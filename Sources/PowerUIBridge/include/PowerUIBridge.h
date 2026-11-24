// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

#import "KeyboardBacklightBridge.h"
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Fixed, typed user-space PowerUI operations. No arbitrary selector or IPC input.
NSDictionary<NSString *, id> * _Nullable TVNativeChargeRead(NSError **error) NS_RETURNS_RETAINED;
BOOL TVNativeChargeSetLimit(uint8_t target, NSError **error);
BOOL TVNativeChargeSetEnabled(BOOL enabled, NSError **error);
/// macOS Optimized Battery Charging: whether it is on, whether it holds the charge right now, and the full-charge time
/// macOS planned (keys "enabled" Bool, "holding" Bool, optional "deadline" NSDate). Nil with an error when unreadable.
NSDictionary<NSString *, id> * _Nullable TVOptimizedChargingRead(NSError **error) NS_RETURNS_RETAINED;
/// Turns Optimized Battery Charging on or off (the System Settings switch).
BOOL TVOptimizedChargingSetEnabled(BOOL enabled, NSError **error);
/// macOS's own "until tomorrow" pause of Optimized Battery Charging (it turns itself back on).
BOOL TVOptimizedChargingPauseUntilTomorrow(NSError **error);
NS_ASSUME_NONNULL_END
