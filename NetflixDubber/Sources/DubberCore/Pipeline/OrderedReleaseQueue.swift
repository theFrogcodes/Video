import Foundation

/// Releases results in sequence order even when they finish out of order.
///
/// Lines are processed concurrently (a short line's translation can finish
/// before a longer earlier one), but dubs must play in the order spoken.
/// A `nil` result marks a line that produced no audio so it doesn't block.
public struct OrderedReleaseQueue<Element> {
    public private(set) var nextSequence: Int
    private var completed: [Int: Element?] = [:]

    public init(startingAt sequence: Int = 0) {
        nextSequence = sequence
    }

    /// Number of finished results waiting on an earlier sequence number.
    public var waitingCount: Int { completed.count }

    /// Records a result. Results for sequences already skipped past are ignored.
    public mutating func complete(_ sequence: Int, with value: Element?) -> [Element] {
        guard sequence >= nextSequence else { return [] }
        completed[sequence] = .some(value)
        return drain()
    }

    /// Gives up on everything before `sequence` (e.g. a stuck request) and
    /// releases whatever is ready from there on.
    public mutating func skip(upTo sequence: Int) -> [Element] {
        guard sequence > nextSequence else { return [] }
        for key in completed.keys where key < sequence {
            completed.removeValue(forKey: key)
        }
        nextSequence = sequence
        return drain()
    }

    /// Lowest sequence number that has finished but is still waiting.
    public var earliestWaiting: Int? { completed.keys.min() }

    private mutating func drain() -> [Element] {
        var released: [Element] = []
        while let entry = completed.removeValue(forKey: nextSequence) {
            if let value = entry { released.append(value) }
            nextSequence += 1
        }
        return released
    }
}
