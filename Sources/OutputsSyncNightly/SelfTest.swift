import Foundation

/// Auto-test headless (`--selftest`) : valide la ligne à retard et la
/// conversion ms→frames, sans audio ni GUI. Chaque frame source porte la
/// valeur de son index global, ce qui permet de vérifier qu'une lecture avec
/// délai `d` renvoie bien le frame écrit `d` échantillons plus tôt.
enum SelfTest {
    static func run() -> Int32 {
        print("=== OutputsSync Nightly — self-test ===\n")
        var failures = 0

        func check(_ cond: Bool, _ label: String) {
            print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
            if !cond { failures += 1 }
        }

        let ctrl = Controls(deviceCount: 2, bufferCount: 3)
        ctrl.sampleRate = 48_000

        // 1) Conversion ms -> frames.
        ctrl.setDelayMs(0, 10)   // 10 ms @ 48 kHz = 480 frames
        ctrl.setDelayMs(1, 0)
        check(ctrl.delayFrames(0) == 480, "10 ms -> 480 frames")
        check(ctrl.delayFrames(1) == 0, "0 ms -> 0 frames")

        // 2) Alimente l'historique : valeur du frame = index global.
        let block = 512
        var g = 0
        var srcbuf = [Float](repeating: 0, count: block * 2)
        for _ in 0..<10 {
            for f in 0..<block {
                srcbuf[f * 2] = Float(g + f)
                srcbuf[f * 2 + 1] = Float(g + f)
            }
            srcbuf.withUnsafeBufferPointer {
                ctrl.writeHistory($0.baseAddress!, srcChannels: 2, frames: block)
            }
            g += block
        }
        check(ctrl.histWrite == 10 * block, "histWrite = \(10 * block)")

        // 3) Lecture retardée : reproduit exactement le calcul de l'IOProc.
        let base = ctrl.histWrite - block   // 1er frame du dernier bloc
        var alignmentOK = true
        for d in [0, 100, 480] {
            for f in [0, 1, 255, 511] {
                let gi = base + f - d
                guard gi >= 0 else { continue }
                let hi = (gi & ctrl.mask) * 2
                if ctrl.history[hi] != Float(gi) { alignmentOK = false }
            }
        }
        check(alignmentOK, "lecture retardée alignée pour d = 0/100/480")

        // 4) Deux appareils, délais différents -> décalage exact entre eux.
        // Appareil 0 retardé de 480, appareil 1 de 0 : à la même position de
        // lecture, l'appareil 0 doit renvoyer une valeur inférieure de 480.
        let f = 300
        let v0 = ctrl.history[((base + f - 480) & ctrl.mask) * 2]
        let v1 = ctrl.history[((base + f - 0) & ctrl.mask) * 2]
        check(v1 - v0 == 480, "décalage inter-appareils = 480 frames (10 ms)")

        // 5) Gains par défaut et écriture.
        check(ctrl.master() == 1.0 && ctrl.gain(0) == 1.0, "gains par défaut = 1.0")
        ctrl.setMaster(0.5); ctrl.setGain(1, 0.25)
        check(ctrl.master() == 0.5 && ctrl.gain(1) == 0.25, "écriture des gains")

        print(failures == 0 ? "\n✅ self-test OK" : "\n❌ \(failures) échec(s)")
        return failures == 0 ? 0 : 1
    }
}
