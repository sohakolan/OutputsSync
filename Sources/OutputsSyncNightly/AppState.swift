import Combine
import CoreAudio
import Foundation

@MainActor
final class AppState: ObservableObject {

    @Published var outputs: [AudioDeviceInfo] = []
    @Published var selectedUIDs: [String] = []           // [0] = horloge maître
    @Published var deviceVolumes: [String: Double] = [:] // 0...1
    @Published var deviceDelaysMs: [String: Double] = [:] // 0...500 ms
    @Published var masterVolume: Double = 1.0            // 0...2
    @Published var isRunning = false
    @Published var statusMessage = ""
    @Published var sourceAvailable = false               // driver OutputsSync présent ?

    private let engine = SyncEngine()

    init() { refreshDevices() }

    /// Le périphérique loopback « OutputsSync Nightly » (source du pont).
    private var sourceDevice: AudioDeviceInfo? {
        AudioDevices.all().first {
            $0.name.localizedCaseInsensitiveContains("OutputsSync") && !$0.isAggregate
        }
    }

    func refreshDevices() {
        outputs = AudioDevices.selectableOutputs()
        sourceAvailable = sourceDevice != nil
        let available = Set(outputs.map(\.uid))
        selectedUIDs = selectedUIDs.filter(available.contains)
        for uid in available {
            if deviceVolumes[uid] == nil { deviceVolumes[uid] = 1.0 }
            if deviceDelaysMs[uid] == nil { deviceDelaysMs[uid] = 0.0 }
        }
        if !sourceAvailable {
            statusMessage = "Driver « OutputsSync Nightly » absent. Installe-le (make install-driver)."
        }
    }

    func toggle(_ uid: String) {
        if let idx = selectedUIDs.firstIndex(of: uid) {
            selectedUIDs.remove(at: idx)
        } else {
            selectedUIDs.append(uid)
        }
        if isRunning { restart() }
    }

    /// Désigne une sortie comme horloge maître de l'agrégat (la place en tête).
    func setClock(_ uid: String) {
        guard let idx = selectedUIDs.firstIndex(of: uid), idx != 0 else { return }
        selectedUIDs.remove(at: idx)
        selectedUIDs.insert(uid, at: 0)
        if isRunning { restart() }
    }

    func setMasterVolume(_ v: Double) {
        masterVolume = v
        engine.setMasterVolume(Float(v))
    }

    func setDeviceVolume(_ uid: String, _ v: Double) {
        deviceVolumes[uid] = v
        if let index = selectedUIDs.firstIndex(of: uid) {
            engine.setDeviceVolume(index, Float(v))
        }
    }

    func setDeviceDelay(_ uid: String, _ ms: Double) {
        deviceDelaysMs[uid] = ms
        if let index = selectedUIDs.firstIndex(of: uid) {
            engine.setDeviceDelayMs(index, Float(ms))
        }
    }

    /// Aligne automatiquement les délais des sorties sélectionnées à partir de
    /// la latence rapportée par CoreAudio : la sortie la plus lente reste à 0,
    /// les plus rapides sont retardées pour la rattraper. Sans micro.
    /// `rescan` : re-scanne le matériel avant (utile après un rebranchement).
    func autoAlign(rescan: Bool) {
        if rescan { refreshDevices() }
        guard !selectedUIDs.isEmpty else {
            statusMessage = "Sélectionne au moins une sortie avant d'aligner."
            return
        }

        var latency: [String: Double] = [:]
        for uid in selectedUIDs {
            if let dev = outputs.first(where: { $0.uid == uid }) {
                latency[uid] = AudioDevices.outputLatencyMs(dev.id)
            }
        }
        let slowest = latency.values.max() ?? 0

        for uid in selectedUIDs {
            let delay = (slowest - (latency[uid] ?? 0)).rounded()
            let clamped = max(0, min(500, delay))
            deviceDelaysMs[uid] = clamped
            if let index = selectedUIDs.firstIndex(of: uid) {
                engine.setDeviceDelayMs(index, Float(clamped))
            }
        }

        let summary = selectedUIDs.compactMap { uid -> String? in
            guard let dev = outputs.first(where: { $0.uid == uid }) else { return nil }
            return "\(dev.name) +\(Int(deviceDelaysMs[uid] ?? 0)) ms"
        }.joined(separator: " · ")
        statusMessage = (rescan ? "Recalibré" : "Aligné") + " (latence rapportée) — " + summary
    }

    func start() {
        guard let source = sourceDevice else {
            statusMessage = SyncEngineError.sourceMissing.localizedDescription
            return
        }
        let selected = selectedUIDs.compactMap { uid in outputs.first { $0.uid == uid } }
        guard !selected.isEmpty else {
            statusMessage = SyncEngineError.noOutputs.localizedDescription
            return
        }
        do {
            try engine.start(source: source, outputs: selected)
            engine.setMasterVolume(Float(masterVolume))
            for (index, uid) in selectedUIDs.enumerated() {
                engine.setDeviceVolume(index, Float(deviceVolumes[uid] ?? 1.0))
                engine.setDeviceDelayMs(index, Float(deviceDelaysMs[uid] ?? 0.0))
            }
            isRunning = true
            statusMessage = "Actif — règle « OutputsSync Nightly » comme sortie système. F11/F12 contrôlent le volume."
        } catch {
            isRunning = false
            statusMessage = error.localizedDescription
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
        statusMessage = ""
    }

    func toggleRunning() { isRunning ? stop() : start() }

    private func restart() { stop(); start() }
}
