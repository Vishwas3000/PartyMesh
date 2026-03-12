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
        // Reject if already connected to avoid duplicate sessions.
        let alreadyConnected = session.connectedPeers.contains(peerID)
        print("[MeshManager] 📨 Invitation from \(peerID.displayName) — \(alreadyConnected ? "rejected (already connected)" : "accepted")")
        invitationHandler(!alreadyConnected, alreadyConnected ? nil : session)
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

        pendingPeers.insert(peerID)
        print("[MeshManager] 🔍 Found \(peerID.displayName) — inviting… (our UUID wins)")
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Only remove from pending; actual cleanup happens in session state .notConnected.
        pendingPeers.remove(peerID)
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
            print("[MeshManager] ❌ Disconnected: \(peerID.displayName)  remaining=\(session.connectedPeers.count)")

            delegate?.meshManager(self, disconnectedPeer: peerID)
            delegate?.meshManager(self, didUpdateState: "Disconnected from \(peerID.displayName)")

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

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        for object in nearbyObjects {
            // Find the MCPeerID associated with this NIDiscoveryToken
            guard let peerID = peerTokens.first(where: { $1 == object.discoveryToken })?.key else {
                continue
            }
            connectedPeers[peerID] = object
            delegate?.meshManager(self, didReceiveNearbyObject: object, forPeer: peerID)
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
