#import "PowerUIBridge.h"
#import <objc/runtime.h>
#import <dlfcn.h>

// Runtime declarations are limited to the inspected ABI. No Apple implementation
// or private resource is copied. An OS change fails closed before dispatch.
@interface NSObject (TilveroPowerUI)
- (id)initWithClientName:(NSString *)name;
- (BOOL)isMCLSupported;
- (NSUInteger)isMCLCurrentlyEnabled:(NSError **)error;
- (uint8_t)getMCLLimitWithError:(NSError **)error;
- (id)availableChargeLimitsWithError:(NSError **)error;
- (NSUInteger)isSmartChargingCurrentlyEnabled:(NSError **)error;
- (BOOL)setMCLLimit:(uint8_t)target error:(NSError **)error;
- (BOOL)enableMCL:(NSError **)error;
- (BOOL)disableMCL:(NSError **)error;
@end

static BOOL TVFail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Tilvero.NativeCharge" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static id TVClient(NSError **error) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_LAZY | RTLD_LOCAL); });
    Class cls = NSClassFromString(@"PowerUISmartChargeClient");
    NSDictionary *signatures = @{
        @"initWithClientName:":@"@24@0:8@16", @"isMCLSupported":@"B16@0:8",
        @"isMCLCurrentlyEnabled:":@"Q24@0:8^@16", @"getMCLLimitWithError:":@"C24@0:8^@16",
        @"availableChargeLimitsWithError:":@"@24@0:8^@16", @"isSmartChargingCurrentlyEnabled:":@"Q24@0:8^@16",
        @"setMCLLimit:error:":@"B28@0:8C16^@20", @"enableMCL:":@"B24@0:8^@16", @"disableMCL:":@"B24@0:8^@16"
    };
    if (!handle || !cls) { TVFail(error,1,@"The native macOS charging client is unavailable."); return nil; }
    for (NSString *name in signatures) {
        Method method = class_getInstanceMethod(cls,NSSelectorFromString(name));
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (!encoding || ![signatures[name] isEqualToString:[NSString stringWithUTF8String:encoding]]) {
            TVFail(error,2,@"The native macOS charging interface changed. No setting was written."); return nil;
        }
    }
    id client = [[cls alloc] initWithClientName:@"Tilvero"];
#if !__has_feature(objc_arc)
    [client autorelease];
#endif
    if (!client) TVFail(error,3,@"The native macOS charging connection could not be created.");
    return client;
}

NSDictionary<NSString *,id> *TVNativeChargeRead(NSError **error) {
    @try {
        id client = TVClient(error); if (!client) return nil;
        if (![client isMCLSupported]) { TVFail(error,4,@"Native charge limits are not supported on this Mac."); return nil; }
        NSError *failure = nil;
        NSUInteger enabled = [client isMCLCurrentlyEnabled:&failure]; if (failure) { if(error)*error=failure; return nil; }
        uint8_t target = [client getMCLLimitWithError:&failure]; if (failure) { if(error)*error=failure; return nil; }
        NSArray *targets = [client availableChargeLimitsWithError:&failure]; if (failure) { if(error)*error=failure; return nil; }
        NSUInteger optimized = [client isSmartChargingCurrentlyEnabled:&failure]; if (failure) { if(error)*error=failure; return nil; }
        if (enabled>1 || optimized>1 || target<80 || target>100 || ![targets isKindOfClass:NSArray.class] || !targets.count || targets.count>21) {
            TVFail(error,5,@"Native charge readback is incomplete or invalid."); return nil;
        }
        for (id value in targets) if (![value isKindOfClass:NSNumber.class] || [value doubleValue] != [value integerValue] || [value integerValue]<80 || [value integerValue]>100) {
            TVFail(error,5,@"Native target list is invalid."); return nil;
        }
        return [[NSDictionary alloc] initWithDictionary:@{@"enabled":@(enabled==1), @"target":@(target), @"optimizedCharging":@(optimized==1), @"targets":targets}];
    } @catch (NSException *exception) { TVFail(error,6,@"The native charging interface failed."); return nil; }
}
BOOL TVNativeChargeSetLimit(uint8_t target,NSError **error) {
    @try {
        // Validate before reaching Apple's uint8 setter, including values below80.
        if (target<80 || target>100) return TVFail(error,7,@"Unsupported native charge target.");
        NSDictionary *state=TVNativeChargeRead(error); if (!state) return NO;
        BOOL offered=[state[@"targets"] containsObject:@(target)];
#if !__has_feature(objc_arc)
        [state release];
#endif
        if (!offered) return TVFail(error,7,@"Choose a target offered by this Mac.");
        id client=TVClient(error); if (!client) return NO;
        return [client setMCLLimit:target error:error];
    } @catch (NSException *exception) { return TVFail(error,6,@"The native charging operation failed; readback is required."); }
}
BOOL TVNativeChargeSetEnabled(BOOL enabled,NSError **error) {
    @try {
        id client=TVClient(error); if (!client) return NO;
        return enabled ? [client enableMCL:error] : [client disableMCL:error];
    } @catch (NSException *exception) { return TVFail(error,6,@"The native charging operation failed; readback is required."); }
}
