#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Only built-in keyboard brightness. No auto-brightness/idle-policy setters.
NSDictionary<NSString *, id> * _Nullable TVKeyboardBacklightRead(NSError **error) NS_RETURNS_RETAINED;
BOOL TVKeyboardBacklightSet(double brightness, uint64_t keyboardID, NSError **error);
NS_ASSUME_NONNULL_END
