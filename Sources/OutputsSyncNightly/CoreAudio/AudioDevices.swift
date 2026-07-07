import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannels: Int
    let transportType: UInt32

    var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
}

enum AudioDevices {

    static func all() -> [AudioDeviceInfo] {
        CA.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
            .compactMap(info(for:))
    }

    static func info(for id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = CA.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = CA.string(id, kAudioObjectPropertyName) ?? uid
        let outCh = CA.totalChannels(id, scope: kAudioObjectPropertyScopeOutput)
        let transport = CA.value(id, kAudioDevicePropertyTransportType, default: UInt32(0))
        return AudioDeviceInfo(id: id, uid: uid, name: name,
                               outputChannels: outCh, transportType: transport)
    }

    /// Sorties physiques sélectionnables : on exclut les agrégats (dont notre
    /// moteur) et notre ancien driver virtuel s'il est encore installé.
    static func selectableOutputs() -> [AudioDeviceInfo] {
        all().filter { dev in
            dev.outputChannels > 0
            && !dev.isAggregate
            && !dev.name.localizedCaseInsensitiveContains("OutputsSync")
        }
    }

    static func device(uid: String) -> AudioDeviceInfo? {
        all().first { $0.uid == uid }
    }

    /// Périphérique de sortie par défaut du système.
    static func defaultOutput() -> AudioDeviceInfo? {
        let id = CA.value(AudioObjectID(kAudioObjectSystemObject),
                          kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
        return id != 0 ? info(for: id) : nil
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double {
        CA.value(id, kAudioDevicePropertyNominalSampleRate, default: 48_000.0)
    }

    /// Volume de sortie (0…1) : élément maître, sinon 1ᵉʳ canal. nil si absent.
    static func outputVolume(_ id: AudioObjectID) -> Float32? {
        for elem in [kAudioObjectPropertyElementMain, 1] {
            var addr = CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, elem)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(id, &addr),
               AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr {
                return v
            }
        }
        return nil
    }

    /// Force le volume matériel d'une sortie (tous les éléments réglables), pour
    /// éviter la double atténuation quand l'app redistribue (le loudness est
    /// alors piloté par le driver/F11-F12 + les curseurs de l'app).
    static func setOutputVolume(_ id: AudioObjectID, _ value: Float32) {
        for elem in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, elem)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(id, &addr),
                  AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { continue }
            var v = value
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    /// Latence de présentation rapportée par CoreAudio, en frames :
    /// latence du périphérique + safety offset + latence du flux de sortie.
    /// Sert à l'alignement automatique (sans micro).
    static func outputLatencyFrames(_ id: AudioObjectID) -> Int {
        let device = CA.value(id, kAudioDevicePropertyLatency,
                              kAudioObjectPropertyScopeOutput, default: UInt32(0))
        let safety = CA.value(id, kAudioDevicePropertySafetyOffset,
                              kAudioObjectPropertyScopeOutput, default: UInt32(0))
        var stream: UInt32 = 0
        if let s = CA.objectIDs(id, kAudioDevicePropertyStreams,
                                kAudioObjectPropertyScopeOutput).first {
            stream = CA.value(s, kAudioStreamPropertyLatency, default: UInt32(0))
        }
        return Int(device) + Int(safety) + Int(stream)
    }

    static func outputLatencyMs(_ id: AudioObjectID) -> Double {
        let sr = nominalSampleRate(id)
        guard sr > 0 else { return 0 }
        return Double(outputLatencyFrames(id)) / sr * 1000.0
    }
}

