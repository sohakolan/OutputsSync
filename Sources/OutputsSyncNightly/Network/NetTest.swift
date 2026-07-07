import Foundation
import Network

/// Vérification headless du stack réseau (phases 0-1), sans matériel audio :
/// horloge commune (loopback), handshake PIN, découverte Bonjour.
/// Lancé via `OutputsSyncNightly --nettest`.
enum NetTest {
    private static func wait(_ sem: DispatchSemaphore, _ seconds: Double) -> Bool {
        sem.wait(timeout: .now() + seconds) == .success
    }
    private static func loopback(_ port: UInt16) -> NWEndpoint {
        .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    }

    static func run() -> Int32 {
        var failures = 0

        // MARK: 1) Horloge commune sur loopback → offset ≈ 0
        do {
            let clock = RoomClock()
            let server = ClockSyncServer()
            let portSem = DispatchSemaphore(value: 0)
            let port = UnsafeMutableBox<UInt16>(0)
            server.onReady = { p in port.value = p; portSem.signal() }
            server.start()
            guard wait(portSem, 3) else { print("❌ horloge: serveur pas prêt"); return 1 }

            let client = ClockSyncClient(clock: clock)
            let doneSem = DispatchSemaphore(value: 0)
            let last = UnsafeMutableBox<(Int64, Int64, Int)>((0, 0, 0))
            client.onOffset = { off, rtt in
                last.value = (off, rtt, last.value.2 + 1)
                if last.value.2 >= 5 { doneSem.signal() }
            }
            client.start(host: .ipv4(.loopback), port: port.value)
            guard wait(doneSem, 6) else { print("❌ horloge: pas de convergence"); server.stop(); return 1 }
            let (offset, rtt, _) = last.value
            client.stop(); server.stop()

            if abs(offset) < 1_000_000, rtt >= 0, rtt < 100_000_000 {
                print(String(format: "✅ horloge: offset %.3f ms, RTT %.3f ms (loopback)",
                             Double(offset) / 1e6, Double(rtt) / 1e6))
            } else {
                print("❌ horloge: valeurs hors bornes (offset \(offset) ns, RTT \(rtt) ns)")
                failures += 1
            }
        }

        // MARK: 2) Handshake PIN (bon → welcome, mauvais → reject)
        do {
            let server = ControlServer()
            let portSem = DispatchSemaphore(value: 0)
            let port = UnsafeMutableBox<UInt16>(0)
            let keep = UnsafeMutableBox<[ControlLink]>([])
            server.onReady = { p in port.value = p; portSem.signal() }
            server.onAccept = { link in
                keep.value.append(link)
                link.onMessage = { msg in
                    guard msg.type == .hello else { return }
                    if msg.pin == "1234" {
                        link.send(ControlMessage(type: .welcome, name: "srv", peerID: "srv",
                                                 isMaster: true, clockPort: 0))
                    } else {
                        link.send(ControlMessage(type: .reject, reason: "PIN incorrect"))
                    }
                }
            }
            server.start()
            guard wait(portSem, 3) else { print("❌ contrôle: serveur pas prêt"); return 1 }
            let q = DispatchQueue(label: "nettest.client")

            // Bon PIN.
            let good = ControlLink(endpoint: loopback(port.value), queue: q)
            let gSem = DispatchSemaphore(value: 0)
            let gWelcome = UnsafeMutableBox<Bool>(false)
            good.onReady = { good.send(ControlMessage(type: .hello, pin: "1234", name: "cli",
                                                      peerID: "cli", isMaster: false)) }
            good.onMessage = { msg in
                if msg.type == .welcome { gWelcome.value = true }
                gSem.signal()
            }
            good.start()
            _ = wait(gSem, 3)

            // Mauvais PIN.
            let bad = ControlLink(endpoint: loopback(port.value), queue: q)
            let bSem = DispatchSemaphore(value: 0)
            let bReject = UnsafeMutableBox<Bool>(false)
            bad.onReady = { bad.send(ControlMessage(type: .hello, pin: "0000", name: "cli2",
                                                    peerID: "cli2", isMaster: false)) }
            bad.onMessage = { msg in
                if msg.type == .reject { bReject.value = true }
                bSem.signal()
            }
            bad.start()
            _ = wait(bSem, 3)

            good.cancel(); bad.cancel(); server.stop()
            if gWelcome.value && bReject.value {
                print("✅ contrôle: bon PIN → welcome, mauvais PIN → reject")
            } else {
                print("❌ contrôle: welcome=\(gWelcome.value) reject=\(bReject.value)")
                failures += 1
            }
        }

        // MARK: 3) Découverte Bonjour (best-effort — peut être bloquée en terminal)
        do {
            let server = ControlServer()
            let portSem = DispatchSemaphore(value: 0)
            server.onReady = { _ in portSem.signal() }
            server.start()
            _ = wait(portSem, 3)
            server.advertise(name: "nettest-\(Int.random(in: 1000...9999))", txt: [
                "room": "testroom", "peer": "srvpeer", "name": "srv", "master": "1",
                "pin": "1", "clk": "0",
            ])
            // Browse-all (lobby, room: nil) : doit voir la room + son flag PIN.
            let disc = RoomDiscovery(myPeerID: "browserpeer", room: nil)
            let dSem = DispatchSemaphore(value: 0)
            let found = UnsafeMutableBox<Bool>(false)
            disc.onPeersChanged = { peers in
                if peers.contains(where: { $0.peerID == "srvpeer" && $0.room == "testroom" && $0.needsPIN }) {
                    found.value = true; dSem.signal()
                }
            }
            disc.start()
            _ = wait(dSem, 6)
            disc.stop(); server.stop()
            if found.value {
                print("✅ découverte lobby: room « testroom » vue (browse-all + flag PIN OK)")
            } else {
                print("⚠️  découverte: non trouvé en 6 s (permission « réseau local » du terminal ?). Non bloquant.")
            }
        }

        // MARK: 4) Round-trip du paquet audio (format binaire)
        do {
            let n = 300
            var samples = [Float](repeating: 0, count: n * 2)
            for i in 0..<n { samples[i * 2] = Float(i) / 1000; samples[i * 2 + 1] = -Float(i) / 1000 }
            let data = samples.withUnsafeBufferPointer {
                AudioPacket.encode(seq: 7, sampleRate: 48_000, channels: 2,
                                   captureRoomTimeNanos: 123_456_789, samples: $0.baseAddress!, frameCount: n)
            }
            if let p = AudioPacket.parse(data),
               p.seq == 7, p.frameCount == n, p.channels == 2,
               p.captureRoomTimeNanos == 123_456_789, p.samples.count == n * 2,
               abs(p.samples[299 * 2] - 0.299) < 1e-6, abs(p.samples[299 * 2 + 1] + 0.299) < 1e-6 {
                print("✅ paquet: encode/parse bit-perfect (300 frames)")
            } else {
                print("❌ paquet: round-trip incorrect"); failures += 1
            }
        }

        // MARK: 5) Programmation du PlayoutBuffer sur l'heure-room
        do {
            let pb = PlayoutBuffer()
            pb.setOutputRate(48_000)
            let clock = RoomClock() // offset 0 → heure-room = heure-locale
            let frames = 2000
            var ramp = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames { let v = Float(i) / Float(frames); ramp[i * 2] = v; ramp[i * 2 + 1] = v }
            pb.push(samples: ramp, frames: frames, sampleRate: 48_000, captureRoomTime: 0)

            let outFrames = 128
            var out = [Float](repeating: -9, count: outFrames * 2)
            // Viser une capture de 20 ms → échantillon ≈ 960 → rampe ≈ 0.48.
            let outHost = HostClock.hostTime(fromNanos: 20_000_000)
            out.withUnsafeMutableBufferPointer { buf in
                pb.render(out: buf.baseAddress!, outChannels: 2, frames: outFrames,
                          outHostTime: outHost, clock: clock, gain: 1.0,
                          playoutDelayNanos: 0, userDelayNanos: 0, deviceLatencyNanos: 0)
            }
            if abs(out[0] - 0.48) < 0.03, abs(out[1] - 0.48) < 0.03 {
                print(String(format: "✅ playout: lecture programmée correcte (échantillon %.3f ≈ 0.48)", out[0]))
            } else {
                print(String(format: "❌ playout: sortie inattendue (%.3f)", out[0])); failures += 1
            }
        }

        // MARK: 6) Round-trip des messages de contrôle (push + settings)
        do {
            let msg = ControlMessage(type: .requestPlay, volume: 0.6, delayMs: 120)
            let settings = ControlMessage(type: .streamSettings, volume: 0.3)
            if let d1 = try? JSONEncoder().encode(msg),
               let r1 = try? JSONDecoder().decode(ControlMessage.self, from: d1),
               let d2 = try? JSONEncoder().encode(settings),
               let r2 = try? JSONDecoder().decode(ControlMessage.self, from: d2),
               r1.type == .requestPlay, r1.volume == 0.6, r1.delayMs == 120,
               r2.type == .streamSettings, r2.volume == 0.3, r2.delayMs == nil {
                print("✅ contrôle push: requestPlay + streamSettings round-trip OK")
            } else {
                print("❌ contrôle push: round-trip incorrect"); failures += 1
            }
        }

        print(failures == 0 ? "\n✅ NetTest OK" : "\n❌ NetTest: \(failures) échec(s)")
        return failures == 0 ? 0 : 1
    }
}

/// Boîte mutable de référence pour partager un scalaire entre closures et fil
/// principal dans le test (pas de contrainte temps-réel ici).
private final class UnsafeMutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
