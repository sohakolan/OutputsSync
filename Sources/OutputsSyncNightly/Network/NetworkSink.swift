import AudioToolbox
import CoreAudio
import Foundation
import Network
import os

/// Un flux distant reçu : réception UDP → `PlayoutBuffer`, avec gain, délai
/// utilisateur et délai de playout adaptatif. Ne pilote **pas** la sortie ;
/// c'est l'`OutputMixer` qui l'appelle pour rendre dans le buffer de sortie.
final class NetworkStream: @unchecked Sendable {
    let peerID: String
    private let playout = PlayoutBuffer()
    private let netQueue = DispatchQueue(label: "com.outputssync.stream.net")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var audioPort: UInt16 = 0
    var onReady: ((UInt16) -> Void)?

    private let gain = AtomicDouble(1.0)
    private let delayMs = AtomicDouble(0)
    private let playoutDelayNanos = AtomicInt64(80_000_000)

    // Délai adaptatif.
    private var adaptTimer: DispatchSourceTimer?
    private var lastUnderrun: Int64 = 0
    private var stableTicks = 0
    private let floorNanos: Int64 = 40_000_000
    private let capNanos: Int64 = 400_000_000

    init(peerID: String, outputRate: Double) {
        self.peerID = peerID
        playout.setOutputRate(outputRate)
    }

    func setVolume(_ v: Double) { gain.store(v) }
    func setDelayMs(_ v: Double) { delayMs.store(max(0, v)) }

    /// Démarre la réception UDP ; `onReady(port)` fournit le port à annoncer à
    /// l'émetteur via `subscribe`.
    func startReceiving() -> Bool {
        do {
            let l = try NWListener(using: .udp)
            listener = l
            l.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self, let p = l.port else { return }
                self.audioPort = p.rawValue
                self.onReady?(p.rawValue)
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: netQueue)
        } catch {
            NSLog("NetworkStream listener failed: \(error)")
            return false
        }
        startAdaptiveDelay()
        return true
    }

    /// Rendu (thread audio) : écrit `frames` frames **stéréo** dans `outStereo`.
    @inline(__always)
    func render(intoStereo outStereo: UnsafeMutablePointer<Float>, frames: Int,
                outHostTime: UInt64, clock: RoomClock, deviceLatencyNanos: Int64) {
        playout.render(
            out: outStereo, outChannels: 2, frames: frames, outHostTime: outHostTime,
            clock: clock, gain: Float(gain.load()),
            playoutDelayNanos: playoutDelayNanos.load(),
            userDelayNanos: Int64(delayMs.load() * 1_000_000),
            deviceLatencyNanos: deviceLatencyNanos)
    }

    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.connections[ObjectIdentifier(conn)] = nil
            default: break
            }
        }
        conn.start(queue: netQueue)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data, let pkt = AudioPacket.parse(data) {
                self?.playout.push(samples: pkt.samples, frames: pkt.frameCount,
                                   sampleRate: Double(pkt.sampleRate),
                                   captureRoomTime: pkt.captureRoomTimeNanos)
            }
            if error == nil { self?.receive(conn) }
        }
    }

    private func startAdaptiveDelay() {
        let t = DispatchSource.makeTimerSource(queue: netQueue)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.playout.underrunCount
            if now > self.lastUnderrun {
                playoutDelayNanos.store(min(capNanos, playoutDelayNanos.load() + 15_000_000))
                stableTicks = 0
            } else {
                stableTicks += 1
                if stableTicks >= 20 {
                    playoutDelayNanos.store(max(floorNanos, playoutDelayNanos.load() - 5_000_000))
                    stableTicks = 0
                }
            }
            lastUnderrun = now
        }
        t.resume()
        adaptTimer = t
    }

    func stop() {
        adaptTimer?.cancel(); adaptTimer = nil
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        playout.reset()
    }
}

/// Un IOProc de sortie par périphérique, qui **mixe** tous les `NetworkStream`
/// dirigés vers ce périphérique (écouter plusieurs Mac sur la même sortie).
final class OutputMixer: @unchecked Sendable {
    let deviceUID: String
    private(set) var outputRate: Double = 48_000

    private let clock: RoomClock
    private var deviceID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var deviceLatencyNanos: Int64 = 0

    private let maxFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>
    private let lock = OSAllocatedUnfairLock()
    private var streams: [NetworkStream] = []

    init(clock: RoomClock, device: AudioDeviceInfo) {
        self.clock = clock
        deviceUID = device.uid
        scratch = .allocate(capacity: maxFrames * 2)
        scratch.initialize(repeating: 0, count: maxFrames * 2)
    }

    deinit { scratch.deallocate() }

    func start(device: AudioDeviceInfo) -> Bool {
        deviceID = device.id
        outputRate = AudioDevices.nominalSampleRate(device.id)
        deviceLatencyNanos = Int64(Double(AudioDevices.outputLatencyFrames(device.id)) / outputRate * 1e9)

        let block: AudioDeviceIOBlock = { [weak self] _, _, _, outOutputData, inOutputTime in
            guard let self else { return }
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard output.count > 0, let raw0 = output[0].mData else { return }
            let ch = max(Int(output[0].mNumberChannels), 1)
            let frames = Int(output[0].mDataByteSize) / (ch * MemoryLayout<Float>.size)
            self.renderMix(out: raw0.assumingMemoryBound(to: Float.self), channels: ch,
                           frames: frames, outHostTime: inOutputTime.pointee.mHostTime)
            for i in 1..<output.count {
                if let m = output[i].mData { memset(m, 0, Int(output[i].mDataByteSize)) }
            }
        }

        var pid: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, nil, block) == noErr, let pid else {
            return false
        }
        procID = pid
        guard AudioDeviceStart(deviceID, pid) == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, pid); procID = nil
            return false
        }
        return true
    }

    private func renderMix(out: UnsafeMutablePointer<Float>, channels ch: Int, frames: Int, outHostTime: UInt64) {
        for i in 0..<(frames * ch) { out[i] = 0 }
        let n = min(frames, maxFrames)
        lock.lock()
        for stream in streams {
            stream.render(intoStereo: scratch, frames: n, outHostTime: outHostTime,
                          clock: clock, deviceLatencyNanos: deviceLatencyNanos)
            for f in 0..<n {
                let l = scratch[f * 2], r = scratch[f * 2 + 1]
                let base = f * ch
                for c in 0..<ch { out[base + c] += (c & 1) == 0 ? l : r }
            }
        }
        lock.unlock()
        for i in 0..<(frames * ch) { out[i] = min(max(out[i], -1.0), 1.0) }
    }

    func addStream(_ s: NetworkStream) {
        lock.lock(); streams.append(s); lock.unlock()
    }

    /// Retire le flux d'un peer. Renvoie `true` s'il était présent.
    @discardableResult
    func removeStream(peerID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = streams.firstIndex(where: { $0.peerID == peerID }) else { return false }
        streams.remove(at: i)
        return true
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return streams.isEmpty
    }

    func stop() {
        if deviceID != 0, let pid = procID {
            AudioDeviceStop(deviceID, pid)
            AudioDeviceDestroyIOProcID(deviceID, pid)
        }
        procID = nil; deviceID = 0
        lock.lock(); streams.removeAll(); lock.unlock()
    }
}
