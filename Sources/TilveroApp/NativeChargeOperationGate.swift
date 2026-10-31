import Foundation

/// A deadline returns control to the UI without pretending that the underlying
/// XPC call was cancelled. No next operation is admitted until that call returns.
@MainActor final class NativeChargeOperationGate {
    enum Failure: Error, LocalizedError {
        case busy, timedOut
        var errorDescription: String? {
            switch self {
            case .busy: "A native charging operation is still in progress."
            case .timedOut: "macOS did not respond in time. Read and reconcile its result before trying again."
            }
        }
    }
    enum Purpose: Equatable, Sendable {
        case read, setLimit(target: Int), setEnabled(enabled: Bool)
        var isMutation: Bool { self != .read }
    }
    private(set) var pendingPurpose: Purpose?
    var pending: Bool { pendingPurpose != nil }
    var onTimeout: ((Purpose) -> Void)?
    var onLateCompletion: ((Purpose) -> Void)?
    let timeout: Duration
    init(timeout: Duration) { self.timeout = timeout }
    private final class Reply<T: Sendable> {
        var continuation: CheckedContinuation<T, any Error>?
        init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }
        func finish(_ result: Result<T, any Error>) {
            guard let continuation else { return }; self.continuation = nil; continuation.resume(with: result)
        }
    }
    func call<T: Sendable>(purpose: Purpose, onDispatch: (@MainActor () -> Void)? = nil,
                           operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !pending else { throw Failure.busy }
        pendingPurpose = purpose
        return try await withCheckedThrowingContinuation { continuation in
            let reply = Reply(continuation)
            var deadline: Task<Void, Never>?
            Task { @MainActor in
                let result: Result<T, any Error>
                if purpose.isMutation { onDispatch?() }
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                pendingPurpose = nil; deadline?.cancel()
                if reply.continuation != nil { reply.finish(result) }
                else { onLateCompletion?(purpose) }
            }
            deadline = Task { @MainActor in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard reply.continuation != nil else { return }
                onTimeout?(purpose)
                reply.finish(.failure(Failure.timedOut))
            }
        }
    }
}
