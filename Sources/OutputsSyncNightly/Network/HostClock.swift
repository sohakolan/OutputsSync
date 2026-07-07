import Foundation

/// Conversion entre l'horloge hôte de CoreAudio (`AudioTimeStamp.mHostTime`,
/// unités `mach_absolute_time`) et des nanosecondes. Sert de base de temps
/// locale commune à la capture, à la lecture et à la synchro d'horloge.
enum HostClock {
    private static let timebase: (num: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Convertit un temps hôte (unités mach) en nanosecondes.
    @inline(__always)
    static func nanos(fromHostTime host: UInt64) -> Int64 {
        Int64(host &* timebase.num / timebase.denom)
    }

    /// Convertit des nanosecondes en temps hôte (unités mach).
    @inline(__always)
    static func hostTime(fromNanos nanos: Int64) -> UInt64 {
        UInt64(nanos) &* timebase.denom / timebase.num
    }

    /// Instant courant de l'horloge locale, en nanosecondes.
    @inline(__always)
    static func nowNanos() -> Int64 {
        nanos(fromHostTime: mach_absolute_time())
    }
}
