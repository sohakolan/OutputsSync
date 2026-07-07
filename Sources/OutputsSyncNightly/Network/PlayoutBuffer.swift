import Foundation

/// Buffer de lecture d'un flux distant. Producteur = queue réseau (push des
/// paquets décodés). Consommateur = IOProc de sortie (`render`), qui programme
/// la lecture sur l'**instant de présentation** en heure-room et se verrouille
/// sur le timeline via un resampler DLL (correction de dérive de débit).
///
/// Mapping temps : heure-room de l'échantillon `i` = `nextWriteRoomTime` −
/// (`writeIndex` − i) / srcRate × 1e9.
final class PlayoutBuffer: @unchecked Sendable {
    private let capacity: Int         // frames, puissance de 2
    private let mask: Int
    private let ring: UnsafeMutablePointer<Float> // stéréo entrelacé

    // Partagés producteur → consommateur.
    private let writeIndex = AtomicInt64(0)
    private let nextWriteRoomTime = AtomicInt64(0)
    private let srcRateBits = AtomicDouble(48_000)
    private let underruns = AtomicInt64(0)
    private let hasData = AtomicBool(false)

    // Consommateur uniquement (thread audio).
    private var readPos: Double = 0
    private var readInit = false
    private var outRate: Double = 48_000

    // Producteur uniquement (queue réseau).
    private var prodWrite: Int64 = 0
    private var prodRoomTime: Int64 = 0
    private var prodInit = false

    // Réglages DLL.
    private let kP = 2.0e-5
    private let maxRate = 0.03

    init(capacityFrames: Int = 1 << 18) {
        capacity = capacityFrames
        mask = capacityFrames - 1
        ring = .allocate(capacity: capacityFrames * 2)
        ring.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { ring.deallocate() }

    func setOutputRate(_ r: Double) { outRate = r }
    var underrunCount: Int64 { underruns.load() }

    // MARK: producteur (queue réseau)

    /// Insère un paquet de `frames` frames stéréo horodaté `captureRoomTime`.
    func push(samples: [Float], frames: Int, sampleRate: Double, captureRoomTime: Int64) {
        guard frames > 0 else { return }
        srcRateBits.store(sampleRate)

        if !prodInit {
            prodInit = true
            prodWrite = 0
            prodRoomTime = captureRoomTime
        } else {
            // Écart entre l'heure attendue et l'heure du paquet.
            let gapNanos = captureRoomTime - prodRoomTime
            let tol: Int64 = 5_000_000 // 5 ms
            if gapNanos > tol {
                // Trou : comble de silence pour garder le mapping linéaire.
                let gapFrames = min(Int(Double(gapNanos) * sampleRate / 1e9), capacity / 2)
                writeSilence(gapFrames)
                prodRoomTime += Int64(Double(gapFrames) / sampleRate * 1e9)
            } else if gapNanos < -tol {
                // Redémarrage/gros désordre : on ré-ancre.
                prodRoomTime = captureRoomTime
            }
        }

        samples.withUnsafeBufferPointer { buf in
            let src = buf.baseAddress!
            for f in 0..<frames {
                let slot = (Int(prodWrite) + f) & mask
                ring[slot * 2] = src[f * 2]
                ring[slot * 2 + 1] = src[f * 2 + 1]
            }
        }
        prodWrite += Int64(frames)
        prodRoomTime += Int64(Double(frames) / sampleRate * 1e9)
        nextWriteRoomTime.store(prodRoomTime)
        writeIndex.storeRelease(prodWrite)
        hasData.store(true)
    }

    private func writeSilence(_ frames: Int) {
        guard frames > 0 else { return }
        for f in 0..<frames {
            let slot = (Int(prodWrite) + f) & mask
            ring[slot * 2] = 0
            ring[slot * 2 + 1] = 0
        }
        prodWrite += Int64(frames)
    }

    // MARK: consommateur (IOProc de sortie)

    /// Écrit `frames` frames dans `out` (`outChannels`) pour l'instant hôte
    /// `outHostTime`, avec gain, en visant `capture = présentation − délais`.
    func render(
        out: UnsafeMutablePointer<Float>, outChannels: Int, frames: Int,
        outHostTime: UInt64, clock: RoomClock, gain: Float,
        playoutDelayNanos: Int64, userDelayNanos: Int64, deviceLatencyNanos: Int64
    ) {
        func silence() {
            for i in 0..<(frames * outChannels) { out[i] = 0 }
        }
        guard hasData.load() else { silence(); return }

        let w = writeIndex.loadAcquire()
        let wRoom = nextWriteRoomTime.load()
        let srcRate = srcRateBits.load()
        guard srcRate > 0, outRate > 0 else { silence(); return }

        // Instant acoustique de la 1ʳᵉ frame, en heure-room, puis heure-room de
        // capture cible.
        let acousticRoom = clock.roomTime(fromHostTime: outHostTime) + deviceLatencyNanos
        let targetCapture = acousticRoom - playoutDelayNanos - userDelayNanos
        // Index (fractionnaire) correspondant à targetCapture.
        let target = Double(w) - Double(wRoom - targetCapture) * srcRate / 1e9

        if !readInit || abs(target - readPos) > Double(capacity / 4) {
            readPos = target
            readInit = true
        }
        let error = target - readPos
        let correction = max(-maxRate, min(maxRate, error * kP))
        let advance = (srcRate / outRate) * (1.0 + correction)

        let lowFloor = Double(w) - Double(capacity - 2)
        var pos = readPos
        for f in 0..<frames {
            let i0 = Int(pos.rounded(.down))
            var l: Float = 0, r: Float = 0
            if Double(i0 + 1) < Double(w) && Double(i0) >= lowFloor {
                let frac = Float(pos - Double(i0))
                let a = (i0 & mask) * 2
                let b = ((i0 + 1) & mask) * 2
                l = ring[a] * (1 - frac) + ring[b] * frac
                r = ring[a + 1] * (1 - frac) + ring[b + 1] * frac
            } else {
                underruns.add(1)
            }
            l *= gain; r *= gain
            let base = f * outChannels
            for c in 0..<outChannels {
                out[base + c] = (c & 1) == 0 ? l : r
            }
            pos += advance
        }
        readPos = pos
    }

    func reset() {
        writeIndex.store(0); nextWriteRoomTime.store(0)
        underruns.store(0); hasData.store(false)
        readInit = false; readPos = 0
        prodInit = false; prodWrite = 0; prodRoomTime = 0
    }
}
