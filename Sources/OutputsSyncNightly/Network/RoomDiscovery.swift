import Foundation
import Network

/// Un peer découvert sur le LAN via Bonjour.
struct DiscoveredPeer: Identifiable, Equatable {
    let peerID: String
    let name: String
    let room: String
    let isMaster: Bool
    let needsPIN: Bool
    let clockPort: UInt16
    let endpoint: NWEndpoint

    var id: String { peerID }
    static func == (a: DiscoveredPeer, b: DiscoveredPeer) -> Bool {
        a.peerID == b.peerID && a.isMaster == b.isMaster && a.clockPort == b.clockPort
    }
}

/// Découverte des peers via Bonjour (`_outputssync._tcp`) et masque notre propre
/// peer. Si `room` est `nil`, découvre **toutes** les rooms (lobby) ; sinon
/// filtre sur ce nom de room.
final class RoomDiscovery: @unchecked Sendable {
    static let serviceType = "_outputssync._tcp"

    private let queue = DispatchQueue(label: "com.outputssync.discovery")
    private var browser: NWBrowser?

    private let myPeerID: String
    private let room: String?
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?

    init(myPeerID: String, room: String? = nil) {
        self.myPeerID = myPeerID
        self.room = room
    }

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: RoomDiscovery.serviceType, domain: nil), using: params)
        browser = b
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results)
        }
        b.start(queue: queue)
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var peers: [DiscoveredPeer] = []
        for result in results {
            guard case let .bonjour(txt) = result.metadata else { continue }
            guard let peerID = txt["peer"], peerID != myPeerID else { continue }
            guard let room = txt["room"] else { continue }
            if let filter = self.room, room != filter { continue }
            let name = txt["name"] ?? peerID
            let isMaster = (txt["master"] ?? "0") == "1"
            let needsPIN = (txt["pin"] ?? "0") == "1"
            let clockPort = UInt16(txt["clk"] ?? "0") ?? 0
            peers.append(DiscoveredPeer(peerID: peerID, name: name, room: room,
                                        isMaster: isMaster, needsPIN: needsPIN,
                                        clockPort: clockPort, endpoint: result.endpoint))
        }
        onPeersChanged?(peers)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
