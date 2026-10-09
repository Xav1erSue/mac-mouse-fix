//
// --------------------------------------------------------------------------
// LogitechCIDActivator.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Miguel Angelo in 2026
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------

/// Overview:
///     Logitech mice expose their buttons through HID++ 2.0 feature 0x1B04 (ReprogControlsV4).
///     We "divert" some of those buttons, which makes the firmware report them through HID++ notifications instead of through the normal HID button reports.
///     We then turn the notifications back into CGEvents, which get picked up by ButtonInputReceiver.m like any other button input.
///
/// Why divert Back/Forward?
///     Some Logitech mice (observed on the Logitech Lift over Bluetooth) only report their side buttons to the host when the button is *released* –
///     the buttonDown and buttonUp arrive 10-20 ms apart, no matter how long the button was held. (Probably so the firmware can distinguish clicks from gestures.)
///     That makes Click and Drag impossible. Diverted buttons are reported immediately on press and on release.
///
/// Why divert the other non-native buttons?
///     Buttons like the thumb button, or the DPI button aren't reported to the host at all unless diverted. (This was the original purpose of this file.)
///
/// Threading:
///     All state is owned by the runLoop that DeviceManager calls us from (the main runLoop) – that's also where we schedule our callbacks and timer.
///     The only exception is the undivert-before-quitting code, which is why access to `_states` is locked.
///
/// Limitations:
///     - Only talks to devices that are connected directly (Bluetooth or cable), not to devices behind a Unifying/Bolt receiver.
///     - Other software that speaks HID++ (Logi Options+) will fight with us over the divert state.
///
/// References:
///     - https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html
///     - Solaar (pwr-Solaar/Solaar) hidpp20.py

#import "LogitechCIDActivator.h"
#import <IOKit/hid/IOHIDLib.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#import <os/lock.h>
#import "SharedUtility.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"

#define kLogitechVID        0x046D
#define kHIDPP_Long         0x11
#define kHIDPP_Device       0xFF    /// Device index for directly connected devices
#define kHIDPP_SoftwareID   0x0B    /// Arbitrary non-zero id, so we can tell our responses apart from notifications and from other software's responses
#define kHIDPP_PacketSize   20
#define kFeat_Root          0x00
#define kFeat_ReprogV4      0x1B04

/// ReprogControlsV4 functions
#define kFunc_GetCount          0
#define kFunc_GetCidInfo        1
#define kFunc_SetCidReporting   3

/// GetCidInfo flags
#define kCidFlag_Divertable (1 << 5)
#define kCidFlag_Virtual    (1 << 7)

/// SetCidReporting flags – each flag bit has a 'valid' bit right above it, telling the firmware that the field is being set intentionally.
#define kReporting_Divert   0x03    /// divert=1, divertValid=1
#define kReporting_Undivert 0x02    /// divert=0, divertValid=1

/// Task ids (TID)
#define kTID_LeftClick      0x0038
#define kTID_RightClick     0x0039
#define kTID_MiddleClick    0x003A
#define kTID_Back           0x003C
#define kTID_Forward        0x003E

/// MMF button numbers (1-based. The CGEvent button number is one lower)
#define kButton_Back        4
#define kButton_Forward     5
#define kButton_FirstExtra  6

#define kMaxControls        16
#define kMaxPressed         4       /// The diverted-buttons notification holds up to 4 CIDs
#define kRequestTimeout     1.0     /// Seconds
#define kMaxRetries         3
#define kKeepAliveInterval  30      /// Ticks (seconds)

typedef enum {
    kPhase_GetFeature,
    kPhase_GetCount,
    kPhase_GetCidInfo,
    kPhase_Divert,
    kPhase_Active,
    kPhase_Failed,
} MFCIDPhase;

typedef struct {
    uint16_t cid;
    int      button;
} MFCIDControl;

typedef struct {
    IOHIDDeviceRef  device;
    uint8_t         reportBuf[64];

    MFCIDPhase      phase;
    uint8_t         featureIndex;
    int             controlCount;       /// Number of controls the device has
    int             cursor;             /// Index of the control we're currently querying / diverting

    uint8_t         pendingPacket[kHIDPP_PacketSize];
    CFAbsoluteTime  pendingSince;
    int             retries;

    MFCIDControl    diverted[kMaxControls];
    int             divertedCount;
    int             nextExtraButton;

    uint16_t        pressed[kMaxPressed];
    int             pressedCount;
} MFCIDDeviceState;

static NSMutableArray<NSValue *> *_states;
static os_unfair_lock _statesLock = OS_UNFAIR_LOCK_INIT;
static CFRunLoopTimerRef _tickTimer;
static int _tickCount;

static void setup(void);

#pragma mark - Button injection

static int buttonForCID(MFCIDDeviceState *s, uint16_t cid) {
    for (int i = 0; i < s->divertedCount; i++) if (s->diverted[i].cid == cid) return s->diverted[i].button;
    return -1;
}

static void postButton(MFCIDDeviceState *s, uint16_t cid, BOOL down) {

    int button = buttonForCID(s, cid);
    if (button < 0) return;

    /// Post a CGEvent
    ///     ButtonInputReceiver.m picks this up from its eventTap, just like input from any other mouse.
    ///     If the button isn't remapped, the event passes through to the system and the button keeps its normal function.
    ///     The event doesn't have a senderID, so ButtonInputReceiver.m attributes it to `Device.strangeDevice`.

    CGEventRef locationEvent = CGEventCreate(NULL);
    CGPoint location = CGEventGetLocation(locationEvent);
    CFRelease(locationEvent);

    CGEventRef event = CGEventCreateMouseEvent(NULL, down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp, location, (CGMouseButton)(button - 1));
    if (event == NULL) return;
    CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, button - 1);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventSetDoubleValueField(event, kCGMouseEventPressure, down ? 1.0 : 0.0); /// ButtonInputReceiver.m uses the pressure to tell down from up.
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void handleDivertedButtons(MFCIDDeviceState *s, const uint8_t *report) {

    /// The notification lists all diverted buttons that are currently held down. Diff against the previous list.

    uint16_t now[kMaxPressed]; int nowCount = 0;
    for (int i = 0; i < kMaxPressed; i++) {
        uint16_t cid = ((uint16_t)report[4 + 2*i] << 8) | report[5 + 2*i];
        if (cid != 0) now[nowCount++] = cid;
    }

    for (int i = 0; i < s->pressedCount; i++) {
        BOOL stillDown = NO;
        for (int j = 0; j < nowCount; j++) if (now[j] == s->pressed[i]) stillDown = YES;
        if (!stillDown) postButton(s, s->pressed[i], NO);
    }
    for (int j = 0; j < nowCount; j++) {
        BOOL wasDown = NO;
        for (int i = 0; i < s->pressedCount; i++) if (s->pressed[i] == now[j]) wasDown = YES;
        if (!wasDown) postButton(s, now[j], YES);
    }

    memcpy(s->pressed, now, sizeof(now));
    s->pressedCount = nowCount;
}

static void releaseAllButtons(MFCIDDeviceState *s) {
    for (int i = 0; i < s->pressedCount; i++) postButton(s, s->pressed[i], NO);
    s->pressedCount = 0;
}

#pragma mark - HID++ requests

static IOReturn sendPacket(MFCIDDeviceState *s, uint8_t featureIndex, uint8_t function, const uint8_t *params, int paramCount) {
    uint8_t packet[kHIDPP_PacketSize] = {0};
    packet[0] = kHIDPP_Long;
    packet[1] = kHIDPP_Device;
    packet[2] = featureIndex;
    packet[3] = (uint8_t)(function << 4) | kHIDPP_SoftwareID;
    for (int i = 0; i < paramCount; i++) packet[4 + i] = params[i];
    memcpy(s->pendingPacket, packet, kHIDPP_PacketSize);
    return IOHIDDeviceSetReport(s->device, kIOHIDReportTypeOutput, kHIDPP_Long, packet, kHIDPP_PacketSize);
}

static void sendSetCidReporting(MFCIDDeviceState *s, uint16_t cid, uint8_t flags) {
    uint8_t params[3] = { (uint8_t)(cid >> 8), (uint8_t)(cid & 0xFF), flags };
    sendPacket(s, s->featureIndex, kFunc_SetCidReporting, params, 3);
}

static void fail(MFCIDDeviceState *s, const char *reason) {
    DDLogDebug("LogitechCIDActivator: Giving up on device %@ - %s", s->device, reason);
    s->phase = kPhase_Failed;
}

static void sendRequestForCurrentPhase(MFCIDDeviceState *s) {

    /// Sends the request belonging to `s->phase`. The response is handled in `handleResponse()`.

    IOReturn ret = kIOReturnSuccess;

    if (s->phase == kPhase_GetFeature) {
        uint8_t params[2] = { kFeat_ReprogV4 >> 8, kFeat_ReprogV4 & 0xFF };
        ret = sendPacket(s, kFeat_Root, 0, params, 2);
    } else if (s->phase == kPhase_GetCount) {
        ret = sendPacket(s, s->featureIndex, kFunc_GetCount, NULL, 0);
    } else if (s->phase == kPhase_GetCidInfo) {
        uint8_t params[1] = { (uint8_t)s->cursor };
        ret = sendPacket(s, s->featureIndex, kFunc_GetCidInfo, params, 1);
    } else if (s->phase == kPhase_Divert) {
        sendSetCidReporting(s, s->diverted[s->cursor].cid, kReporting_Divert);
    } else {
        return;
    }

    if (ret != kIOReturnSuccess) { fail(s, "Sending the HID++ request failed. The device probably doesn't speak HID++."); return; }
    s->pendingSince = CFAbsoluteTimeGetCurrent();
}

static void advance(MFCIDDeviceState *s, MFCIDPhase phase, int cursor) {
    s->phase = phase;
    s->cursor = cursor;
    s->retries = 0;
    sendRequestForCurrentPhase(s);
}

static void handleResponse(MFCIDDeviceState *s, const uint8_t *report, BOOL isError) {

    if (isError) {
        if (s->phase == kPhase_GetCidInfo)  { /// Skip this control
            if (s->cursor + 1 < s->controlCount)    advance(s, kPhase_GetCidInfo, s->cursor + 1);
            else if (s->divertedCount > 0)          advance(s, kPhase_Divert, 0);
            else                                    fail(s, "No divertable controls.");
        } else if (s->phase == kPhase_Divert) { /// Skip this control
            if (s->cursor + 1 < s->divertedCount)   advance(s, kPhase_Divert, s->cursor + 1);
            else                                    s->phase = kPhase_Active;
        } else {
            fail(s, "Device responded with a HID++ error.");
        }
        return;
    }

    if (s->phase == kPhase_GetFeature) {

        s->featureIndex = report[4];
        if (s->featureIndex == 0) { fail(s, "Device doesn't support ReprogControlsV4."); return; }
        advance(s, kPhase_GetCount, 0);

    } else if (s->phase == kPhase_GetCount) {

        s->controlCount = report[4];
        if (s->controlCount == 0) { fail(s, "Device has no controls."); return; }
        advance(s, kPhase_GetCidInfo, 0);

    } else if (s->phase == kPhase_GetCidInfo) {

        uint16_t cid = ((uint16_t)report[4] << 8) | report[5];
        uint16_t tid = ((uint16_t)report[6] << 8) | report[7];
        uint8_t flags = report[8];

        BOOL divertable = (flags & kCidFlag_Divertable) && !(flags & kCidFlag_Virtual);
        BOOL isPrimaryButton = tid == kTID_LeftClick || tid == kTID_RightClick || tid == kTID_MiddleClick; /// These report properly on their own

        if (divertable && !isPrimaryButton && s->divertedCount < kMaxControls) {
            int button;
            if      (tid == kTID_Back)      button = kButton_Back;
            else if (tid == kTID_Forward)   button = kButton_Forward;
            else                            button = s->nextExtraButton++;
            s->diverted[s->divertedCount++] = (MFCIDControl){ .cid = cid, .button = button };
        }

        if (s->cursor + 1 < s->controlCount)    advance(s, kPhase_GetCidInfo, s->cursor + 1);
        else if (s->divertedCount > 0)          advance(s, kPhase_Divert, 0);
        else                                    fail(s, "No divertable controls.");

    } else if (s->phase == kPhase_Divert) {

        DDLogDebug("LogitechCIDActivator: Diverted CID 0x%04x -> button %d", s->diverted[s->cursor].cid, s->diverted[s->cursor].button);

        if (s->cursor + 1 < s->divertedCount) {
            advance(s, kPhase_Divert, s->cursor + 1);
        } else {
            s->phase = kPhase_Active;
            DDLogInfo("LogitechCIDActivator: Diverted %d button(s) on %@", s->divertedCount, (__bridge id)IOHIDDeviceGetProperty(s->device, CFSTR(kIOHIDProductKey)));
        }
    }
}

static void inputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex length) {

    MFCIDDeviceState *s = context;

    if (length < 12 || report[0] != kHIDPP_Long || report[1] != kHIDPP_Device) return;

    uint8_t softwareID = report[3] & 0x0F;
    uint8_t function = report[3] >> 4;

    /// Notification: diverted buttons changed
    if (s->featureIndex != 0 && report[2] == s->featureIndex && softwareID == 0 && function == 0) {
        handleDivertedButtons(s, report);
        return;
    }

    /// Response to our pending request
    BOOL isWaiting = s->phase != kPhase_Active && s->phase != kPhase_Failed;
    if (!isWaiting) return;

    BOOL isResponse = report[2] == s->pendingPacket[2] && report[3] == s->pendingPacket[3];
    BOOL isError    = report[2] == 0xFF && report[3] == s->pendingPacket[2] && report[4] == s->pendingPacket[3];

    if (isResponse || isError) handleResponse(s, report, isError);
}

static void divertAgain(MFCIDDeviceState *s) {

    /// The firmware forgets the divert state on sleep/reconnect, and other HID++ software might reset it. Re-sending is cheap and idempotent.

    if (s->phase != kPhase_Active) return;
    for (int i = 0; i < s->divertedCount; i++) sendSetCidReporting(s, s->diverted[i].cid, kReporting_Divert);
}

static void tick(CFRunLoopTimerRef timer, void *info) {

    _tickCount++;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    for (NSValue *value in _states) {
        MFCIDDeviceState *s = value.pointerValue;

        /// Retry requests that timed out
        BOOL isWaiting = s->phase != kPhase_Active && s->phase != kPhase_Failed;
        if (isWaiting && now - s->pendingSince > kRequestTimeout) {
            if (++s->retries > kMaxRetries) fail(s, "Requests timed out.");
            else                            sendRequestForCurrentPhase(s);
        }

        /// Keep alive
        if (_tickCount % kKeepAliveInterval == 0) divertAgain(s);
    }
}

#pragma mark - Interface

@implementation LogitechCIDActivator

+ (void)handleDeviceAttached:(IOHIDDeviceRef)device {

    NSNumber *vendorID = (__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    if (vendorID.integerValue != kLogitechVID) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ setup(); });

    MFCIDDeviceState *s = calloc(1, sizeof(MFCIDDeviceState));
    s->device = (IOHIDDeviceRef)CFRetain(device);
    s->nextExtraButton = kButton_FirstExtra;

    IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    IOHIDDeviceRegisterInputReportCallback(device, s->reportBuf, sizeof(s->reportBuf), inputReportCallback, s);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);

    os_unfair_lock_lock(&_statesLock);
    [_states addObject:[NSValue valueWithPointer:s]];
    os_unfair_lock_unlock(&_statesLock);

    advance(s, kPhase_GetFeature, 0);
}

+ (void)handleDeviceRemoved:(IOHIDDeviceRef)device {

    for (NSValue *value in _states.copy) {
        MFCIDDeviceState *s = value.pointerValue;
        if (s->device != device) continue;

        releaseAllButtons(s);
        IOHIDDeviceRegisterInputReportCallback(device, s->reportBuf, sizeof(s->reportBuf), NULL, NULL);

        os_unfair_lock_lock(&_statesLock);
        [_states removeObject:value];
        os_unfair_lock_unlock(&_statesLock);

        CFRelease(s->device);
        free(s);
    }
}

static void undivertAll(void) {

    /// Give the buttons back to the firmware. Otherwise they'd be dead until the mouse reconnects.

    os_unfair_lock_lock(&_statesLock);
    for (NSValue *value in _states) {
        MFCIDDeviceState *s = value.pointerValue;
        if (s->phase != kPhase_Active && s->phase != kPhase_Divert) continue;
        for (int i = 0; i < s->divertedCount; i++) sendSetCidReporting(s, s->diverted[i].cid, kReporting_Undivert);
    }
    os_unfair_lock_unlock(&_statesLock);
}

static void setup(void) {

    _states = [NSMutableArray array];

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();

    /// Timer for request timeouts and keep-alive
    _tickTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1.0, 1.0, 0, 0, tick, NULL);
    CFRunLoopAddTimer(runLoop, _tickTimer, kCFRunLoopCommonModes);

    /// Divert again after wake
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        CFRunLoopPerformBlock(runLoop, kCFRunLoopCommonModes, ^{
            for (NSValue *value in _states) divertAgain(value.pointerValue);
        });
        CFRunLoopWakeUp(runLoop);
    }];

    /// Undivert before quitting
    ///     The helper is normally terminated through launchd, which sends SIGTERM and doesn't trigger `applicationWillTerminate:`. (See UNIXSignals.m)
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        undivertAll();
    }];
    signal(SIGTERM, SIG_IGN);
    static dispatch_source_t sigtermSource;
    sigtermSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigtermSource, ^{
        undivertAll();
        exit(0);
    });
    dispatch_resume(sigtermSource);
}

@end
