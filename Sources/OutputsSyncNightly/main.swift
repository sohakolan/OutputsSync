import AppKit

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}
if CommandLine.arguments.contains("--latencies") {
    exit(LatencyProbe.run())
}
if CommandLine.arguments.contains("--nettest") {
    exit(NetTest.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
