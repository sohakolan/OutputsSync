import Foundation

/// `--latencies` : affiche la latence rapportée de chaque sortie et les délais
/// que « Sync auto » appliquerait pour toutes les aligner. Sur vrai matériel,
/// sans GUI ni audio.
enum LatencyProbe {
    static func run() -> Int32 {
        print("=== OutputsSync Nightly — latences rapportées ===\n")
        let outputs = AudioDevices.selectableOutputs()
        guard !outputs.isEmpty else { print("Aucune sortie."); return 1 }

        var latency: [String: Double] = [:]
        for d in outputs {
            let frames = AudioDevices.outputLatencyFrames(d.id)
            let ms = AudioDevices.outputLatencyMs(d.id)
            latency[d.uid] = ms
            print(String(format: "  %-26@  %5d frames  %6.1f ms",
                         d.name as NSString, frames, ms))
        }

        let slowest = latency.values.max() ?? 0
        print(String(format: "\nLe plus lent : %.1f ms → délais « Sync auto » :", slowest))
        for d in outputs {
            let delay = max(0, min(500, (slowest - (latency[d.uid] ?? 0)).rounded()))
            print(String(format: "  %-26@  +%3d ms", d.name as NSString, Int(delay)))
        }
        print("\n✅ Alignement calculé (aligne toutes les sorties sur la plus lente).")
        return 0
    }
}
