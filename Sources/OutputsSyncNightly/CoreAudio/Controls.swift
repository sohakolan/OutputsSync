import Foundation

/// État partagé entre le thread UI (écriture) et le thread audio temps-réel
/// (lecture). Volumes et délais sont de simples Float/… : sur arm64 une
/// écriture 32 bits alignée est atomique, ce qui suffit ici (aucun verrou dans
/// le chemin temps-réel).
///
/// Contient aussi l'historique source (ligne à retard) et les rampes de gain,
/// qui ne sont touchés QUE par le thread audio.
final class Controls: @unchecked Sendable {
    let deviceCount: Int
    let bufferCount: Int

    // Écrit par l'UI, lu par l'audio.
    private let gains: UnsafeMutablePointer<Float>   // [0]=maître, [1...]=par appareil
    private let delaysMs: UnsafeMutablePointer<Float> // par appareil

    // Domaine audio uniquement.
    let ramps: UnsafeMutablePointer<Float>            // par buffer de sortie
    let history: UnsafeMutablePointer<Float>          // stéréo entrelacé
    let capacity: Int                                 // en frames (puissance de 2)
    let mask: Int
    var histWrite: Int = 0
    var sampleRate: Double = 48_000

    init(deviceCount: Int, bufferCount: Int, capacityFrames: Int = 131_072) {
        self.deviceCount = deviceCount
        self.bufferCount = bufferCount
        self.capacity = capacityFrames
        self.mask = capacityFrames - 1

        gains = .allocate(capacity: 1 + deviceCount)
        delaysMs = .allocate(capacity: max(deviceCount, 1))
        ramps = .allocate(capacity: max(bufferCount, 1))
        history = .allocate(capacity: capacityFrames * 2)

        gains[0] = 1.0
        for i in 0..<deviceCount { gains[1 + i] = 1.0 }
        for i in 0..<max(deviceCount, 1) { delaysMs[i] = 0.0 }
        for i in 0..<max(bufferCount, 1) { ramps[i] = 0.0 }
        history.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit {
        gains.deallocate()
        delaysMs.deallocate()
        ramps.deallocate()
        history.deallocate()
    }

    // MARK: écrit par l'UI
    func setMaster(_ v: Float) { gains[0] = v }
    func setGain(_ index: Int, _ v: Float) {
        guard index >= 0, index < deviceCount else { return }
        gains[1 + index] = v
    }
    func setDelayMs(_ index: Int, _ v: Float) {
        guard index >= 0, index < deviceCount else { return }
        delaysMs[index] = max(0, v)
    }

    // MARK: lu par l'audio
    @inline(__always) func master() -> Float { gains[0] }
    @inline(__always) func gain(_ index: Int) -> Float { gains[1 + index] }
    @inline(__always) func delayFrames(_ index: Int) -> Int {
        Int(delaysMs[index] * Float(sampleRate) / 1000.0)
    }

    /// Écrit `n` frames source (entrelacé, `srcChannels`) dans l'historique.
    @inline(__always)
    func writeHistory(_ src: UnsafePointer<Float>, srcChannels: Int, frames n: Int) {
        let c1 = srcChannels > 1 ? 1 : 0
        for f in 0..<n {
            let dst = ((histWrite + f) & mask) * 2
            history[dst] = src[f * srcChannels]
            history[dst + 1] = src[f * srcChannels + c1]
        }
        histWrite += n
    }
}
