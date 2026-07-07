import SwiftUI

/// Onglet « Réseau ». Modèle **source → enceintes** : celui qui crée le salon est
/// la **source** (c'est lui qui met le son) ; il choisit quelles enceintes — ses
/// sorties locales et les Mac du salon — jouent son son, synchronisées par
/// l'horloge commune. Les invités sont de simples **enceintes** : ils écoutent la
/// source sur la sortie locale de leur choix.
struct RoomView: View {
    @EnvironmentObject var room: RoomManager
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if room.isActive {
                if room.isMaster { hostView } else { guestView }
            } else {
                lobbyView
            }
            statusLine
        }
        .onAppear { room.startLobby() }
    }

    private var statusLine: some View {
        // La source (hôte) voit aussi les messages du moteur local (sorties, sync
        // auto) ; l'enceinte (invité) non — elle n'a pas de fan-out local.
        let fallback = (room.isActive && room.isMaster) ? state.statusMessage : ""
        let msg = room.statusMessage.isEmpty ? fallback : room.statusMessage
        return Group {
            if !msg.isEmpty {
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: hors salon (lobby)

    private var lobbyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Ton nom", text: $room.myName, placeholder: "Mon Mac")
            if let target = room.joinTarget {
                joinPrompt(target)
            } else {
                detectedRoomsSection
                Divider()
                createSection
            }
        }
    }

    private var detectedRoomsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Salons détectés").font(.subheadline).bold()
                Spacer()
                Button { room.rescanLobby() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Re-scanner le réseau")
            }
            if room.discoveredRooms.isEmpty {
                Text("Aucun salon détecté. Crée-en un ci-dessous, ou attends qu'un Mac en crée un.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(room.discoveredRooms) { roomRow($0) }
                Text("Rejoindre un salon = devenir une **enceinte** : tu écoutes la source sur ta sortie locale.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func roomRow(_ r: DiscoveredRoom) -> some View {
        HStack(spacing: 8) {
            Image(systemName: r.needsPIN ? "lock.fill" : "lock.open")
                .font(.caption).foregroundStyle(r.needsPIN ? Color.secondary : Color.green)
            Text(r.name).font(.callout).lineLimit(1)
            Text("· \(r.peopleCount)").font(.caption2).foregroundStyle(.secondary)
                .help("\(r.peopleCount) Mac dans ce salon")
            Spacer()
            Button { room.selectRoomToJoin(r) } label: { Text("Rejoindre").font(.caption2) }
                .buttonStyle(.bordered).controlSize(.small).tint(.purple)
        }
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Créer un salon").font(.subheadline).bold()
            field("Salon", text: $room.roomName, placeholder: "Salon")
            HStack(spacing: 8) {
                Text("PIN").font(.caption).frame(width: 60, alignment: .leading)
                SecureField("optionnel", text: $room.pin).textFieldStyle(.roundedBorder)
            }
            Button { room.createRoom() } label: {
                Label("Créer le salon", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.purple).disabled(room.roomName.isEmpty)
            Text("**Tu deviens la source** : ton son est envoyé aux enceintes cochées, synchronisées. PIN optionnel : sans PIN, le salon est ouvert à tous.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func joinPrompt(_ target: DiscoveredRoom) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rejoindre « \(target.name) »").font(.subheadline).bold()
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                SecureField("code PIN", text: $room.pin).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button { room.confirmJoin() } label: {
                    Label("Rejoindre", systemImage: "arrow.right.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.purple).disabled(room.pin.isEmpty)
                Button { room.cancelJoin() } label: { Text("Annuler") }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: source (créateur du salon)

    private var hostView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(role: "Tu es la source", roleIcon: "dot.radiowaves.up.forward", showOffset: false)
            if !state.sourceAvailable {
                Label("Émettre requiert le driver « OutputsSync » comme sortie système.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            destinationsSection
            syncBar
        }
    }

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Enceintes du salon").font(.subheadline).bold()
                Spacer()
                Button { state.refreshDevices(); room.refreshOutputs() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless).help("Rafraîchir")
            }
            ForEach(state.outputs) { localRow($0) }
            ForEach(room.peers) { peerRow($0) }
            if state.outputs.isEmpty && room.peers.isEmpty {
                Text("Aucune sortie locale ni Mac dans « \(room.roomName) »…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Coche des sorties locales et/ou des Mac : ton son sort partout en même temps, synchronisé. Chaque Mac joue sur sa propre sortie.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func localRow(_ device: AudioDeviceInfo) -> some View {
        let selected = state.selectedUIDs.contains(device.uid)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                checkbox(selected) { state.toggleLocalLive(device.uid) }
                Image(systemName: "hifispeaker").font(.caption).foregroundStyle(.secondary)
                Text(device.name).font(.callout).lineLimit(1)
                Spacer()
                Text("local").font(.caption2).foregroundStyle(.tertiary)
            }
            if selected {
                slider("dial.low", value: Binding(
                    get: { state.deviceVolumes[device.uid] ?? 1.0 },
                    set: { state.setDeviceVolume(device.uid, $0) }), range: 0...1,
                    trailing: "\(Int((state.deviceVolumes[device.uid] ?? 1.0) * 100)) %")
                slider("clock", value: Binding(
                    get: { state.deviceDelaysMs[device.uid] ?? 0 },
                    set: { state.setDeviceDelay(device.uid, $0) }), range: 0...500,
                    trailing: "\(Int(state.deviceDelaysMs[device.uid] ?? 0)) ms")
            }
        }
    }

    private func peerRow(_ peer: PeerRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                checkbox(peer.sendingToThem) { room.setEmitToPeer(peer.peerID, !peer.sendingToThem) }
                    .disabled(!peer.connected)
                Image(systemName: "laptopcomputer").font(.caption)
                    .foregroundStyle(peer.connected ? .secondary : Color.secondary.opacity(0.4))
                Text(peer.name).font(.callout).lineLimit(1)
                Spacer()
                Text(peer.connected ? "Mac" : "hors ligne")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if peer.sendingToThem {
                slider("dial.low", value: Binding(
                    get: { peer.destVolume }, set: { room.setDestVolume(peer.peerID, $0) }),
                    range: 0...1.5, trailing: "\(Int(peer.destVolume * 100)) %")
                slider("clock", value: Binding(
                    get: { peer.destDelay }, set: { room.setDestDelay(peer.peerID, $0) }),
                    range: 0...200, trailing: "\(Int(peer.destDelay)) ms")
            }
        }
    }

    // MARK: enceinte (invité du salon)

    private var guestView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(role: "Tu es une enceinte", roleIcon: "hifispeaker.fill", showOffset: true)
            listenSection
            syncBar
        }
    }

    private var listenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if room.hasActiveAudio {
                Label("Tu écoutes la source de « \(room.roomName) »", systemImage: "waveform")
                    .font(.callout).foregroundStyle(.purple)
            } else {
                Label("En attente que la source t'ajoute au salon…", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "headphones").font(.caption).foregroundStyle(.secondary)
                Text("Sortie").font(.caption)
                Picker("", selection: Binding(
                    get: { room.selectedOutputUID },
                    set: { room.setListenOutput($0) })) {
                    ForEach(room.outputs) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden()
            }
            Text("La source (le créateur du salon) met le son. Choisis la sortie locale où le jouer. Écouter ne demande **pas** le driver.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: en-tête + sync communs

    private func header(role: String, roleIcon: String, showOffset: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 0) {
                Text(room.roomName).font(.subheadline).bold().lineLimit(1)
                Label(role, systemImage: roleIcon).font(.caption2).foregroundStyle(.purple)
            }
            Spacer()
            if showOffset {
                Text(String(format: "±%.1f ms", room.clockOffsetMs))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Décalage estimé avec l'horloge de la source")
            }
            Button { room.leaveRoom() } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.borderless).help("Quitter le salon")
        }
    }

    private var syncBar: some View {
        Button { room.resync() } label: {
            Label("Resynchroniser", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).tint(.purple).controlSize(.small)
        .disabled(!room.hasActiveAudio)
        .help("Re-aligne toutes les enceintes du salon sur l'horloge commune")
    }

    // MARK: composants

    private func checkbox(_ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .foregroundStyle(on ? Color.purple : .secondary)
        }
        .buttonStyle(.borderless)
    }

    private func slider(_ icon: String, value: Binding<Double>, range: ClosedRange<Double>,
                        trailing: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Slider(value: value, in: range)
            Text(trailing).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.leading, 24)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 60, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}
