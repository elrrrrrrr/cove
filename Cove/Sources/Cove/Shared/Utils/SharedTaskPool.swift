import Foundation

/// Cancels shared work only when its final subscriber leaves.
actor SharedTaskPool<Key: Hashable & Sendable, Value: Sendable> {
    private struct Work {
        let id: UUID
        let task: Task<Void, Never>
        var subscribers: [UUID: CheckedContinuation<Value?, Never>]
    }
    private var work: [Key: Work] = [:]

    func value(for key: Key, operation: @escaping @Sendable () async -> Value?) async -> Value? {
        let subscriber = UUID()
        let result: Value? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if work[key] != nil {
                    work[key]?.subscribers[subscriber] = continuation
                } else {
                    let id = UUID()
                    let task = Task {
                        let result = await operation()
                        complete(key, id: id, result: result)
                    }
                    work[key] = Work(id: id, task: task, subscribers: [subscriber: continuation])
                }
            }
        } onCancel: { Task { await self.cancel(key, subscriber: subscriber) } }
        return Task.isCancelled ? nil : result
    }

    private func complete(_ key: Key, id: UUID, result: Value?) {
        guard work[key]?.id == id, let completed = work.removeValue(forKey: key) else { return }
        for continuation in completed.subscribers.values { continuation.resume(returning: result) }
    }
    private func cancel(_ key: Key, subscriber: UUID) {
        guard let continuation = work[key]?.subscribers.removeValue(forKey: subscriber) else { return }
        continuation.resume(returning: nil)
        if work[key]?.subscribers.isEmpty == true { work.removeValue(forKey: key)?.task.cancel() }
    }
    func clear() {
        let pending = work.values; work.removeAll()
        for value in pending {
            value.task.cancel()
            for continuation in value.subscribers.values { continuation.resume(returning: nil) }
        }
    }
}

actor AsyncWorkLimiter {
    private let limit: Int
    private var active = 0
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    init(limit: Int) { self.limit = max(1, limit) }

    func run<Value: Sendable>(_ operation: @Sendable () async -> Value?) async -> Value? {
        let id = UUID()
        let admitted = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            if active < limit { active += 1; return true }
            return await withCheckedContinuation { waiters[id] = $0; order.append(id) }
        } onCancel: { Task { await self.cancel(id) } }
        guard admitted else { return nil }
        let result = Task.isCancelled ? nil : await operation()
        release()
        return Task.isCancelled ? nil : result
    }
    private func cancel(_ id: UUID) {
        order.removeAll { $0 == id }
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }
    private func release() {
        while !order.isEmpty {
            if let waiter = waiters.removeValue(forKey: order.removeFirst()) {
                waiter.resume(returning: true)
                return
            }
        }
        active -= 1
    }
}
