import Foundation
import Network

/// Message de contrôle échangé sur TCP (une ligne JSON par message).
struct ControlMessage: Codable {
    enum Kind: String, Codable {
        case hello, welcome, reject, bye
        case subscribe, unsubscribe      // récepteur → émetteur : « envoie-moi ton son sur ce port »
        case requestPlay, stopPlay       // émetteur → récepteur : « joue mon son / arrête »
        case streamSettings              // émetteur → récepteur : volume/délai de mon son chez toi
    }
    var type: Kind
    var pin: String?
    var name: String?
    var peerID: String?
    var isMaster: Bool?
    var clockPort: UInt16?
    var audioPort: UInt16? // port UDP où le demandeur veut recevoir l'audio
    var volume: Double?
    var delayMs: Double?
    var reason: String?
}

/// Une connexion de contrôle authentifiée (entrante ou sortante). Transport
/// pur : lit/écrit des `ControlMessage` délimités par `\n` ; la logique de
/// handshake (PIN, rôles) vit dans `RoomManager`.
final class ControlLink: @unchecked Sendable {
    fileprivate static let paramsTCP: NWParameters = {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }()

    let connection: NWConnection
    private let queue: DispatchQueue
    private var inbound = Data()

    /// Adresse distante résolue (utile pour cibler l'horloge/l'audio UDP).
    var remoteHost: NWEndpoint.Host?

    var onReady: (() -> Void)?
    var onMessage: ((ControlMessage) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    /// Connexion sortante vers un endpoint découvert.
    init(endpoint: NWEndpoint, queue: DispatchQueue) {
        self.queue = queue
        self.connection = NWConnection(to: endpoint, using: ControlLink.paramsTCP)
    }

    /// Connexion entrante déjà acceptée par le listener.
    init(connection: NWConnection, queue: DispatchQueue) {
        self.queue = queue
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let path = self.connection.currentPath,
                   case let .hostPort(host, _)? = path.remoteEndpoint {
                    self.remoteHost = host
                }
                self.onReady?()
            case .failed, .cancelled:
                self.notifyClose()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ message: ControlMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A) // \n
        connection.send(content: data, completion: .idempotent)
    }

    func cancel() {
        connection.cancel()
        notifyClose()
    }

    private func notifyClose() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbound.append(data)
                self.drainLines()
            }
            if isComplete || error != nil {
                self.notifyClose()
            } else {
                self.receive()
            }
        }
    }

    private func drainLines() {
        while let nl = inbound.firstIndex(of: 0x0A) {
            let line = inbound.subdata(in: inbound.startIndex..<nl)
            inbound.removeSubrange(inbound.startIndex...nl)
            if let msg = try? JSONDecoder().decode(ControlMessage.self, from: line) {
                onMessage?(msg)
            }
        }
    }
}

/// Écoute les connexions de contrôle entrantes (TCP).
final class ControlServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.outputssync.control.server")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    var onReady: ((UInt16) -> Void)?
    var onAccept: ((ControlLink) -> Void)?

    func start() {
        do {
            let l = try NWListener(using: ControlLink.paramsTCP)
            listener = l
            l.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self, let p = l.port else { return }
                self.port = p.rawValue
                self.onReady?(p.rawValue)
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                let link = ControlLink(connection: conn, queue: self.queue)
                self.onAccept?(link)
                link.start()
            }
            l.start(queue: queue)
        } catch {
            NSLog("ControlServer start failed: \(error)")
        }
    }

    /// Annonce (ou met à jour) le service Bonjour porté par ce listener.
    func advertise(name: String, txt: [String: String]) {
        listener?.service = NWListener.Service(
            name: name, type: RoomDiscovery.serviceType, txtRecord: NWTXTRecord(txt))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var sharedQueue: DispatchQueue { queue }
}
