import AudioToolbox
import CoreAudio
import Foundation

enum SyncEngineError: LocalizedError {
    case sourceMissing
    case noOutputs
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "Périphérique « OutputsSync Nightly » introuvable. Installe le driver (make install-driver)."
        case .noOutputs:
            return "Sélectionne au moins une sortie."
        case .aggregateCreationFailed(let s):
            return "Création de l'agrégat impossible (OSStatus \(s))."
        case .ioProcFailed(let s):
            return "Installation du flux impossible (OSStatus \(s))."
        case .startFailed(let s):
            return "Démarrage impossible (OSStatus \(s))."
        }
    }
}

/// Moteur de synchronisation multi-sorties.
///
/// La source est le périphérique loopback **OutputsSync Nightly** : les apps y
/// jouent (tu le règles comme sortie système), le driver reboucle ce mix vers
/// son entrée, et cette entrée devient la source de l'agrégat. L'IOProc répartit
/// l'audio vers chaque sortie choisie avec **volume maître + gain par appareil +
/// délai par appareil**. Le volume système (F11/F12) agit sur le driver.
final class SyncEngine {

    private let aggregateUID = "com.outputssync.nightly.aggregate"

    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var controls: Controls?
    private var savedOutputVolumes: [(AudioObjectID, Float32)] = []
    private(set) var isRunning = false

    func start(source: AudioDeviceInfo, outputs: [AudioDeviceInfo]) throws {
        guard !outputs.isEmpty else { throw SyncEngineError.noOutputs }
        stop()

        // Agrégat = [source (entrée) + sorties]. Horloge maître = 1ʳᵉ sortie ;
        // la source et les autres sorties sont compensées en dérive.
        let masterUID = outputs[0].uid
        var subDevices: [[String: Any]] = [subDeviceDict(uid: source.uid, master: false)]
        subDevices += outputs.enumerated().map { i, d in subDeviceDict(uid: d.uid, master: i == 0) }

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "OutputsSync Nightly Engine",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMasterSubDeviceKey: masterUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]

        var aggID: AudioObjectID = 0
        let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard createStatus == noErr, aggID != 0 else {
            throw SyncEngineError.aggregateCreationFailed(createStatus)
        }
        aggregateID = aggID

        // Met chaque sortie à plein volume matériel (en mémorisant l'ancienne
        // valeur) : le loudness est piloté par le driver (F11/F12) + les curseurs
        // de l'app, sans double atténuation par le volume propre de l'appareil.
        savedOutputVolumes = outputs.compactMap { d in
            AudioDevices.outputVolume(d.id).map { (d.id, $0) }
        }
        for d in outputs { AudioDevices.setOutputVolume(d.id, 1.0) }

        let rate = AudioDevices.nominalSampleRate(source.id)
        setNominalSampleRate(aggID, rate)

        // Buffers de sortie de l'agrégat = [sortie de la source (mutée), sorties…].
        let outputBufferChannels = CA.streamChannelsPerBuffer(aggID, scope: kAudioObjectPropertyScopeOutput)
        let tags = bufferTags(bufferCount: outputBufferChannels.count, deviceCount: outputs.count)

        let ctrl = Controls(deviceCount: outputs.count, bufferCount: outputBufferChannels.count)
        ctrl.sampleRate = rate
        controls = ctrl

        let block = makeIOBlock(controls: ctrl, bufferTags: tags)
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, block)
        guard procStatus == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggregateID = 0
            throw SyncEngineError.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggID, procID)
            AudioHardwareDestroyAggregateDevice(aggID)
            aggregateID = 0
            ioProcID = nil
            throw SyncEngineError.startFailed(startStatus)
        }
        isRunning = true
    }

    func stop() {
        if aggregateID != 0, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        // Restaure le volume matériel d'origine des sorties.
        for (id, v) in savedOutputVolumes { AudioDevices.setOutputVolume(id, v) }
        savedOutputVolumes = []
        aggregateID = 0
        ioProcID = nil
        controls = nil
        isRunning = false
    }

    func setMasterVolume(_ v: Float) { controls?.setMaster(v) }
    func setDeviceVolume(_ index: Int, _ v: Float) { controls?.setGain(index, v) }
    func setDeviceDelayMs(_ index: Int, _ v: Float) { controls?.setDelayMs(index, v) }

    // MARK: construction

    private func subDeviceDict(uid: String, master: Bool) -> [String: Any] {
        [kAudioSubDeviceUIDKey: uid,
         kAudioSubDeviceDriftCompensationKey: master ? 0 : 1]
    }

    /// Agrégat = [source, sorties] : buffer 0 = sortie de la source (mutée),
    /// buffers suivants = les sorties, buffer i -> appareil i-1.
    private func bufferTags(bufferCount: Int, deviceCount: Int) -> [Int] {
        guard bufferCount > 0 else { return [] }
        var tags = [Int](repeating: -1, count: bufferCount)
        for i in 1..<bufferCount {
            let deviceIndex = i - 1
            tags[i] = deviceIndex < deviceCount ? deviceIndex : -1
        }
        return tags
    }

    private func setNominalSampleRate(_ device: AudioObjectID, _ rate: Double) {
        var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    }

    // MARK: IOProc temps-réel

    private func makeIOBlock(controls: Controls, bufferTags: [Int]) -> AudioDeviceIOBlock {
        let mask = controls.mask
        let history = controls.history
        let ramps = controls.ramps

        return { _, inInputData, _, outOutputData, _ in
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)

            // 1) Source = entrée de l'agrégat (le loopback du driver) = 1er buffer.
            let input = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard input.count > 0, let srcRaw = input[0].mData else {
                for buf in output { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
                return
            }
            let srcChannels = max(Int(input[0].mNumberChannels), 1)
            let src = srcRaw.assumingMemoryBound(to: Float.self)
            let frames = Int(input[0].mDataByteSize) / (srcChannels * MemoryLayout<Float>.size)
            controls.writeHistory(src, srcChannels: srcChannels, frames: frames)

            let base = controls.histWrite - frames
            let master = controls.master()

            // 2) Fan-out : gain + délai par appareil.
            for (bufIndex, buf) in output.enumerated() {
                let tag = bufIndex < bufferTags.count ? bufferTags[bufIndex] : -1
                guard let dstRaw = buf.mData else { continue }
                if tag < 0 {
                    memset(dstRaw, 0, Int(buf.mDataByteSize))
                    continue
                }

                let dstChannels = max(Int(buf.mNumberChannels), 1)
                let dst = dstRaw.assumingMemoryBound(to: Float.self)
                let dstFrames = Int(buf.mDataByteSize) / (dstChannels * MemoryLayout<Float>.size)
                let n = min(frames, dstFrames)

                let delay = controls.delayFrames(tag)
                let targetGain = master * controls.gain(tag)
                let last = ramps[bufIndex]
                let step = n > 0 ? (targetGain - last) / Float(n) : 0

                for f in 0..<n {
                    let g = last + step * Float(f)
                    let globalIndex = base + f - delay
                    var l: Float = 0, r: Float = 0
                    if globalIndex >= 0 {
                        let hi = (globalIndex & mask) * 2
                        l = history[hi]; r = history[hi + 1]
                    }
                    for c in 0..<dstChannels {
                        let s = (c & 1) == 0 ? l : r
                        dst[f * dstChannels + c] = min(max(s * g, -1.0), 1.0)
                    }
                }
                if dstFrames > n {
                    let tailStart = n * dstChannels
                    let tailCount = (dstFrames - n) * dstChannels
                    memset(dst + tailStart, 0, tailCount * MemoryLayout<Float>.size)
                }
                ramps[bufIndex] = targetGain
            }
        }
    }
}
