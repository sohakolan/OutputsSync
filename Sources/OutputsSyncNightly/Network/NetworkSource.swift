import AudioToolbox
import CoreAudio
import Foundation
import Network

/// Ring SPSC de « chunks » audio : le producteur est l'IOProc de capture
/// (temps-réel), le consommateur est le thread réseau. Chaque slot porte des
/// frames stéréo entrelacées + l'heure-room de la 1ʳᵉ frame.
private final class ChunkRing: @unchecked Sendable {
    let slots: Int
    let frameCap: Int
    private let bufs: UnsafeMutablePointer<Float>
    private let roomTimes: UnsafeMutablePointer<Int64>
    private let counts: UnsafeMutablePointer<Int32>
    private let write = AtomicInt64(0)
    private let read = AtomicInt64(0)

    init(slots: Int = 64, frameCap: Int = 8192) {
        self.slots = slots
        self.frameCap = frameCap
        bufs = .allocate(capacity: slots * frameCap * 2)
        roomTimes = .allocate(capacity: slots)
        counts = .allocate(capacity: slots)
        bufs.initialize(repeating: 0, count: slots * frameCap * 2)
        roomTimes.initialize(repeating: 0, count: slots)
        counts.initialize(repeating: 0, count: slots)
    }

    deinit { bufs.deallocate(); roomTimes.deallocate(); counts.deallocate() }

    /// Producteur (thread audio) : downmix vers stéréo dans le prochain slot.
    @inline(__always)
    func push(_ src: UnsafePointer<Float>, srcChannels: Int, frames: Int, roomTime: Int64) {
        let w = write.load(), r = read.load()
        if w - r >= Int64(slots) { return } // plein : on lâche (ne devrait pas arriver)
        let slot = Int(w % Int64(slots))
        let dst = bufs + slot * frameCap * 2
        let n = min(frames, frameCap)
        let c1 = srcChannels > 1 ? 1 : 0
        for f in 0..<n {
            dst[f * 2] = src[f * srcChannels]
            dst[f * 2 + 1] = src[f * srcChannels + c1]
        }
        roomTimes[slot] = roomTime
        counts[slot] = Int32(n)
        write.store(w + 1)
    }

    /// Consommateur (thread réseau) : traite tous les slots disponibles.
    func consume(_ body: (UnsafePointer<Float>, Int, Int64) -> Void) {
        var r = read.load()
        let w = write.load()
        while r < w {
            let slot = Int(r % Int64(slots))
            body(bufs + slot * frameCap * 2, Int(counts[slot]), roomTimes[slot])
            r += 1
        }
        read.store(r)
    }
}

/// Émetteur : capte le son système (driver loopback), horodate en heure-room et
/// diffuse en UDP vers les abonnés, en paquets ≤ `maxPacketFrames` (sous la MTU).
final class NetworkSource: @unchecked Sendable {
    static let maxPacketFrames = 128 // 128×2×4 = 1024 o de payload

    private let clock: RoomClock
    private let ring = ChunkRing()
    private let senderQueue = DispatchQueue(label: "com.outputssync.source.sender")
    private var timer: DispatchSourceTimer?

    private var deviceID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var subscribers: [String: NWConnection] = [:] // peerID → UDP
    private var seq: UInt32 = 0
    private var sampleRate: UInt32 = 48_000

    private(set) var isRunning = false

    init(clock: RoomClock) { self.clock = clock }

    func start(loopback: AudioDeviceInfo) -> Bool {
        stop()
        deviceID = loopback.id
        sampleRate = UInt32(AudioDevices.nominalSampleRate(loopback.id))

        let ring = self.ring
        let clock = self.clock
        let block: AudioDeviceIOBlock = { _, inInputData, inInputTime, outOutputData, _ in
            // On est aussi client de sortie du loopback : écrire du silence pour
            // ne pas réinjecter de bruit dans le mix rebouclé.
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)
            for buf in output { if let m = buf.mData { memset(m, 0, Int(buf.mDataByteSize)) } }

            let input = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard input.count > 0, let raw = input[0].mData else { return }
            let channels = max(Int(input[0].mNumberChannels), 1)
            let frames = Int(input[0].mDataByteSize) / (channels * MemoryLayout<Float>.size)
            let roomTime = clock.roomTime(fromHostTime: inInputTime.pointee.mHostTime)
            ring.push(raw.assumingMemoryBound(to: Float.self),
                      srcChannels: channels, frames: frames, roomTime: roomTime)
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

        let t = DispatchSource.makeTimerSource(queue: senderQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
        isRunning = true
        return true
    }

    private func flush() {
        let sr = Double(sampleRate)
        ring.consume { [weak self] ptr, frames, roomTime in
            guard let self, frames > 0 else { return }
            var offset = 0
            while offset < frames {
                let n = min(NetworkSource.maxPacketFrames, frames - offset)
                let ts = roomTime + Int64((Double(offset) / sr) * 1_000_000_000)
                let data = AudioPacket.encode(
                    seq: self.seq, sampleRate: self.sampleRate, channels: 2,
                    captureRoomTimeNanos: ts, samples: ptr + offset * 2, frameCount: n)
                self.seq &+= 1
                for conn in self.subscribers.values {
                    conn.send(content: data, completion: .idempotent)
                }
                offset += n
            }
        }
    }

    // MARK: abonnés

    func addSubscriber(peerID: String, host: NWEndpoint.Host, port: UInt16) {
        senderQueue.async {
            self.subscribers[peerID]?.cancel()
            let conn = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .udp)
            conn.start(queue: self.senderQueue)
            self.subscribers[peerID] = conn
        }
    }

    func removeSubscriber(peerID: String) {
        senderQueue.async {
            self.subscribers[peerID]?.cancel()
            self.subscribers[peerID] = nil
        }
    }

    var subscriberCount: Int { subscribers.count }

    /// Arrête la capture, mais **conserve** les abonnés (toggle d'émission).
    func stop() {
        timer?.cancel(); timer = nil
        if deviceID != 0, let pid = procID {
            AudioDeviceStop(deviceID, pid)
            AudioDeviceDestroyIOProcID(deviceID, pid)
        }
        procID = nil
        deviceID = 0
        isRunning = false
    }

    /// Démontage complet : arrête la capture et libère les abonnés.
    func teardown() {
        stop()
        senderQueue.async {
            self.subscribers.values.forEach { $0.cancel() }
            self.subscribers.removeAll()
        }
    }
}
