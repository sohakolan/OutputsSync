import Combine
import CoreAudio
import Foundation
import Network

/// Un peer de la room tel qu'affiché dans l'UI.
struct PeerRow: Identifiable {
    let peerID: String
    var name: String
    var isMaster: Bool
    var connected: Bool      // lien de contrôle authentifié
    var listening: Bool      // je reçois son son (bouton « écouter »)
    var sendingToThem: Bool  // il reçoit mon son (coché comme destination)
    var destVolume: Double = 1.0 // volume de MON son chez lui
    var destDelay: Double = 0    // délai de MON son chez lui (ms)
    var id: String { peerID }
}

/// Une room détectée sur le LAN (regroupement des peers par nom de room).
struct DiscoveredRoom: Identifiable, Equatable {
    let name: String
    let peopleCount: Int
    let needsPIN: Bool
    var id: String { name }
}

/// Orchestration du mode réseau : découverte, contrôle (PIN), horloge commune,
/// émission (capture loopback → UDP) et réception (UDP → sortie). Tout l'état
/// publié pour l'UI est confiné au `MainActor` ; les callbacks réseau y sautent.
@MainActor
final class RoomManager: ObservableObject {

    @Published var myName: String = Host.current().localizedName ?? "Mon Mac"
    @Published var roomName: String = "Salon"
    @Published var pin: String = ""

    @Published var isActive = false
    @Published var isMaster = false
    @Published var broadcasting = false
    @Published var peers: [PeerRow] = []
    @Published var discoveredRooms: [DiscoveredRoom] = [] // lobby : rooms détectées
    @Published var joinTarget: DiscoveredRoom?            // room sélectionnée en attente de PIN
    @Published var statusMessage = ""
    @Published var clockOffsetMs: Double = 0
    @Published var clockRttMs: Double = 0

    @Published var outputs: [AudioDeviceInfo] = []
    @Published var selectedOutputUID: String = ""

    let myPeerID = UUID().uuidString

    // Composants réseau/audio.
    private let clock = RoomClock()
    private let controlServer = ControlServer()
    private var discovery: RoomDiscovery?
    private var clockServer: ClockSyncServer?
    private var clockClient: ClockSyncClient?
    private var source: NetworkSource?
    private var mixers: [String: OutputMixer] = [:]   // UID device → mixeur de sortie
    private var streams: [String: NetworkStream] = [:] // peerID → flux reçu

    // Liens de contrôle.
    private var links: [String: ControlLink] = [:]      // peerID → lien authentifié
    private var pendingInbound: [ObjectIdentifier: ControlLink] = [:]
    private var pendingOutbound: Set<String> = []

    private var controlPort: UInt16 = 0
    private var clockPort: UInt16 = 0
    private var masterPeerID: String?
    private var masterClockPort: UInt16 = 0
    private var clockClientStarted = false

    init() { refreshOutputs() }

    func refreshOutputs() {
        outputs = AudioDevices.selectableOutputs()
        if selectedOutputUID.isEmpty || !outputs.contains(where: { $0.uid == selectedOutputUID }) {
            selectedOutputUID = AudioDevices.defaultOutput()?.uid ?? outputs.first?.uid ?? ""
        }
    }

    private var loopbackDevice: AudioDeviceInfo? {
        AudioDevices.all().first {
            $0.name.localizedCaseInsensitiveContains("OutputsSync") && !$0.isAggregate
        }
    }

    // MARK: cycle de vie de la room

    func createRoom() { activate(asMaster: true) }
    func joinRoom() { activate(asMaster: false) }

    private func activate(asMaster: Bool) {
        guard !isActive else { return }
        guard !roomName.isEmpty else { statusMessage = "Nomme la room."; return }
        isMaster = asMaster
        joinTarget = nil
        refreshOutputs()
        startLobby() // découverte des peers (déjà lancée depuis le lobby en général)

        // Serveur de contrôle (chaque peer écoute, maillage complet).
        controlServer.onReady = { [weak self] port in self?.onMain { $0.controlReady(port) } }
        controlServer.onAccept = { [weak self] link in self?.onMain { $0.acceptInbound(link) } }
        controlServer.start()

        // Maître : héberge l'horloge (offset 0). Joiner : la synchronise plus tard.
        if asMaster {
            clock.setOffset(0)
            let cs = ClockSyncServer()
            cs.onReady = { [weak self] port in self?.onMain { $0.clockServerReady(port) } }
            cs.start()
            clockServer = cs
        }

        source = NetworkSource(clock: clock)
        isActive = true
        statusMessage = asMaster ? "Room « \(roomName) » créée. En attente de peers…"
                                 : "Recherche de la room « \(roomName) »…"
    }

    private func controlReady(_ port: UInt16) {
        controlPort = port
        advertiseIfReady()
    }

    private func clockServerReady(_ port: UInt16) {
        clockPort = port
        advertiseIfReady()
    }

    private func advertiseIfReady() {
        // Le maître attend aussi son port horloge ; le joiner non.
        guard controlPort != 0, isActive else { return }
        if isMaster && clockPort == 0 { return }
        controlServer.advertise(name: myName, txt: [
            "room": roomName,
            "peer": myPeerID,
            "name": myName,
            "master": isMaster ? "1" : "0",
            "pin": pin.isEmpty ? "0" : "1",
            "clk": String(clockPort),
        ])
    }

    /// Découverte du lobby : browse **toutes** les rooms du LAN. Idempotent,
    /// reste actif même hors room pour tenir la liste à jour.
    func startLobby() {
        guard discovery == nil else { return }
        let d = RoomDiscovery(myPeerID: myPeerID, room: nil)
        d.onPeersChanged = { [weak self] peers in self?.onMain { $0.handleAllPeers(peers) } }
        d.start()
        discovery = d
    }

    /// Relance un scan frais du lobby.
    func rescanLobby() {
        discovery?.stop(); discovery = nil
        if !isActive { discoveredRooms = [] }
        startLobby()
    }

    func leaveRoom() {
        for link in links.values { link.send(ControlMessage(type: .bye)); link.cancel() }
        links.removeAll()
        pendingInbound.removeAll()
        pendingOutbound.removeAll()
        streams.values.forEach { $0.stop() }
        streams.removeAll()
        mixers.values.forEach { $0.stop() }
        mixers.removeAll()
        source?.teardown(); source = nil
        clockClient?.stop(); clockClient = nil
        clockServer?.stop(); clockServer = nil
        controlServer.stop()
        // On garde la découverte du lobby active pour continuer à voir les rooms.
        clock.setOffset(0)
        isActive = false; isMaster = false; broadcasting = false
        peers = []; masterPeerID = nil; clockClientStarted = false
        controlPort = 0; clockPort = 0
        joinTarget = nil
        statusMessage = ""
    }

    // MARK: découverte → connexions (maillage, dédoublonnage par peerID)

    private func handleAllPeers(_ all: [DiscoveredPeer]) {
        // 1) Lobby : regrouper par room pour la liste.
        var groups: [String: [DiscoveredPeer]] = [:]
        for p in all { groups[p.room, default: []].append(p) }
        discoveredRooms = groups.map { name, peers in
            DiscoveredRoom(name: name, peopleCount: peers.count,
                           needsPIN: peers.contains { $0.needsPIN })
        }.sorted { $0.name < $1.name }

        // 2) Dans une room : connexions mesh pour les peers de MA room.
        guard isActive else { return }
        let mine = all.filter { $0.room == roomName }
        for p in mine {
            if p.isMaster { masterPeerID = p.peerID; masterClockPort = p.clockPort }
            if links[p.peerID] != nil || pendingOutbound.contains(p.peerID) { continue }
            // Seul le plus petit peerID initie, pour éviter les liens en double.
            if myPeerID < p.peerID { connectOutbound(to: p) }
        }
        rebuildPeerRows(discovered: mine)
        maybeStartClockClient()
    }

    // MARK: rejoindre depuis la liste

    /// Room choisie dans la liste : rejoint direct si ouverte, sinon demande le PIN.
    func selectRoomToJoin(_ r: DiscoveredRoom) {
        roomName = r.name
        if r.needsPIN {
            joinTarget = r
        } else {
            pin = ""
            joinRoom()
        }
    }

    func confirmJoin() {
        guard let t = joinTarget else { return }
        roomName = t.name
        joinTarget = nil
        joinRoom()
    }

    func cancelJoin() { joinTarget = nil }

    private func connectOutbound(to peer: DiscoveredPeer) {
        pendingOutbound.insert(peer.peerID)
        let link = ControlLink(endpoint: peer.endpoint, queue: controlServer.sharedQueue)
        let pid = peer.peerID
        link.onReady = { [weak self] in
            self?.onMain { s in
                link.send(ControlMessage(
                    type: .hello, pin: s.pin, name: s.myName, peerID: s.myPeerID,
                    isMaster: s.isMaster, clockPort: s.isMaster ? s.clockPort : nil))
            }
        }
        link.onMessage = { [weak self] msg in self?.onMain { $0.handleMessage(msg, link: link, knownPeerID: pid) } }
        link.onClose = { [weak self] in self?.onMain { $0.linkClosed(pid) } }
        link.start()
    }

    private func acceptInbound(_ link: ControlLink) {
        pendingInbound[ObjectIdentifier(link)] = link
        link.onMessage = { [weak self] msg in self?.onMain { $0.handleMessage(msg, link: link, knownPeerID: nil) } }
        link.onClose = { [weak self] in
            self?.onMain { s in
                s.pendingInbound[ObjectIdentifier(link)] = nil
                if let pid = s.links.first(where: { $0.value === link })?.key { s.linkClosed(pid) }
            }
        }
    }

    // MARK: messages de contrôle

    private func handleMessage(_ msg: ControlMessage, link: ControlLink, knownPeerID: String?) {
        switch msg.type {
        case .hello:
            // Côté récepteur de connexion : valider le PIN.
            guard msg.pin == pin, let pid = msg.peerID else {
                link.send(ControlMessage(type: .reject, reason: "PIN incorrect"))
                link.cancel()
                return
            }
            registerLink(link, peerID: pid, name: msg.name ?? pid, isMaster: msg.isMaster ?? false)
            if msg.isMaster == true, let cp = msg.clockPort { masterPeerID = pid; masterClockPort = cp }
            link.send(ControlMessage(
                type: .welcome, name: myName, peerID: myPeerID,
                isMaster: isMaster, clockPort: isMaster ? clockPort : nil))
            maybeStartClockClient()

        case .welcome:
            guard let pid = msg.peerID else { return }
            pendingOutbound.remove(pid)
            registerLink(link, peerID: pid, name: msg.name ?? pid, isMaster: msg.isMaster ?? false)
            if msg.isMaster == true, let cp = msg.clockPort { masterPeerID = pid; masterClockPort = cp }
            maybeStartClockClient()

        case .reject:
            statusMessage = "Connexion refusée : \(msg.reason ?? "PIN incorrect")."
            if let pid = knownPeerID { pendingOutbound.remove(pid) }
            link.cancel()

        case .subscribe:
            // Un peer veut recevoir mon son (il a été coché chez lui, ou il m'écoute).
            guard let pid = peerKey(link, knownPeerID),
                  let port = msg.audioPort, let host = link.remoteHost else { return }
            source?.addSubscriber(peerID: pid, host: host, port: port)
            setPeerFlag(pid) { $0.sendingToThem = true }

        case .unsubscribe:
            if let pid = peerKey(link, knownPeerID) {
                source?.removeSubscriber(peerID: pid)
                setPeerFlag(pid) { $0.sendingToThem = false }
            }

        case .requestPlay:
            // Un peer veut que je joue SON son sur ma sortie → je m'y abonne.
            guard let pid = peerKey(link, knownPeerID) else { return }
            startListening(pid, volume: msg.volume, delayMs: msg.delayMs)

        case .stopPlay:
            if let pid = peerKey(link, knownPeerID) { stopListening(pid) }

        case .streamSettings:
            // Un peer ajuste le volume/délai de SON son chez moi.
            if let pid = peerKey(link, knownPeerID) {
                if let v = msg.volume { streams[pid]?.setVolume(v) }
                if let d = msg.delayMs { streams[pid]?.setDelayMs(d) }
            }

        case .bye:
            if let pid = peerKey(link, knownPeerID) { linkClosed(pid) }
            link.cancel()
        }
    }

    private func peerKey(_ link: ControlLink, _ knownPeerID: String?) -> String? {
        knownPeerID ?? links.first(where: { $0.value === link })?.key
    }

    private func registerLink(_ link: ControlLink, peerID: String, name: String, isMaster: Bool) {
        pendingInbound[ObjectIdentifier(link)] = nil
        links[peerID] = link
        upsertPeer(peerID: peerID, name: name, isMaster: isMaster, connected: true)
        statusMessage = "Connecté à \(name)."
    }

    private func linkClosed(_ peerID: String) {
        links[peerID] = nil
        pendingOutbound.remove(peerID)
        detachStream(peerID)
        source?.removeSubscriber(peerID: peerID)
        peers.removeAll { $0.peerID == peerID }
        maybeStopBroadcasting()
    }

    // MARK: horloge commune (joiner → maître)

    private func maybeStartClockClient() {
        guard !isMaster, !clockClientStarted,
              let masterID = masterPeerID, masterClockPort != 0,
              let link = links[masterID], let host = link.remoteHost else { return }
        clockClientStarted = true
        let c = ClockSyncClient(clock: clock)
        c.onOffset = { [weak self] offset, rtt in
            self?.onMain { s in
                s.clockOffsetMs = Double(offset) / 1e6
                s.clockRttMs = Double(rtt) / 1e6
            }
        }
        c.start(host: host, port: masterClockPort)
        clockClient = c
        statusMessage = "Horloge synchronisée sur le maître."
    }

    // MARK: émission — cocher un Mac comme destination (mon son → lui)

    /// Coche/décoche un Mac comme destination de mon son. Je capte mon son
    /// (loopback) et je demande au peer de le jouer sur SES sorties.
    func setEmitToPeer(_ peerID: String, _ on: Bool) {
        guard let link = links[peerID] else { return }
        if on {
            guard ensureBroadcasting() else { return }
            let vol = peers.first { $0.peerID == peerID }?.destVolume
            let dly = peers.first { $0.peerID == peerID }?.destDelay
            link.send(ControlMessage(type: .requestPlay, volume: vol, delayMs: dly))
            setPeerFlag(peerID) { $0.sendingToThem = true }
        } else {
            link.send(ControlMessage(type: .stopPlay))
            source?.removeSubscriber(peerID: peerID)
            setPeerFlag(peerID) { $0.sendingToThem = false }
            maybeStopBroadcasting()
        }
    }

    /// Volume/délai de MON son chez un peer donné → envoyé au peer qui l'applique.
    func setDestVolume(_ peerID: String, _ v: Double) {
        setPeerFlag(peerID) { $0.destVolume = v }
        links[peerID]?.send(ControlMessage(type: .streamSettings, volume: v))
    }
    func setDestDelay(_ peerID: String, _ ms: Double) {
        setPeerFlag(peerID) { $0.destDelay = ms }
        links[peerID]?.send(ControlMessage(type: .streamSettings, delayMs: ms))
    }

    /// Démarre la capture loopback si besoin. `false` si le driver manque.
    @discardableResult
    private func ensureBroadcasting() -> Bool {
        if broadcasting { return true }
        guard let source, let loopback = loopbackDevice else {
            statusMessage = "Émettre requiert le driver loopback (« OutputsSync » comme sortie système)."
            return false
        }
        guard source.start(loopback: loopback) else {
            statusMessage = "Impossible de démarrer la capture."
            return false
        }
        broadcasting = true
        statusMessage = "J'émets — règle « OutputsSync » comme sortie système."
        return true
    }

    /// Coupe la capture quand plus aucun Mac ne reçoit mon son.
    private func maybeStopBroadcasting() {
        guard broadcasting, !peers.contains(where: { $0.sendingToThem }) else { return }
        source?.stop()
        broadcasting = false
    }

    // MARK: réception — écouter le son d'un peer (son son → moi)

    func toggleListen(_ peerID: String) {
        if streams[peerID] != nil { stopListening(peerID) } else { startListening(peerID) }
    }

    /// Démarre la lecture du son d'un peer sur ma sortie (idempotent).
    /// `volume`/`delayMs` fournis quand c'est le peer qui pousse son son.
    private func startListening(_ peerID: String, volume: Double? = nil, delayMs: Double? = nil) {
        guard let link = links[peerID] else { return }
        if let existing = streams[peerID] {
            if let v = volume { existing.setVolume(v) }
            if let d = delayMs { existing.setDelayMs(d) }
            return
        }
        guard let output = outputs.first(where: { $0.uid == selectedOutputUID }) ?? AudioDevices.defaultOutput() else {
            statusMessage = "Aucune sortie disponible."
            return
        }
        // Un mixeur par périphérique de sortie (mixe plusieurs flux).
        let mixer: OutputMixer
        if let existing = mixers[output.uid] {
            mixer = existing
        } else {
            let m = OutputMixer(clock: clock, device: output)
            guard m.start(device: output) else { statusMessage = "Impossible d'ouvrir la sortie."; return }
            mixers[output.uid] = m
            mixer = m
        }

        let stream = NetworkStream(peerID: peerID, outputRate: mixer.outputRate)
        if let v = volume { stream.setVolume(v) }
        if let d = delayMs { stream.setDelayMs(d) }
        stream.onReady = { [weak self] port in
            self?.onMain { _ in link.send(ControlMessage(type: .subscribe, audioPort: port)) }
        }
        guard stream.startReceiving() else {
            statusMessage = "Impossible de démarrer la réception."
            if mixer.isEmpty { mixer.stop(); mixers[output.uid] = nil }
            return
        }
        mixer.addStream(stream)
        streams[peerID] = stream
        setPeerFlag(peerID) { $0.listening = true }
    }

    private func stopListening(_ peerID: String) {
        links[peerID]?.send(ControlMessage(type: .unsubscribe))
        detachStream(peerID)
        setPeerFlag(peerID) { $0.listening = false }
    }

    /// Re-primer la lecture d'un peer déjà écouté (sortie changée, ou re-sync).
    private func restartListening(_ peerID: String) {
        guard streams[peerID] != nil else { return }
        stopListening(peerID)
        startListening(peerID)
    }

    // MARK: re-synchronisation manuelle

    /// Y a-t-il un chemin audio actif (j'émets ou j'écoute) ? Pilote le bouton Sync.
    var hasActiveAudio: Bool { broadcasting || peers.contains { $0.listening } }

    /// Re-aligne toutes les enceintes du salon : re-prime chaque chemin audio pour
    /// qu'il se re-verrouille sur l'horloge commune (après une dérive, un
    /// rebranchement ou un changement de sortie).
    func resync() {
        guard isActive else { return }
        // Côté source : demander à chaque Mac récepteur de relancer ma lecture.
        for peer in peers where peer.sendingToThem {
            guard let link = links[peer.peerID] else { continue }
            link.send(ControlMessage(type: .stopPlay))
            link.send(ControlMessage(type: .requestPlay, volume: peer.destVolume, delayMs: peer.destDelay))
        }
        // Côté enceinte : re-primer ma propre lecture de la source.
        for peer in peers where peer.listening { restartListening(peer.peerID) }
        statusMessage = hasActiveAudio ? "Re-synchronisation…" : "Rien à synchroniser."
    }

    /// Change la sortie locale d'écoute et y déplace les flux en cours.
    func setListenOutput(_ uid: String) {
        guard uid != selectedOutputUID else { return }
        selectedOutputUID = uid
        for peer in peers where peer.listening { restartListening(peer.peerID) }
    }

    /// Arrête le flux reçu d'un peer et libère son mixeur s'il devient vide.
    private func detachStream(_ peerID: String) {
        guard let stream = streams[peerID] else { return }
        stream.stop()
        streams[peerID] = nil
        for (uid, m) in mixers where m.removeStream(peerID: peerID) {
            if m.isEmpty { m.stop(); mixers[uid] = nil }
        }
    }

    // MARK: helpers état UI

    private func rebuildPeerRows(discovered found: [DiscoveredPeer]) {
        for p in found where !peers.contains(where: { $0.peerID == p.peerID }) {
            upsertPeer(peerID: p.peerID, name: p.name, isMaster: p.isMaster,
                       connected: links[p.peerID] != nil)
        }
    }

    private func upsertPeer(peerID: String, name: String, isMaster: Bool, connected: Bool) {
        if let i = peers.firstIndex(where: { $0.peerID == peerID }) {
            peers[i].name = name
            peers[i].isMaster = isMaster
            peers[i].connected = connected
        } else {
            peers.append(PeerRow(peerID: peerID, name: name, isMaster: isMaster,
                                 connected: connected, listening: false, sendingToThem: false))
        }
    }

    private func setPeerFlag(_ peerID: String, _ mutate: (inout PeerRow) -> Void) {
        guard let i = peers.firstIndex(where: { $0.peerID == peerID }) else { return }
        mutate(&peers[i])
    }

    /// Saute sur le MainActor en conservant l'ordre FIFO des callbacks réseau.
    private func onMain(_ body: @escaping (RoomManager) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body(self) } }
    }
}
