import Foundation
import MultipeerConnectivity
import NearbyInteraction
import UIKit // Required for UIDevice

// Sent over MultipeerConnectivity whenever a device is tapped.
// x/y are normalised (0–1) screen coords; wallTime is Unix timestamp of the tap.
struct RippleMessage: Codable {
    let messageType: String  // always "ripple"
    let x: Float
    let y: Float
    let wallTime: Double   // Date().timeIntervalSince1970 at the moment of tap
}

/// One point event in a collaborative drawing stroke.
struct StrokeMessage: Codable {
    let messageType: String  // always "stroke"
    let event: String        // "begin", "move", "end", "clear"
    let strokeID: String     // UUID grouping all events in one stroke
    let x: Float             // normalised 0-1
    let y: Float             // normalised 0-1
    let r: Float             // stroke colour components
    let g: Float
    let b: Float
    let lineWidth: Float
}

// Internal: first-pass decode to route by message type
private struct MessageTypeProbe: Codable { let messageType: String }

protocol MeshManagerDelegate: AnyObject {
    func meshManager(_ manager: MeshManager, didReceiveNearbyObject object: NINearbyObject, forPeer peerID: MCPeerID)
    func meshManager(_ manager: MeshManager, connectedPeer peerID: MCPeerID)
    func meshManager(_ manager: MeshManager, disconnectedPeer peerID: MCPeerID)
    func meshManager(_ manager: MeshManager, didUpdateState state: String)
    func meshManager(_ manager: MeshManager, didEncounterError error: Error)
    func meshManager(_ manager: MeshManager, didReceiveRipple ripple: RippleMessage, fromPeer peerID: MCPeerID)
    func meshManager(_ manager: MeshManager, didReceiveStroke stroke: StrokeMessage, fromPeer peerID: MCPeerID)
}

class MeshManager: NSObject, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate, NISessionDelegate {

    weak var delegate: MeshManagerDelegate?

    private let serviceType = "u1-mesh"
    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)

    /// Stable UUID broadcast in discoveryInfo so each peer can decide who invites whom.
    /// The device with the lexicographically higher UUID sends the invitation;
    /// the other waits to receive one. This prevents the double-invite race condition
    /// that causes immediate disconnect loops.
    private let sessionUUID = UUID().uuidString

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession!

    /// Peers we've invited but that haven't reached .connected yet.
    private var pendingPeers: Set<MCPeerID> = []

    // MARK: - K-Neighbor topology

    /// Maximum simultaneous MCSession connections.
    /// Apple's MCSession hard-limit is 8; we cap at 5 to leave headroom and
    /// to keep the local graph sparse (4 proximity neighbours + 1 random long-range).
    private let maxNeighbors = 5

    /// Peers discovered via Bonjour but not connected because we were at maxNeighbors.
    /// Keyed by MCPeerID; value is the peer's sessionUUID (already passed the tiebreaker,
    /// so we can invite them directly when a slot opens).
    private var candidatePeers: [MCPeerID: String] = [:]

    /// The MCPeerID occupying the "random long-range" slot — the last peer to connect
    /// when we hit maxNeighbors. This peer is exempt from distance-based eviction so
    /// the graph always has at least one non-proximity link, reducing partition risk.
    private var randomSlotPeer: MCPeerID?

    var niSession: NISession?
    var peerTokens: [MCPeerID: NIDiscoveryToken] = [:]
    var connectedPeers: [MCPeerID: NINearbyObject] = [:]

    override init() {
        super.init()
        buildSession()
    }

    // MARK: - Session lifecycle

    private func buildSession() {
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    /// Tear down and recreate MCSession so the next foundPeer connects cleanly.
    /// Called whenever the last peer disconnects.
    private func rebuildSession() {
        session.disconnect()
        buildSession()
        pendingPeers.removeAll()
        candidatePeers.removeAll()
        randomSlotPeer = nil
        print("[MeshManager] 🔄 Session rebuilt — ready for fresh connections")
    }

    func start() {
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                               discoveryInfo: ["sid": sessionUUID],
                                               serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        niSession = NISession()
        niSession?.delegate = self

        // Restart discovery every time the app comes back to the foreground.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)

        delegate?.meshManager(self, didUpdateState: "Searching for peers…")
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        niSession?.invalidate()
        niSession = nil
        pendingPeers.removeAll()
        candidatePeers.removeAll()
        randomSlotPeer = nil
        delegate?.meshManager(self, didUpdateState: "Stopped.")
    }

    @objc private func appDidBecomeActive() {
        // Stop-then-start forces a fresh Bonjour registration — fixes stale
        // service records left behind when the app was backgrounded.
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser?.startAdvertisingPeer()
        browser?.startBrowsingForPeers()
        print("[MeshManager] 🟢 App active — restarted discovery")
    }

    // MARK: - MCNearbyServiceAdvertiserDelegate

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let alreadyConnected = session.connectedPeers.contains(peerID)
        let atCapacity = session.connectedPeers.count + pendingPeers.count >= maxNeighbors
        let accept = !alreadyConnected && !atCapacity
        let reason = alreadyConnected ? "already connected" : atCapacity ? "at K=\(maxNeighbors) capacity" : "accepted"
        print("[MeshManager] 📨 Invitation from \(peerID.displayName) — \(reason)")
        invitationHandler(accept, accept ? session : nil)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[MeshManager] ⚠️ Advertiser failed: \(error.localizedDescription) — retrying in 3s")
        delegate?.meshManager(self, didEncounterError: error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.advertiser?.startAdvertisingPeer()
        }
    }

    // MARK: - MCNearbyServiceBrowserDelegate

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        guard !session.connectedPeers.contains(peerID),
              !pendingPeers.contains(peerID) else {
            print("[MeshManager] ↩️ Skipping \(peerID.displayName) — already connected or pending")
            return
        }

        // UUID tiebreaker: only the device with the higher sessionUUID sends the
        // invitation. The lower-UUID device waits to receive one from the other side.
        // This guarantees exactly one connection attempt regardless of timing,
        // eliminating the double-invite → immediate-disconnect loop.
        if let peerSID = info?["sid"] {
            guard sessionUUID > peerSID else {
                print("[MeshManager] ↩️ Lower UUID — waiting for \(peerID.displayName) to invite us")
                return
            }
        }

        let totalActive = session.connectedPeers.count + pendingPeers.count
        guard totalActive < maxNeighbors else {
            // At K-neighbor capacity. Park this peer as a candidate: when any current
            // neighbor disconnects or is evicted, connectNextCandidate() will pick it up.
            candidatePeers[peerID] = info?["sid"] ?? ""
            print("[MeshManager] 📋 At K=\(maxNeighbors) — \(peerID.displayName) queued as candidate (\(candidatePeers.count) waiting)")
            return
        }

        // If this fills the last slot, mark it as the random long-range peer.
        // All earlier slots are considered proximity peers (connected in discovery order).
        if totalActive == maxNeighbors - 1 {
            randomSlotPeer = peerID
            print("[MeshManager] 🎲 \(peerID.displayName) assigned to random long-range slot")
        }

        pendingPeers.insert(peerID)
        print("[MeshManager] 🔍 Found \(peerID.displayName) — inviting… (\(totalActive + 1)/\(maxNeighbors) slots)")
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Only remove from pending; actual cleanup happens in session state .notConnected.
        pendingPeers.remove(peerID)
        candidatePeers.removeValue(forKey: peerID)
        print("[MeshManager] 🔍 Lost sight of \(peerID.displayName)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[MeshManager] ⚠️ Browser failed: \(error.localizedDescription) — retrying in 3s")
        delegate?.meshManager(self, didEncounterError: error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.browser?.startBrowsingForPeers()
        }
    }

    // MARK: - MCSessionDelegate

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // After rebuildSession(), the old MCSession still holds a delegate reference
        // and can fire stale callbacks. Ignore any event that isn't from the
        // current live session to prevent cascading rebuilds.
        guard session === self.session else {
            print("[MeshManager] ↩️ Ignoring state change from replaced session — \(peerID.displayName) \(state.rawValue)")
            return
        }

        switch state {
        case .connected:
            pendingPeers.remove(peerID)
            print("[MeshManager] ✅ Connected: \(peerID.displayName)")
            delegate?.meshManager(self, connectedPeer: peerID)
            delegate?.meshManager(self, didUpdateState: "Connected to \(peerID.displayName)")
            sendMyToken(to: peerID)

        case .connecting:
            print("[MeshManager] ⏳ Connecting: \(peerID.displayName)…")
            delegate?.meshManager(self, didUpdateState: "Connecting to \(peerID.displayName)…")

        case .notConnected:
            pendingPeers.remove(peerID)
            peerTokens.removeValue(forKey: peerID)
            connectedPeers.removeValue(forKey: peerID)
            if randomSlotPeer == peerID { randomSlotPeer = nil }
            print("[MeshManager] ❌ Disconnected: \(peerID.displayName)  remaining=\(session.connectedPeers.count)")

            delegate?.meshManager(self, disconnectedPeer: peerID)
            delegate?.meshManager(self, didUpdateState: "Disconnected from \(peerID.displayName)")

            // A slot just opened — promote a waiting candidate before deciding
            // whether to rebuild. This fills the vacancy without a full teardown.
            connectNextCandidate()

            if session.connectedPeers.isEmpty {
                // Rebuild MCSession so the next peer gets a clean slate.
                rebuildSession()
                // Recreate NISession immediately so its token is ready before
                // the next peer connects. NISession must be touched on main thread.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.niSession?.invalidate()
                    self.niSession = NISession()
                    self.niSession?.delegate = self
                    print("[MeshManager] 🔄 NISession recreated — token ready: \(self.niSession?.discoveryToken != nil)")
                }
            } else {
                // Refresh NI for remaining peers (also on main thread).
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.niSession == nil {
                        self.niSession = NISession()
                        self.niSession?.delegate = self
                    }
                    for (pid, token) in self.peerTokens where self.session.connectedPeers.contains(pid) {
                        self.niSession?.run(NINearbyPeerConfiguration(peerToken: token))
                    }
                }
            }

        @unknown default:
            fatalError("Unhandled MCSessionState")
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Route JSON messages by messageType; binary data is NIDiscoveryToken.
        if let probe = try? JSONDecoder().decode(MessageTypeProbe.self, from: data) {
            switch probe.messageType {
            case "ripple":
                if let ripple = try? JSONDecoder().decode(RippleMessage.self, from: data) {
                    print("[MeshManager] 📡 Ripple from \(peerID.displayName)  age=\(String(format:"%.3f", Date().timeIntervalSince1970 - ripple.wallTime))s")
                    DispatchQueue.main.async {
                        self.delegate?.meshManager(self, didReceiveRipple: ripple, fromPeer: peerID)
                    }
                }
            case "stroke":
                if let stroke = try? JSONDecoder().decode(StrokeMessage.self, from: data) {
                    DispatchQueue.main.async {
                        self.delegate?.meshManager(self, didReceiveStroke: stroke, fromPeer: peerID)
                    }
                }
            default:
                break
            }
            return
        }

        // NIDiscoveryToken exchange (binary, not JSON)
        do {
            if let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) {
                peerTokens[peerID] = token
                print("[MeshManager] 🤝 Received NI token from \(peerID.displayName) — starting NI session")
                delegate?.meshManager(self, didUpdateState: "Received NI token from \(peerID.displayName)")
                // NISession.run must be called on the main thread.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard let niSession = self.niSession else {
                        print("[MeshManager] ❌ niSession is nil when token arrived from \(peerID.displayName)")
                        self.delegate?.meshManager(self, didUpdateState: "⚠️ NI session nil for \(peerID.displayName)")
                        return
                    }
                    niSession.run(NINearbyPeerConfiguration(peerToken: token))
                }
            }
        } catch {
            delegate?.meshManager(self, didEncounterError: error)
        }
    }

    /// Broadcasts a ripple event to all connected peers.
    func sendRipple(normalizedX: Float, normalizedY: Float) {
        guard !session.connectedPeers.isEmpty else { return }
        let msg = RippleMessage(messageType: "ripple", x: normalizedX, y: normalizedY,
                                wallTime: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(msg) else { return }
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("[MeshManager] 📤 Sent ripple to \(session.connectedPeers.map(\.displayName))")
        } catch {
            delegate?.meshManager(self, didEncounterError: error)
        }
    }

    /// Broadcasts a stroke event to all connected peers.
    /// Uses .unreliable for "move" events (low latency, drops OK) and .reliable for begin/end/clear.
    func sendStroke(_ stroke: StrokeMessage) {
        guard !session.connectedPeers.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(stroke) else { return }
        let reliability: MCSessionSendDataMode = stroke.event == "move" ? .unreliable : .reliable
        try? session.send(data, toPeers: session.connectedPeers, with: reliability)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Not used for this POC
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Not used for this POC
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // Not used for this POC
    }

    // MARK: - K-Neighbor helpers

    /// Invites the first available candidate peer when a connection slot has opened.
    /// Called from .notConnected so the vacancy is filled as soon as possible.
    private func connectNextCandidate() {
        guard let browser else { return }
        let totalActive = session.connectedPeers.count + pendingPeers.count
        guard totalActive < maxNeighbors else { return }

        // Pick the first candidate that hasn't gone stale (still visible via Bonjour).
        // candidatePeers is ordered by insertion (Swift Dict is unordered, but for
        // small N this is fine — future work can sort by distance once NI gossip lands).
        guard let (candidateID, _) = candidatePeers.first else {
            print("[MeshManager] 📋 No candidates in queue")
            return
        }

        candidatePeers.removeValue(forKey: candidateID)
        pendingPeers.insert(candidateID)
        browser.invitePeer(candidateID, to: session, withContext: nil, timeout: 10)
        print("[MeshManager] 📋 Slot opened — promoting candidate \(candidateID.displayName) (\(candidatePeers.count) remaining)")
    }

    /// Returns the connected peer with the highest NI distance, excluding the random-slot peer.
    /// Used to identify the best eviction candidate once per-peer MCSession is in place.
    /// Currently informational only — MCSession doesn't support per-peer disconnect.
    private func farthestProximityPeer() -> (MCPeerID, Float)? {
        connectedPeers
            .filter { $0.key != randomSlotPeer }
            .compactMap { (pid, obj) -> (MCPeerID, Float)? in
                guard let dist = obj.distance else { return nil }
                return (pid, dist)
            }
            .max(by: { $0.1 < $1.1 })
    }

    // MARK: - NearbyInteraction

    /// Sends our NIDiscoveryToken to `peerID`.
    /// Retries on main thread because:
    ///   1. MCSession delegate fires on a background queue.
    ///   2. NISession.discoveryToken needs one run-loop tick after NISession() init.
    private func sendMyToken(to peerID: MCPeerID, attempt: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard let token = self.niSession?.discoveryToken else {
                if attempt < 5 {
                    print("[MeshManager] ⏳ Token not ready for \(peerID.displayName), retry \(attempt + 1)/5")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.sendMyToken(to: peerID, attempt: attempt + 1)
                    }
                } else {
                    print("[MeshManager] ❌ Token still nil after 5 attempts for \(peerID.displayName)")
                    self.delegate?.meshManager(self, didUpdateState: "⚠️ NI token unavailable for \(peerID.displayName)")
                }
                return
            }

            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
                try self.session.send(data, toPeers: [peerID], with: .reliable)
                print("[MeshManager] 📤 NI token sent to \(peerID.displayName) on attempt \(attempt + 1)")
                self.delegate?.meshManager(self, didUpdateState: "Sent NI token to \(peerID.displayName)")
            } catch {
                self.delegate?.meshManager(self, didEncounterError: error)
            }
        }
    }

    /// Evict threshold: disconnect a proximity peer when it drifts beyond this distance.
    /// The random-slot peer is exempt. Actual disconnect requires per-peer MCSession
    /// (tracked in docs/large-scale-mesh-networking.md — build step 4). For now this
    /// logs the signal so the threshold can be tuned before the architecture upgrade.
    private let evictDistanceThreshold: Float = 4.0  // metres

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        for object in nearbyObjects {
            // Find the MCPeerID associated with this NIDiscoveryToken
            guard let peerID = peerTokens.first(where: { $1 == object.discoveryToken })?.key else {
                continue
            }
            connectedPeers[peerID] = object
            delegate?.meshManager(self, didReceiveNearbyObject: object, forPeer: peerID)

            // Distance-based eviction signal.
            // TODO: replace log with actual disconnect once per-peer MCSession lands.
            if let dist = object.distance {
                let slot = peerID == randomSlotPeer ? " [random-slot, exempt]" : ""
                print("[MeshManager] 📏 \(peerID.displayName): \(String(format: "%.2f", dist))m\(slot)")

                if dist > evictDistanceThreshold, peerID != randomSlotPeer {
                    print("[MeshManager] ⚠️ \(peerID.displayName) at \(String(format: "%.1f", dist))m > threshold — eviction candidate (needs per-peer MCSession)")
                }
            }
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        for object in nearbyObjects {
            guard let peerID = peerTokens.first(where: { $1 == object.discoveryToken })?.key else { continue }
            connectedPeers.removeValue(forKey: peerID)
            delegate?.meshManager(self, didUpdateState: "Removed nearby object for \(peerID.displayName) due to reason: \(reason.rawValue)")
            
            // If the peer is still connected via Multipeer Connectivity, try to re-run NI session for it.
            if self.session.connectedPeers.contains(peerID) {
                if let token = peerTokens[peerID], let niSession = self.niSession {
                    let config = NINearbyPeerConfiguration(peerToken: token)
                    niSession.run(config)
                }
            }
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        delegate?.meshManager(self, didEncounterError: error)
        delegate?.meshManager(self, didUpdateState: "NearbyInteraction session invalidated with error: \(error.localizedDescription)")
        
        // Attempt to restart NISession if possible
        niSession = NISession()
        niSession?.delegate = self
        
        // Re-run configurations for existing active peers
        for (peerID, token) in peerTokens where self.session.connectedPeers.contains(peerID) {
            let config = NINearbyPeerConfiguration(peerToken: token)
            niSession?.run(config)
        }
    }
}
