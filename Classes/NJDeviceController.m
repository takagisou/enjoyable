//
//  NJDeviceController.m
//  Enjoy
//
//  Created by Sam McCall on 4/05/09.
//

#import "NJDeviceController.h"

#import "NJMapping.h"
#import "NJMappingsController.h"
#import "NJDevice.h"
#import "NJInput.h"
#import "NJOutput.h"
#import "NJOutputController.h"
#import "NJEvents.h"
#import "NJDeviceViewController.h"

@implementation NJDeviceController {
    NJHIDManager *_hidManager;
    NSTimer *_continuousOutputsTick;
    NSMutableArray *_continousOutputs;
    NSMutableArray *_devices;
}

#define NSSTR(e) ((NSString *)CFSTR(e))

- (id)init {
    if ((self = [super init])) {
        _devices = [[NSMutableArray alloc] initWithCapacity:16];
        _continousOutputs = [[NSMutableArray alloc] initWithCapacity:32];
        
        _hidManager = [[NJHIDManager alloc] initWithCriteria:@[
                       @{ NSSTR(kIOHIDDeviceUsagePageKey) : @(kHIDPage_GenericDesktop),
                       NSSTR(kIOHIDDeviceUsageKey) : @(kHIDUsage_GD_Joystick) },
                       @{ NSSTR(kIOHIDDeviceUsagePageKey) : @(kHIDPage_GenericDesktop),
                       NSSTR(kIOHIDDeviceUsageKey) : @(kHIDUsage_GD_GamePad) },
                       @{ NSSTR(kIOHIDDeviceUsagePageKey) : @(kHIDPage_GenericDesktop),
                       NSSTR(kIOHIDDeviceUsageKey) : @(kHIDUsage_GD_MultiAxisController) }
                       ]
                                                    delegate:self];

        // The HID manager uses 5-10ms per second doing basically
        // nothing if a noisy device is plugged in (the % of that
        // spent in input_callback is negligible, so it's not
        // something we can make faster). I don't really think that's
        // acceptable, CPU/power wise. So if simulation is disabled
        // and the window is closed, just switch off the HID manager
        // entirely. This probably also has some marginal benefits for
        // compatibility with other applications that want exclusive
        // grabs.
        [NSNotificationCenter.defaultCenter
            addObserver:self
            selector:@selector(stopHidIfDisabled:)
            name:NSApplicationDidResignActiveNotification
            object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
            selector:@selector(startHid)
            name:NSApplicationDidBecomeActiveNotification
            object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_continuousOutputsTick invalidate];
}

- (void)addRunningOutput:(NJOutput *)output {
    // Axis events will trigger every small movement, don't keep
    // re-adding them or they trigger multiple times each time.
    if (![_continousOutputs containsObject:output])
        [_continousOutputs addObject:output];
    if (!_continuousOutputsTick) {
        _continuousOutputsTick = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                           target:self
                                                         selector:@selector(updateContinuousOutputs:)
                                                         userInfo:nil
                                                          repeats:YES];
    }
}

- (void)runOutputForDevice:(IOHIDDeviceRef)device value:(IOHIDValueRef)value {
    NJDevice *dev = [self findDeviceByRef:device];
    NJInput *mainInput = [dev inputForEvent:value];
    [mainInput notifyEvent:value];
    NSArray *children = mainInput.children ? mainInput.children : mainInput ? @[mainInput] : @[];
    for (NJInput *subInput in children) {
        NJOutput *output = mappingsController.currentMapping[subInput];
        output.magnitude = subInput.magnitude;
        output.running = subInput.active;
        if ((output.running || output.magnitude) && output.isContinuous)
            [self addRunningOutput:output];
    }
}

- (void)showOutputForDevice:(IOHIDDeviceRef)device value:(IOHIDValueRef)value {
    NJDevice *dev = [self findDeviceByRef:device];
    NJInput *handler = [dev handlerForEvent:value];
    if (!handler)
        return;
    
    [devicesViewController expandAndSelectItem:handler];
    [outputController focusKey];
}

- (void)hidManager:(NJHIDManager *)manager
      valueChanged:(IOHIDValueRef)value
        fromDevice:(IOHIDDeviceRef)device {
    if (self.simulatingEvents
        && !NSApplication.sharedApplication.isActive) {
        [self runOutputForDevice:device value:value];
    } else {
        [self showOutputForDevice:device value:value];
    }
}

- (void)addDevice:(NJDevice *)device {
    BOOL available;
    do {
        available = YES;
        for (NJDevice *used in _devices) {
            if ([used isEqual:device]) {
                device.index += 1;
                available = NO;
            }
        }
    } while (!available);
    
    [_devices addObject:device];
}

- (void)hidManager:(NJHIDManager *)manager deviceAdded:(IOHIDDeviceRef)device {
    NJDevice *match = [[NJDevice alloc] initWithDevice:device];
    [devicesViewController beginUpdates];
    [self addDevice:match];
    [devicesViewController addedDevice:match atIndex:_devices.count - 1];
    [devicesViewController endUpdates];
}

- (NJDevice *)findDeviceByRef:(IOHIDDeviceRef)device {
    for (NJDevice *dev in _devices)
        if (dev.device == device)
            return dev;
    return nil;
}

- (void)hidManager:(NJHIDManager *)manager deviceRemoved:(IOHIDDeviceRef)device {
    NJDevice *match = [self findDeviceByRef:device];
    IOHIDDeviceRegisterInputValueCallback(device, NULL, NULL);
    if (match) {
        NSInteger idx = [_devices indexOfObjectIdenticalTo:match];
        [devicesViewController beginUpdates];
        [_devices removeObjectAtIndex:idx];
        [devicesViewController removedDevice:match atIndex:idx];
        [devicesViewController endUpdates];
    }
}

- (void)updateContinuousOutputs:(NSTimer *)timer {
    self.mouseLoc = [NSEvent mouseLocation];
    for (NJOutput *output in [_continousOutputs copy]) {
        if (![output update:self]) {
            [_continousOutputs removeObject:output];
        }
    }
    if (!_continousOutputs.count) {
        [_continuousOutputsTick invalidate];
        _continuousOutputsTick = nil;
    }
}

- (void)hidManager:(NJHIDManager *)manager didError:(NSError *)error {
    // Since the error shows the window, it can trigger another attempt
    // to re-open the HID manager, which will also probably fail and error,
    // so don't bother repeating ourselves.
    if (!simulatingEventsButton.window.attachedSheet) {
        [NSApplication.sharedApplication activateIgnoringOtherApps:YES];
        [simulatingEventsButton.window makeKeyAndOrderFront:nil];
        [simulatingEventsButton.window presentError:error
                                     modalForWindow:simulatingEventsButton.window
                                           delegate:nil
                                 didPresentSelector:nil
                                        contextInfo:nil];
    }
    self.simulatingEvents = NO;
}

- (void)hidManagerDidStart:(NJHIDManager *)manager {
    [devicesViewController hidStarted];
}

- (void)hidManagerDidStop:(NJHIDManager *)manager {
    [_devices removeAllObjects];
    [devicesViewController hidStopped];
}

- (void)startHid {
    [_hidManager start];
}

- (void)stopHid {
    [_hidManager stop];
}

- (NJInput *)selectedInput {
    return (NJInput *)devicesViewController.selectedHandler;
}

- (void)setSimulatingEvents:(BOOL)simulatingEvents {
    if (simulatingEvents != _simulatingEvents) {
        _simulatingEvents = simulatingEvents;
        NSInteger state = simulatingEvents ? NSOnState : NSOffState;
        simulatingEventsButton.state = state;
        NSString *name = simulatingEvents
            ? NJEventSimulationStarted
            : NJEventSimulationStopped;
        [NSNotificationCenter.defaultCenter postNotificationName:name
                                                          object:self];

        if (!simulatingEvents && !NSApplication.sharedApplication.isActive)
            [self stopHid];
        else
            [self startHid];
    }
}

- (void)stopHidIfDisabled:(NSNotification *)application {
    if (!self.simulatingEvents && !NSProcessInfo.processInfo.isBeingDebugged)
        [self stopHid];
}

- (IBAction)simulatingEventsChanged:(NSButton *)sender {
    self.simulatingEvents = sender.state == NSOnState;
}

- (NSInteger)numberOfDevicesInDeviceList:(NJDeviceViewController *)dvc {
    return _devices.count;
}

- (NJDevice *)deviceViewController:(NJDeviceViewController *)dvc
                    deviceForIndex:(NSUInteger)idx {
    return _devices[idx];
}

- (id)deviceViewController:(NJDeviceViewController *)dvc
             elementForUID:(NSString *)uid {
    for (NJDevice *dev in _devices) {
        id item = [dev elementForUID:uid];
        if (item)
            return item;
    }
    return nil;
}

- (void)deviceViewControllerDidSelectNothing:(NJDeviceViewController *)dvc {
    [outputController loadCurrent];
}

- (void)deviceViewController:(NJDeviceViewController *)dvc
             didSelectBranch:(NJInputPathElement *)handler {
    [outputController loadCurrent];
}

- (void)deviceViewController:(NJDeviceViewController *)dvc
            didSelectHandler:(NJInputPathElement *)handler {
    [outputController loadCurrent];
}

- (void)deviceViewController:(NJDeviceViewController *)dvc
             didSelectDevice:(NJInputPathElement *)device {
    [outputController loadCurrent];
}

@end
