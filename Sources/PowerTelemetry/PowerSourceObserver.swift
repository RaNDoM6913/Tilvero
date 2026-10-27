import Foundation
import CoreFoundation
#if os(macOS)
import IOKit.ps
#endif

private final class ObservationCallback: Sendable {
    @MainActor var active = true
    let action: @MainActor @Sendable () -> Void
    init(_ action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
}

/// Public IOPowerSources event registration. Polling remains the app's measured fallback.
@MainActor public final class PowerSourceObserver {
    private var source: CFRunLoopSource?
    private var callback: ObservationCallback?
    public var isRunning: Bool { source != nil }
    public init() {}
    @discardableResult public func start(onChange: @escaping @MainActor @Sendable () -> Void) -> Bool {
        stop()
        #if os(macOS)
        let callback = ObservationCallback(onChange)
        let context = Unmanaged.passUnretained(callback).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let callback = Unmanaged<ObservationCallback>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in if callback.active { callback.action() } }
        }, context)?.takeRetainedValue() else { return false }
        self.callback = callback
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
        #else
        return false
        #endif
    }
    public func stop() {
        callback?.active = false
        if let source { CFRunLoopSourceInvalidate(source) }
        source = nil
        callback = nil
    }
    isolated deinit { if let source { CFRunLoopSourceInvalidate(source) } }
}
