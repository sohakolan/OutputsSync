import Foundation
import Network

/// Horloge partagée de la room. `offsetNanos` = heure-room − heure-locale ; sur
/// le maître il vaut 0. Lu sans verrou par le thread audio.
final class RoomClock: Sendable {
    private let offset = AtomicInt64(0)

    var offsetNanos: Int64 { offset.load() }
    func setOffset(_ v: Int64) { offset.store(v) }

    /// Heure-room correspondant à un temps-hôte CoreAudio.
    @inline(__always)
    func roomTime(fromHostTime host: UInt64) -> Int64 {
        HostClock.nanos(fromHostTime: host) + offset.load()
    }

    /// Instant courant, en heure-room.
    @inline(__always)
    func roomNow() -> Int64 { HostClock.nowNanos() + offset.load() }

    /// Temps-hôte local correspondant à une heure-room de présentation.
    @inline(__always)
    func hostTime(fromRoomTime room: Int64) -> UInt64 {
        HostClock.hostTime(fromNanos: room - offset.load())
    }
}

// MARK: - Wire format (ping/pong)

private enum ClockWire {
    static let magic: UInt32 = 0x4F53434C // "OSCL"
    static let querySize = 12
    static let replySize = 28

    static func query(t0: Int64) -> Data {
        var d = Data(capacity: querySize)
        appendLE(&d, magic); appendLE(&d, t0)
        return d
    }
    static func reply(t0: Int64, t1: Int64, t2: Int64) -> Data {
        var d = Data(capacity: replySize)
        appendLE(&d, magic); appendLE(&d, t0); appendLE(&d, t1); appendLE(&d, t2)
        return d
    }
    static func parseQuery(_ d: Data) -> Int64? {
        guard d.count >= querySize else { return nil }
        return d.withUnsafeBytes { raw in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == magic else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
        }
    }
    static func parseReply(_ d: Data) -> (Int64, Int64, Int64)? {
        guard d.count >= replySize else { return nil }
        return d.withUnsafeBytes { raw in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == magic else { return nil }
            return (raw.loadUnaligned(fromByteOffset: 4, as: Int64.self),
                    raw.loadUnaligned(fromByteOffset: 12, as: Int64.self),
                    raw.loadUnaligned(fromByteOffset: 20, as: Int64.self))
        }
    }
    static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}

// MARK: - Maître : répond aux pings

/// Le maître de la room héberge l'horloge : il répond à chaque ping en
/// horodatant réception (t1) et émission (t2) avec sa propre horloge locale.
final class ClockSyncServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.outputssync.clock.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var port: UInt16 = 0
    var onReady: ((UInt16) -> Void)?

    func start() {
        do {
            let l = try NWListener(using: .udp)
            listener = l
            l.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self, let p = l.port else { return }
                self.port = p.rawValue
                self.onReady?(p.rawValue)
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
        } catch {
            NSLog("ClockSyncServer start failed: \(error)")
        }
    }

    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections[ObjectIdentifier(conn)] = nil }
            if case .failed = state { self?.connections[ObjectIdentifier(conn)] = nil }
        }
        conn.start(queue: queue)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data, let t0 = ClockWire.parseQuery(data) {
                let t1 = HostClock.nowNanos()
                let t2 = HostClock.nowNanos()
                conn.send(content: ClockWire.reply(t0: t0, t1: t1, t2: t2),
                          completion: .idempotent)
            }
            if error == nil { self?.receive(conn) }
        }
    }

    func stop() {
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
    }
}

// MARK: - Client : ping le maître et estime l'offset

/// Estime `offset` (heure-room − heure-locale) par échanges NTP-like. Conserve
/// l'échantillon de RTT minimal sur une fenêtre glissante, puis lisse (EMA).
final class ClockSyncClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.outputssync.clock.client")
    private let clock: RoomClock
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?

    private var window: [(rtt: Int64, offset: Int64)] = []
    private var smoothed: Int64?
    private(set) var converged = false
    var onOffset: ((Int64, Int64) -> Void)? // (offset, rtt) pour l'UI

    init(clock: RoomClock) { self.clock = clock }

    func start(host: NWEndpoint.Host, port: UInt16) {
        let conn = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection = conn
        conn.start(queue: queue)
        receive(conn)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.ping() }
        t.resume()
        timer = t
    }

    private func ping() {
        guard let conn = connection else { return }
        let t0 = HostClock.nowNanos()
        conn.send(content: ClockWire.query(t0: t0), completion: .idempotent)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data, let (t0, t1, t2) = ClockWire.parseReply(data) {
                self?.consume(t0: t0, t1: t1, t2: t2, t3: HostClock.nowNanos())
            }
            if error == nil { self?.receive(conn) }
        }
    }

    private func consume(t0: Int64, t1: Int64, t2: Int64, t3: Int64) {
        let rtt = (t3 - t0) - (t2 - t1)
        let offset = ((t1 - t0) + (t2 - t3)) / 2
        guard rtt >= 0 else { return }

        window.append((rtt, offset))
        if window.count > 16 { window.removeFirst() }
        let best = window.min { $0.rtt < $1.rtt }!.offset

        // EMA pour éviter les sauts brusques une fois convergé.
        if let s = smoothed {
            smoothed = Int64(Double(s) * 0.8 + Double(best) * 0.2)
        } else {
            smoothed = best
        }
        clock.setOffset(smoothed!)
        if window.count >= 4 { converged = true }
        onOffset?(smoothed!, window.min { $0.rtt < $1.rtt }!.rtt)
    }

    func stop() {
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
    }
}
