import Foundation

/// Async semaphore: at most `limit` operations run at once, the rest wait in FIFO order.
public actor AsyncGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        available = max(1, limit)
    }

    public func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    public nonisolated func run<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }
}
