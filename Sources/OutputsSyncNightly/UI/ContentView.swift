import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sourceSection
            masterSection
            Divider()
            outputsSection

            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(state.isRunning ? .purple : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("OutputsSync").font(.headline)
                Text("Nightly").font(.caption2).foregroundStyle(.purple)
            }
            Spacer()
            Circle()
                .fill(state.isRunning ? Color.purple : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
        }
    }

    private var sourceSection: some View {
        Group {
            if state.sourceAvailable {
                Label("Règle « OutputsSync Nightly » comme sortie système",
                      systemImage: "arrow.down.forward.and.arrow.up.backward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Driver « OutputsSync Nightly » absent — installe-le (make install-driver)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var masterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Volume maître").font(.subheadline).bold()
                Spacer()
                Text("\(Int(state.masterVolume * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(state.masterVolume > 1.0 ? .orange : .secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { state.masterVolume },
                    set: { state.setMasterVolume($0) }), in: 0...2)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
        }
    }

    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sorties & délais").font(.subheadline).bold()
                Spacer()
                Button { state.refreshDevices() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rafraîchir")
            }
            if state.outputs.isEmpty {
                Text("Aucune sortie détectée.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(state.outputs) { device in outputRow(device) }
            }

            HStack(spacing: 8) {
                Button { state.autoAlign(rescan: false) } label: {
                    Label("Sync auto", systemImage: "wand.and.rays")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .help("Aligne les sorties depuis la latence rapportée par CoreAudio")

                Button { state.autoAlign(rescan: true) } label: {
                    Label("Recalibrer", systemImage: "gauge.with.needle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Re-scanne le matériel puis réaligne (après un rebranchement)")
            }
            .controlSize(.small)
            .disabled(state.selectedUIDs.isEmpty)

            Text("Auto = latence rapportée (top pour HDMI/AirPods ; base ajustable pour du Bluetooth générique). Sinon, délai manuel sur l'appareil le plus RAPIDE.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func outputRow(_ device: AudioDeviceInfo) -> some View {
        let selected = state.selectedUIDs.contains(device.uid)
        let isClock = state.selectedUIDs.first == device.uid
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { state.toggle(device.uid) } label: {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? Color.purple : .secondary)
                }
                .buttonStyle(.borderless)
                Text(device.name).font(.callout).lineLimit(1)
                Spacer()
                if selected {
                    if isClock {
                        Label("horloge", systemImage: "metronome.fill")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.purple.opacity(0.18))
                            .clipShape(Capsule())
                            .help("Horloge maître de la synchronisation")
                    } else {
                        Button { state.setClock(device.uid) } label: {
                            Image(systemName: "metronome")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Définir comme horloge maître")
                    }
                }
            }

            if selected {
                // Volume
                HStack(spacing: 8) {
                    Image(systemName: "dial.low").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { state.deviceVolumes[device.uid] ?? 1.0 },
                        set: { state.setDeviceVolume(device.uid, $0) }), in: 0...1)
                    Text("\(Int((state.deviceVolumes[device.uid] ?? 1.0) * 100)) %")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.leading, 24)
                // Délai
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { state.deviceDelaysMs[device.uid] ?? 0.0 },
                        set: { state.setDeviceDelay(device.uid, $0) }), in: 0...500)
                    Text("\(Int(state.deviceDelaysMs[device.uid] ?? 0.0)) ms")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                .padding(.leading, 24)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { state.toggleRunning() } label: {
                Label(state.isRunning ? "Arrêter" : "Activer",
                      systemImage: state.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(state.selectedUIDs.isEmpty || !state.sourceAvailable)

            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help("Quitter")
        }
    }
}
