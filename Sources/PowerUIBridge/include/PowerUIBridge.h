#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Fixed, typed user-space PowerUI operations. No arbitrary selector or IPC input.
NSDictionary<NSString *, id> * _Nullable TVNativeChargeRead(NSError **error) NS_RETURNS_RETAINED;
BOOL TVNativeChargeSetLimit(uint8_t target, NSError **error);
BOOL TVNativeChargeSetEnabled(BOOL enabled, NSError **error);
NS_ASSUME_NONNULL_END
