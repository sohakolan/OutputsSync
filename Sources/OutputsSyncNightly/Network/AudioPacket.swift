import Foundation

/// Paquet audio réseau : entête binaire (little-endian) + payload PCM Float32
/// entrelacé. Encodé côté émetteur (thread réseau), décodé côté récepteur
/// (queue réseau) — jamais dans le thread audio temps-réel.
///
/// ```
/// off  taille  champ
/// 0    4       magic "OSS1"
/// 4    1       flags (bit0 : 0=PCM float32, 1=Opus)
/// 5    1       channels
/// 6    2       réservé
/// 8    4       sampleRate
/// 12   4       seq
/// 16   8       captureRoomTimeNanos (heure-room de la 1ʳᵉ frame)
/// 24   4       frameCount
/// 28   …       payload = frameCount × channels × Float32
/// ```
enum AudioPacket {
    static let magic: UInt32 = 0x4F535331 // "OSS1"
    static let headerSize = 28
    static let flagPCM: UInt8 = 0

    struct Parsed {
        let seq: UInt32
        let sampleRate: UInt32
        let channels: Int
        let captureRoomTimeNanos: Int64
        let frameCount: Int
        /// Copie des échantillons entrelacés (frameCount × channels).
        let samples: [Float]
    }

    /// Sérialise `frameCount × channels` échantillons entrelacés.
    static func encode(
        seq: UInt32,
        sampleRate: UInt32,
        channels: Int,
        captureRoomTimeNanos: Int64,
        samples: UnsafePointer<Float>,
        frameCount: Int
    ) -> Data {
        let count = frameCount * channels
        var data = Data(capacity: headerSize + count * MemoryLayout<Float>.size)
        appendLE(&data, magic)
        data.append(flagPCM)
        data.append(UInt8(channels))
        appendLE(&data, UInt16(0))
        appendLE(&data, sampleRate)
        appendLE(&data, seq)
        appendLE(&data, captureRoomTimeNanos)
        appendLE(&data, UInt32(frameCount))
        samples.withMemoryRebound(to: UInt8.self, capacity: count * 4) { raw in
            data.append(raw, count: count * 4)
        }
        return data
    }

    static func parse(_ data: Data) -> Parsed? {
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Parsed? in
            let base = raw.baseAddress!
            guard base.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == magic else { return nil }
            let channels = Int(base.loadUnaligned(fromByteOffset: 5, as: UInt8.self))
            let sampleRate = base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let seq = base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            let captureTime = base.loadUnaligned(fromByteOffset: 16, as: Int64.self)
            let frameCount = Int(base.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
            guard channels > 0 else { return nil }
            let sampleCount = frameCount * channels
            let need = headerSize + sampleCount * MemoryLayout<Float>.size
            guard data.count >= need, sampleCount >= 0 else { return nil }
            var samples = [Float](repeating: 0, count: sampleCount)
            samples.withUnsafeMutableBytes { dst in
                _ = memcpy(dst.baseAddress!, base + headerSize, sampleCount * MemoryLayout<Float>.size)
            }
            return Parsed(seq: seq, sampleRate: sampleRate, channels: channels,
                          captureRoomTimeNanos: captureTime, frameCount: frameCount, samples: samples)
        }
    }

    // MARK: little-endian append

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
