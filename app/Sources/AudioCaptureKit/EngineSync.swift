import EngineSync
import os

/// The few atomic operations the engine needs, on macOS 14 (Swift's `Synchronization` needs 15).
/// One lock-free 64-bit word each, C11 underneath; the same call shapes as `Synchronization.Atomic`.
public struct AtomicOrder: Sendable {
    let raw: Int32
    public static let relaxed = AtomicOrder(raw: 0)
    public static let acquiring = AtomicOrder(raw: 2)
    public static let releasing = AtomicOrder(raw: 3)
}

public protocol AtomicWord {
    var bits: UInt64 { get }
    init(bits: UInt64)
}
extension Int: AtomicWord { public var bits: UInt64 { UInt64(bitPattern: Int64(self)) }; public init(bits: UInt64) { self = Int(Int64(bitPattern: bits)) } }
extension UInt64: AtomicWord { public var bits: UInt64 { self }; public init(bits: UInt64) { self = bits } }
extension UInt32: AtomicWord { public var bits: UInt64 { UInt64(self) }; public init(bits: UInt64) { self = UInt32(truncatingIfNeeded: bits) } }
extension Bool: AtomicWord { public var bits: UInt64 { self ? 1 : 0 }; public init(bits: UInt64) { self = bits != 0 } }

public final class Atomic<Value: AtomicWord>: @unchecked Sendable {
    private let word = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    public init(_ value: Value) { word.initialize(to: value.bits) }
    deinit { word.deallocate() }

    @inline(__always) public func load(ordering: AtomicOrder) -> Value { Value(bits: ac_load(word, ordering.raw)) }
    @inline(__always) public func store(_ value: Value, ordering: AtomicOrder) { ac_store(word, value.bits, ordering.raw) }
    @inline(__always) @discardableResult
    public func exchange(_ value: Value, ordering: AtomicOrder) -> Value { Value(bits: ac_exchange(word, value.bits, ordering.raw)) }
    @inline(__always) public func compareExchange(expected: Value, desired: Value, ordering: AtomicOrder) -> (exchanged: Bool, original: Value) {
        var current = expected.bits
        let done = ac_compare_exchange(word, &current, desired.bits, ordering.raw)
        return (done, Value(bits: current))
    }
}
extension Atomic where Value == Int {
    @inline(__always) public func wrappingAdd(_ delta: Int, ordering: AtomicOrder) { _ = ac_fetch_add(word, delta.bits, ordering.raw) }
}

/// A value behind an unfair lock; the same `withLock` shape as `Synchronization.Mutex`.
public final class Mutex<Value>: @unchecked Sendable {
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var value: Value
    public init(_ value: Value) { self.value = value; lock.initialize(to: os_unfair_lock()) }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return try body(&value)
    }
}
