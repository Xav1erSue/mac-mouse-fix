//
// --------------------------------------------------------------------------
// LogitechCIDActivator.h
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Miguel Angelo in 2026
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//
// Diverts buttons of Logitech mice through HID++ 2.0 ReprogControlsV4 (feature 0x1B04),
// and reports them as normal mouse button CGEvents that Mac Mouse Fix can remap.
// See the .m file for details.
//

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDDevice.h>

@interface LogitechCIDActivator : NSObject

/// Both of these need to be called on the same runLoop. (DeviceManager calls them from its device callbacks.)
+ (void)handleDeviceAttached:(IOHIDDeviceRef)device;
+ (void)handleDeviceRemoved:(IOHIDDeviceRef)device;

@end
