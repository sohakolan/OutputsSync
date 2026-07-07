import SwiftUI

/// Onglet « Réseau » : créer/rejoindre une room, puis une **liste unifiée de
/// destinations** (mes sorties locales + les Mac de la room). Mon son sort vers
/// tout ce qui est coché — local ET distant — synchronisé par l'horloge commune.
struct RoomView: View {
    @EnvironmentObject var room: RoomManager
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if room.isActive { activeView } else { lobbyView }
            let msg = room.statusMessage.isEmpty ? state.statusMessage : room.statusMessage
            if room.isActive, !msg.isEmpty {
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !room.statusMessage.isEmpty {
                Text(room.statusMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { room.startLobby() }
    }

    // MARK: hors room (lobby)

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
                Text("Rooms détectées").font(.subheadline).bold()
                Spacer()
                Button { room.rescanLobby() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Re-scanner le réseau")
            }
            if room.discoveredRooms.isEmpty {
                Text("Aucune room détectée. Crée-en une ci-dessous, ou attends qu'un Mac en crée une.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(room.discoveredRooms) { roomRow($0) }
            }
        }
    }

    private func roomRow(_ r: DiscoveredRoom) -> some View {
        HStack(spacing: 8) {
            Image(systemName: r.needsPIN ? "lock.fill" : "lock.open")
                .font(.caption).foregroundStyle(r.needsPIN ? Color.secondary : Color.green)
            Text(r.name).font(.callout).lineLimit(1)
            Text("· \(r.peopleCount)").font(.caption2).foregroundStyle(.secondary)
                .help("\(r.peopleCount) Mac dans cette room")
            Spacer()
            Button { room.selectRoomToJoin(r) } label: { Text("Rejoindre").font(.caption2) }
                .buttonStyle(.bordered).controlSize(.small).tint(.purple)
        }
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Créer une room").font(.subheadline).bold()
            field("Room", text: $room.roomName, placeholder: "Salon")
            HStack(spacing: 8) {
                Text("PIN").font(.caption).frame(width: 60, alignment: .leading)
                SecureField("optionnel", text: $room.pin).textFieldStyle(.roundedBorder)
            }
            Button { room.createRoom() } label: {
                Label("Créer", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.purple).disabled(room.roomName.isEmpty)
            Text("Tu deviens l'horloge maître. PIN optionnel : sans PIN, la room est ouverte à tous.")
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

    // MARK: dans la room

    private var activeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            roomHeader
            destinationsSection
            Divider()
            receiveSection
        }
    }

    private var roomHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.purple)
            Text(room.roomName).font(.subheadline).bold()
            if room.isMaster {
                badge("horloge maître", "metronome.fill")
            } else {
                Text(String(format: "±%.1f ms", room.clockOffsetMs))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Décalage estimé avec l'horloge maître")
            }
            Spacer()
            Button { room.leaveRoom() } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.borderless).help("Quitter la room")
        }
    }

    // MARK: destinations (local + Mac)

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mes destinations").font(.subheadline).bold()
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
            Text("Coche des sorties locales et/ou des Mac : ton son sort partout en même temps. Chaque Mac joue sur ses propres sorties.")
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
                if peer.isMaster { badge("maître", "metronome") }
                Spacer()
                Button { room.toggleListen(peer.peerID) } label: {
                    Image(systemName: peer.listening ? "headphones.circle.fill" : "headphones")
                        .foregroundStyle(peer.listening ? Color.purple : .secondary)
                }
                .buttonStyle(.borderless).disabled(!peer.connected)
                .help(peer.listening ? "J'écoute ce Mac" : "Écouter ce Mac")
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

    // MARK: réception

    private var receiveSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "headphones").font(.caption).foregroundStyle(.secondary)
                Text("Écouter sur").font(.caption)
                Picker("", selection: $room.selectedOutputUID) {
                    ForEach(room.outputs) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden()
            }
            Text("Sortie locale où jouer le son des Mac que tu écoutes (bouton casque).")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.purple.opacity(0.18))
            .clipShape(Capsule())
    }
}
