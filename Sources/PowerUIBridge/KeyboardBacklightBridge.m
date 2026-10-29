#import "KeyboardBacklightBridge.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <CoreFoundation/CoreFoundation.h>

// Independently declared, fixed operations from the inspected installed ABI.
// The private framework is runtime-loaded; ABI drift fails before invocation.
@interface NSObject (TilveroKeyboardBrightness)
- (NSArray *)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(uint64_t)keyboard;
- (float)brightnessForKeyboard:(uint64_t)keyboard;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(uint64_t)keyboard;
- (BOOL)isBacklightSuppressedOnKeyboard:(uint64_t)keyboard;
- (BOOL)isBacklightDimmedOnKeyboard:(uint64_t)keyboard;
- (BOOL)setBrightness:(float)brightness forKeyboard:(uint64_t)keyboard;
@end
static BOOL TVKeyboardFail(NSError **error, NSInteger code) {
    if (error) *error = [NSError errorWithDomain:@"Tilvero.KeyboardBacklight" code:code userInfo:nil];
    return NO;
}
static id TVKeyboardClient(NSError **error) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/Versions/A/CoreBrightness", RTLD_LAZY | RTLD_LOCAL); });
    Class cls = NSClassFromString(@"KeyboardBrightnessClient");
    if (!handle || !cls) { TVKeyboardFail(error, 1); return nil; }
    NSDictionary *signatures = @{
        @"init":@"@16@0:8", @"copyKeyboardBacklightIDs":@"@16@0:8",
        @"isKeyboardBuiltIn:":@"B24@0:8Q16", @"brightnessForKeyboard:":@"f24@0:8Q16",
        @"isAutoBrightnessEnabledForKeyboard:":@"B24@0:8Q16",
        @"isBacklightSuppressedOnKeyboard:":@"B24@0:8Q16", @"isBacklightDimmedOnKeyboard:":@"B24@0:8Q16",
        @"setBrightness:forKeyboard:":@"B28@0:8f16Q20"
    };
    for (NSString *name in signatures) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (!encoding || strcmp(encoding, [signatures[name] UTF8String]) != 0) { TVKeyboardFail(error, 2); return nil; }
    }
    id client = [[cls alloc] init];
#if !__has_feature(objc_arc)
    [client autorelease];
#endif
    if (!client) TVKeyboardFail(error, 1);
    return client;
}
static NSNumber *TVBuiltInKeyboard(id client, NSError **error) {
    NSArray *ids = [client copyKeyboardBacklightIDs];
    NSNumber *builtIn = nil;
    BOOL valid = [ids isKindOfClass:NSArray.class] && ids.count <= 16;
    if (valid) for (id value in ids) {
        if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) { valid = NO; break; }
        // A float/negative/truncated object must never become a device selector.
        const char *type = [value objCType];
        if (!type || !strchr("CISLQcislq", type[0]) || [value doubleValue] < 0) { valid = NO; break; }
        if ([client isKeyboardBuiltIn:[value unsignedLongLongValue]]) {
            if (builtIn) { valid = NO; break; } // Ambiguous devices fail closed.
            builtIn = value;
        }
    }
#if !__has_feature(objc_arc)
    [builtIn retain];
    [ids release];
    [builtIn autorelease];
#endif
    if (!valid) { TVKeyboardFail(error, 4); return nil; }
    if (!builtIn) TVKeyboardFail(error, 3);
    return builtIn;
}
NSDictionary<NSString *, id> *TVKeyboardBacklightRead(NSError **error) {
    @try {
        id client = TVKeyboardClient(error); if (!client) return nil;
        NSNumber *keyboard = TVBuiltInKeyboard(client, error); if (!keyboard) return nil;
        uint64_t identifier = keyboard.unsignedLongLongValue;
        float brightness = [client brightnessForKeyboard:identifier];
        if (!isfinite(brightness) || brightness < 0 || brightness > 1) { TVKeyboardFail(error, 4); return nil; }
        return [@{
            @"keyboardID":keyboard, @"brightness":@(brightness),
            @"automaticBrightness":@([client isAutoBrightnessEnabledForKeyboard:identifier]),
            @"suppressed":@([client isBacklightSuppressedOnKeyboard:identifier]),
            @"dimmed":@([client isBacklightDimmedOnKeyboard:identifier])
        } copy];
    } @catch (NSException *exception) { TVKeyboardFail(error, 1); return nil; }
}
BOOL TVKeyboardBacklightSet(double brightness, uint64_t keyboardID, NSError **error) {
    // Reject invalid input before framework load, device discovery or dispatch.
    if (!isfinite(brightness) || brightness < 0 || brightness > 1) return TVKeyboardFail(error, 5);
    @try {
        id client = TVKeyboardClient(error); if (!client) return NO;
        NSNumber *keyboard = TVBuiltInKeyboard(client, error); if (!keyboard) return NO;
        if (keyboard.unsignedLongLongValue != keyboardID) return TVKeyboardFail(error, 3);
        if (![client setBrightness:(float)brightness forKeyboard:keyboardID]) return TVKeyboardFail(error, 6);
        return YES;
    } @catch (NSException *exception) { return TVKeyboardFail(error, 7); }
}
