//
//  UIWebView+Gamepad.m
//  GamepadBridge
//
//  Created by Conrad Kramer on 12/25/13.
//  Copyright (c) 2013 Conrad Kramer. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <GameController/GameController.h>

#include <objc/runtime.h>

@interface WebFrame : NSObject
- (JSContext *)javaScriptContext;
@end

@interface UIWebView (WebFrameLoadDelegate)
- (void)webView:(id)sender didClearWindowObject:(id)windowObject forFrame:(WebFrame *)frame;
- (void)webView:(id)sender willCloseFrame:(WebFrame *)frame;
@end

static char GBConnectedObserverKey;
static char GBDisconnectedObserverKey;

static void (*GBDidClearWindowObject_orig)(UIWebView *, SEL, id, id, WebFrame *);
static void (*GBWillCloseFrame_orig)(UIWebView *, SEL, id, WebFrame *);

/**
 Snapshots a `GCControllerButtonInput` object into its corresponding JavaScript representation.

 @return `JSValue` of type `GamepadButton` that conforms to Section 5 of the draft
 */
static JSValue * GBGamepadButtonObjectFromInput(GCControllerButtonInput *input, JSContext *context) {
    input = [input isKindOfClass:[NSNull class]] ? nil : input;
    if (!context[@"GamepadButton"].toBool) [context evaluateScript:@"function GamepadButton(){}; GamepadButton.prototype = new Object();"];
    JSValue *object = [context evaluateScript:@"new GamepadButton()"];
    [object setValue:@(input.pressed) forProperty:@"pressed"];
    [object setValue:@(input.value) forProperty:@"value"];
    return object;
}

/**
 Snapshots a `GCController` object into its corresponding JavaScript representation.

 @return `JSValue` of type `Gamepad` that conforms to Section 4 of the draft
 */
static JSValue * GBGamepadObjectFromController(GCController *controller, JSContext *context) {
    GCGamepad *gamepad = controller.gamepad;
    GCControllerDirectionPad *dpad = gamepad.dpad;
    GCExtendedGamepad *extendedGamepad = controller.extendedGamepad;
    GCControllerDirectionPad *leftThumbstick = extendedGamepad.leftThumbstick;
    GCControllerDirectionPad *rightThumbstick = extendedGamepad.rightThumbstick;
    NSArray *axes = @[ @(leftThumbstick.xAxis.value),
                       @(-1.0 * leftThumbstick.yAxis.value),
                       @(rightThumbstick.xAxis.value),
                       @(-1.0 * rightThumbstick.yAxis.value) ];
    NSMutableArray *buttons = @[ gamepad.buttonA,
                                 gamepad.buttonB,
                                 gamepad.buttonX,
                                 gamepad.buttonY,
                                 extendedGamepad.leftShoulder,
                                 extendedGamepad.rightShoulder,
                                 extendedGamepad.leftTrigger,
                                 extendedGamepad.rightTrigger,
                                 [NSNull null],
                                 [NSNull null],
                                 [NSNull null],
                                 [NSNull null],
                                 dpad.up,
                                 dpad.down,
                                 dpad.left,
                                 dpad.right,
                                 [NSNull null] ].mutableCopy;
    for (NSUInteger idx = 0; idx < buttons.count; idx++)
        buttons[idx] = GBGamepadButtonObjectFromInput(buttons[idx], context);
    NSDictionary *dictionary = @{ @"axes": axes,
                                @"buttons": buttons,
                                @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000),
                                @"mapping": @"standard",
                                @"id": controller.vendorName,
                                @"connected": @([[[controller class] controllers] containsObject:controller]),
                                @"index": @(controller.playerIndex) };
    if (!context[@"Gamepad"].toBool) [context evaluateScript:@"function Gamepad(){}; Gamepad.prototype = new Object();"];
    JSValue *object = [context evaluateScript:@"new Gamepad()"];
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [object setValue:obj forProperty:key];
    }];
    return object;
}

/**
 Indexes connected `GCController` objects in a method consistent with Section 4.1 of the draft.
 */
static void GBIndexGamepads() {
    NSArray *controllers = [GCController controllers];
    NSMutableDictionary *indexedControllers = [NSMutableDictionary dictionary];
    [controllers enumerateObjectsUsingBlock:^(GCController *controller, NSUInteger idx, BOOL *stop) {
        indexedControllers[@(controller.playerIndex)] = controller;
    }];
    [controllers enumerateObjectsUsingBlock:^(GCController *controller, NSUInteger idx, BOOL *stop) {
        if (controller.playerIndex == GCControllerPlayerIndexUnset) {
            for (NSInteger index = 0; index < INT_MAX; index++) {
                if (indexedControllers[@(index)] == nil) {
                    controller.playerIndex = index;
                    indexedControllers[@(index)] = controller;
                    break;
                }
            }
        }
    }];
}

/**
 Adds the Navigator interface extension specified in Section 6 of the draft.
 Also adds a bridge for the `gamepadconnected` and `gamepaddisconnected` events specified in Sections 10 and 11 of the draft.
 
 See the `WebFrameLoadDelegate` informal protocol for more information on this method.
 */
static void GBDidClearWindowObject(UIWebView *self, SEL _cmd, id sender, id windowObject, WebFrame *frame) {
    JSContext *context = frame.javaScriptContext;
    context[@"window"][@"navigator"][@"getGamepads"] = ^{
        NSArray *controllers = [GCController controllers];
        NSMutableArray *gamepads = [NSMutableArray array];
        NSMutableDictionary *indexedGamepads = [NSMutableDictionary dictionary];
        [controllers enumerateObjectsUsingBlock:^(GCController *controller, NSUInteger idx, BOOL *stop) {
            indexedGamepads[@(controller.playerIndex)] = GBGamepadObjectFromController(controller, context);
        }];
        NSInteger maxIndex = controllers.count ? [[controllers valueForKeyPath:@"@max.playerIndex"] integerValue] : -1;
        for (NSInteger idx = 0; idx <= maxIndex; idx++) {
            gamepads[idx] = indexedGamepads[@(idx)] ?: [JSValue valueWithUndefinedInContext:context];
        }
        return gamepads;
    };

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSOperationQueue *queue = [NSOperationQueue mainQueue];
    id connectedObserver = [center addObserverForName:GCControllerDidConnectNotification object:nil queue:queue usingBlock:^(NSNotification *note) {
        GBIndexGamepads();
        JSValue *event = [context evaluateScript:@"new Event('gamepadconnected')"];
        [event setValue:GBGamepadObjectFromController(note.object, context) forProperty:@"gamepad"];
        [context[@"window"] invokeMethod:@"dispatchEvent" withArguments:@[event]];
    }];
    id disconnectedObserver = [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:queue usingBlock:^(NSNotification *note) {
        JSValue *event = [context evaluateScript:@"new Event('gamepaddisconnected')"];
        [event setValue:GBGamepadObjectFromController(note.object, context) forProperty:@"gamepad"];
        [context[@"window"] invokeMethod:@"dispatchEvent" withArguments:@[event]];
    }];

    objc_setAssociatedObject(context, &GBConnectedObserverKey, connectedObserver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(context, &GBDisconnectedObserverKey, disconnectedObserver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    GBIndexGamepads();
    GBDidClearWindowObject_orig(self, _cmd, sender, windowObject, frame);
}

/**
 Removes the bridge for controller connected and disconnected events.

 See the `WebFrameLoadDelegate` informal protocol for more information on this method.
 */
static void GBWillCloseFrame(UIWebView *self, SEL _cmd, id sender, WebFrame *frame) {
    JSContext *context = frame.javaScriptContext;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:objc_getAssociatedObject(context, &GBConnectedObserverKey)];
    [center removeObserver:objc_getAssociatedObject(context, &GBDisconnectedObserverKey)];
    objc_setAssociatedObject(context, &GBConnectedObserverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(context, &GBDisconnectedObserverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    GBWillCloseFrame_orig(self, _cmd, sender, frame);
}

/**
 Hooks `-[UIWebView webView:didClearWindowObject:forFrame:]` to load GamepadBridge into every UIWebView.
 Also hooks `-[UIWebView webView:willCloseFrame:]` to unload GamepadBridge.
 */
@implementation UIWebView (GamepadBridge)

+ (void)load {
    Method windowMethod = class_getInstanceMethod([UIWebView class], @selector(webView:didClearWindowObject:forFrame:));
    Method closeMethod = class_getInstanceMethod([UIWebView class], @selector(webView:willCloseFrame:));
    GBDidClearWindowObject_orig = (typeof(GBDidClearWindowObject_orig))method_setImplementation(windowMethod, (IMP)GBDidClearWindowObject);
    GBWillCloseFrame_orig = (typeof(GBWillCloseFrame_orig))method_setImplementation(closeMethod, (IMP)GBWillCloseFrame);
}

@end
