import Foundation
import Synchronization

/// Scalaires partagés entre threads (réseau/horloge ↔ audio temps-réel) sans
/// verrou. `Atomic` du module Synchronization garantit des accès sans déchirure ;
/// le chemin temps-réel ne fait qu'un `load` relaxé.
final class AtomicDouble: Sendable {
    private let bits: Atomic<UInt64>
    init(_ value: Double = 0) { bits = Atomic(value.bitPattern) }
    @inline(__always) func store(_ v: Double) { bits.store(v.bitPattern, ordering: .relaxed) }
    @inline(__always) func load() -> Double { Double(bitPattern: bits.load(ordering: .relaxed)) }
}

final class AtomicInt64: Sendable {
    private let value: Atomic<Int64>
    init(_ v: Int64 = 0) { value = Atomic(v) }
    @inline(__always) func store(_ v: Int64) { value.store(v, ordering: .relaxed) }
    @inline(__always) func load() -> Int64 { value.load(ordering: .relaxed) }
    /// Publication ordonnée : le producteur écrit les données puis publie
    /// l'index en `release` ; le consommateur le lit en `acquire`.
    @inline(__always) func storeRelease(_ v: Int64) { value.store(v, ordering: .releasing) }
    @inline(__always) func loadAcquire() -> Int64 { value.load(ordering: .acquiring) }
    @inline(__always) func add(_ v: Int64) { value.wrappingAdd(v, ordering: .relaxed) }
}

final class AtomicBool: Sendable {
    private let value: Atomic<Bool>
    init(_ v: Bool = false) { value = Atomic(v) }
    @inline(__always) func store(_ v: Bool) { value.store(v, ordering: .relaxed) }
    @inline(__always) func load() -> Bool { value.load(ordering: .relaxed) }
}
