import Foundation
import MultipeerConnectivity
import NearbyInteraction
import UIKit

// MARK: - Message Types

struct RippleMessage: Codable {
    let messageType: String
    let x: Float
    let y: Float
    let wallTime: Double
}

struct StrokeMessage: Codable {
    let messageType: String
    let event: String
    let strokeID: String
    let x: Float
    let y: Float
    let r: Float
    let g: Float
    let b: Float
    let lineWidth: Float
}

private struct MessageTypeProbe: Codable { let messageType: String }

// MARK: - Delegate

protocol MeshManagerDelegate: AnyObject {
    func meshManager(_ manager: MeshManager, didReceiveNearbyObject object: NINearbyObject, forPeer peerID: MCPeerID)
    func meshManager(_ manager: MeshManager, connectedPeer peerID: MCPeerID)
    func meshManager(_ manager: MeshManager, disconnectedPeer peerID: MCPeerID)
    func meshManager(_ manager: MeshManager, didUpdateState state: String)
    func meshManager(_ manager: MeshManager, didEncounterError error: Error)
    func meshManager(_ manager: MeshManager, didReceiveRipple ripple: RippleMessage, fromPeer peerID: MCPeerID)
    func meshManager(_ manager: MeshManager, didReceiveStroke stroke: StrokeMessage, fromPeer peerID: MCPeerID)
}

// MARK: - MeshManager

class MeshManager: NSObject {

    weak var delegate: MeshManagerDelegate?

    // MARK: Identity

    private let serviceType = "u1-mesh"
    private let myPeerID    = MCPeerID(displayName: UIDevice.current.name)

    /// Stable UUID broadcast in discoveryInfo so each peer can decide who invites whom.
    /// The device with the lexicographically higher UUID sends the invitation —
    /// eliminates the double-invite race condition.
    private let sessionUUID = UUID().uuidString

    // MARK: Discovery

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser:    MCNearbyServiceBrowser?

    // MARK: Per-peer MCSession
    //
    // KEY ARCHITECTURE DECISION:
    // One MCSession per neighbour instead of one shared session.
    // This is what makes selective disconnect possible: calling
    // sessions[peerID]?.disconnect() drops only that one edge.
    // A shared session only supports session.disconnect() which drops everyone.

    /// Live sessions, one per directly-connected or pending neighbour.
    private var sessions: [MCPeerID: MCSession] = [:]

    /// Peers whose session is .connected (subset of sessions.keys).
    private(set) var connectedPeerSet: Set<MCPeerID> = []

    /// Peers we have invited but whose session hasn't reached .connected yet.
    private var pendingPeers: Set<MCPeerID> = []

    // MARK: K-Neighbor Topology

    /// Hard cap on simultaneous MCSession connections.
    /// 5 = 4 proximity slots + 1 random long-range slot.
    private let maxNeighbors = 5

    /// Distance threshold (metres). A proximity-slot peer beyond this is an
    /// eviction candidate if a closer replacement (candidate) is waiting.
    private let evictDistanceThreshold: Float = 4.0

    /// Hysteresis guard: don't re-invite a peer we just evicted until their
    /// NI distance drops below this (prevents oscillation at the boundary).
    private let reconnectDistanceThreshold: Float = 2.0

    /// Peers seen via Bonjour but not connected because we were at maxNeighbors.
    /// Stored with a timestamp so `connectNextCandidate` can prefer the most
    /// recently-seen one (most recently seen ≈ still physically nearby).
    private struct CandidateInfo {
        let sessionUUID: String
        var lastSeen: Date
    }
    private var candidatePeers: [MCPeerID: CandidateInfo] = [:]

    /// The last peer to fill the Kth slot — exempt from distance eviction.
    /// Guarantees at least one non-proximity edge in the graph, reducing
    /// the risk of the network splitting into disconnected islands.
    private var randomSlotPeer: MCPeerID?

    /// Guards against firing eviction for the same peer on consecutive NI ticks
    /// before the disconnect callback has had a chance to run.
    private var evictionInFlight: Set<MCPeerID> = []

    /// Timestamp at which each peer was last evicted.
    /// Prevents a freshly-evicted peer from immediately re-entering the candidate
    /// queue before they've had a chance to physically move closer.
    private var recentlyEvicted: [MCPeerID: Date] = [:]

    /// How long (seconds) an evicted peer must sit out before being re-queued.
    private let evictionCooldown: TimeInterval = 30

    // MARK: Periodic Rebalance

    /// Fires every `rebalanceInterval` seconds to catch cases where NI has gone
    /// quiet (UWB occlusion, peer idle) but a closer candidate is still waiting.
    /// Also rotates the random slot periodically for better graph diversity.
    private var rebalanceTimer: Timer?
    private let rebalanceInterval: TimeInterval = 15

    // MARK: NearbyInteraction

    var niSession:    NISession?
    var peerTokens:   [MCPeerID: NIDiscoveryToken] = [:]

    /// Latest NI measurement per peer. Used for eviction decisions and UI.
    var connectedPeers: [MCPeerID: NINearbyObject] = [:]

    // MARK: - Init

    override init() {
        super.init()
    }

    // MARK: - Lifecycle

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

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)

        rebalanceTimer = Timer.scheduledTimer(withTimeInterval: rebalanceInterval,
                                              repeats: true) { [weak self] _ in
            self?.periodicRebalance()
        }

        delegate?.meshManager(self, didUpdateState: "Searching for peers…")
    }

    func stop() {
        rebalanceTimer?.invalidate()
        rebalanceTimer = nil
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        sessions.values.forEach { $0.disconnect() }
        sessions.removeAll()
        connectedPeerSet.removeAll()
        pendingPeers.removeAll()
        candidatePeers.removeAll()
        evictionInFlight.removeAll()
        recentlyEvicted.removeAll()
        randomSlotPeer = nil
        niSession?.invalidate()
        niSession = nil
        delegate?.meshManager(self, didUpdateState: "Stopped.")
    }

    @objc private func appDidBecomeActive() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser?.startAdvertisingPeer()
        browser?.startBrowsingForPeers()
        print("[MeshManager] 🟢 App active — restarted discovery")
    }

    // MARK: - Per-peer session factory

    /// Creates a fresh MCSession dedicated to one neighbour and registers it.
    /// Using separate sessions means `sessions[peerID]?.disconnect()` drops
    /// exactly that one edge without touching anyone else.
    private func makeSession(for peerID: MCPeerID) -> MCSession {
        let s = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        sessions[peerID] = s
        return s
    }

    // MARK: - K-Neighbor helpers

    /// Current number of active connections (connected + in-flight invitations).
    private var totalActive: Int { connectedPeerSet.count + pendingPeers.count }

    /// Evicts a specific peer by disconnecting only their session.
    /// The freed slot triggers `connectNextCandidate` via the .notConnected callback.
    private func evict(peer peerID: MCPeerID) {
        guard !evictionInFlight.contains(peerID) else { return }
        evictionInFlight.insert(peerID)
        recentlyEvicted[peerID] = Date()
        print("[MeshManager] ⚡ Evicting \(peerID.displayName) — freeing slot for closer candidate")
        sessions[peerID]?.disconnect()
        // Cleanup and candidate promotion happen in the .notConnected branch below.
    }

    /// Connects the best waiting candidate when a slot opens.
    /// "Best" = most recently seen by Bonjour (most recent ≈ still physically close).
    private func connectNextCandidate() {
        guard let browser else { return }
        guard totalActive < maxNeighbors else { return }

        // Sort candidates by lastSeen descending — recently seen peer is likely still nearby.
        let sorted = candidatePeers.sorted { $0.value.lastSeen > $1.value.lastSeen }
        guard let (candidateID, _) = sorted.first else {
            print("[MeshManager] 📋 No candidates in queue")
            return
        }

        candidatePeers.removeValue(forKey: candidateID)
        pendingPeers.insert(candidateID)
        let s = makeSession(for: candidateID)
        browser.invitePeer(candidateID, to: s, withContext: nil, timeout: 10)
        print("[MeshManager] 📋 Promoting candidate \(candidateID.displayName) (\(candidatePeers.count) remaining)")
    }

    /// Returns the proximity-slot peer with the greatest NI distance, if any.
    /// Used to decide whether an eviction is worth triggering.
    private func farthestProximityPeer() -> (MCPeerID, Float)? {
        connectedPeerSet
            .filter { $0 != randomSlotPeer }
            .compactMap { pid -> (MCPeerID, Float)? in
                guard let dist = connectedPeers[pid]?.distance else { return nil }
                return (pid, dist)
            }
            .max(by: { $0.1 < $1.1 })
    }

    // MARK: - Periodic Rebalance

    /// Called every `rebalanceInterval` seconds. Catches topology drift that the
    /// reactive NI path misses — e.g. NI went quiet while a candidate is waiting,
    /// or the random slot hasn't changed in a long time.
    ///
    /// Three checks in priority order:
    ///   1. Free slot + candidates waiting → promote immediately.
    ///   2. Farthest proximity peer > threshold + candidates waiting → evict.
    ///   3. Random slot has held for > 2× rebalance intervals → rotate it out
    ///      so different long-range nodes get a turn (improves graph diversity).
    @objc private func periodicRebalance() {
        // ── 1. Fill any open slots ────────────────────────────────────────────
        if totalActive < maxNeighbors && !candidatePeers.isEmpty {
            print("[MeshManager] 🔄 Rebalance: open slot found — promoting candidate")
            connectNextCandidate()
            return
        }

        // ── 2. Evict stale far peer (NI may have gone quiet) ──────────────────
        if !candidatePeers.isEmpty,
           let (farthestID, farthestDist) = farthestProximityPeer(),
           farthestDist > evictDistanceThreshold,
           !evictionInFlight.contains(farthestID) {
            print("[MeshManager] 🔄 Rebalance: \(farthestID.displayName) still far at \(String(format:"%.1f",farthestDist))m — evicting")
            evict(peer: farthestID)
            return
        }

        // ── 3. Rotate random slot for graph diversity ─────────────────────────
        // If we're at full capacity AND a candidate is waiting AND the random
        // slot peer has a known NI distance (meaning they're still close), swap
        // them out — a peer with no NI data (truly long-range) is a better fit.
        if connectedPeerSet.count == maxNeighbors,
           !candidatePeers.isEmpty,
           let rsp = randomSlotPeer,
           connectedPeers[rsp]?.distance != nil,       // random slot is actually nearby — not diverse
           !evictionInFlight.contains(rsp) {
            print("[MeshManager] 🔄 Rebalance: random slot \(rsp.displayName) is nearby — rotating for diversity")
            randomSlotPeer = nil   // clear before eviction so it's treated as a proximity slot
            evict(peer: rsp)
        }
    }

    // MARK: - Send

    func sendRipple(normalizedX: Float, normalizedY: Float) {
        guard !connectedPeerSet.isEmpty else { return }
        let msg = RippleMessage(messageType: "ripple", x: normalizedX, y: normalizedY,
                                wallTime: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(msg) else { return }
        for peerID in connectedPeerSet {
            try? sessions[peerID]?.send(data, toPeers: [peerID], with: .reliable)
        }
        print("[MeshManager] 📤 Sent ripple to \(connectedPeerSet.map(\.displayName))")
    }

    func sendStroke(_ stroke: StrokeMessage) {
        guard !connectedPeerSet.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(stroke) else { return }
        let mode: MCSessionSendDataMode = stroke.event == "move" ? .unreliable : .reliable
        for peerID in connectedPeerSet {
            try? sessions[peerID]?.send(data, toPeers: [peerID], with: mode)
        }
    }

    // MARK: - NI token exchange

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
                    print("[MeshManager] ❌ Token nil after 5 attempts for \(peerID.displayName)")
                    self.delegate?.meshManager(self, didUpdateState: "⚠️ NI token unavailable for \(peerID.displayName)")
                }
                return
            }
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
                try self.sessions[peerID]?.send(data, toPeers: [peerID], with: .reliable)
                print("[MeshManager] 📤 NI token sent to \(peerID.displayName) on attempt \(attempt + 1)")
                self.delegate?.meshManager(self, didUpdateState: "Sent NI token to \(peerID.displayName)")
            } catch {
                self.delegate?.meshManager(self, didEncounterError: error)
            }
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshManager: MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let alreadyConnected = connectedPeerSet.contains(peerID)
        let atCapacity = totalActive >= maxNeighbors
        let accept = !alreadyConnected && !atCapacity

        let reason = alreadyConnected ? "already connected"
                   : atCapacity       ? "at K=\(maxNeighbors) capacity"
                   :                    "accepted"
        print("[MeshManager] 📨 Invitation from \(peerID.displayName) — \(reason)")

        if accept {
            pendingPeers.insert(peerID)
            invitationHandler(true, makeSession(for: peerID))
        } else {
            invitationHandler(false, nil)
            // Even though we rejected, queue the peer as a candidate so the
            // rebalance timer can invite them when a slot opens.
            // This handles the case where UUID_peer > UUID_self — the browser
            // path returned early ("waiting for peer to invite us"), so the peer
            // never ended up in candidatePeers. Now that the peer knocked on our
            // door, we know they exist and are nearby.
            if atCapacity && !alreadyConnected && candidatePeers[peerID] == nil {
                candidatePeers[peerID] = CandidateInfo(sessionUUID: "", lastSeen: Date())
                print("[MeshManager] 📋 Rejected \(peerID.displayName) (at capacity) — queued as candidate")
            }
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[MeshManager] ⚠️ Advertiser failed: \(error.localizedDescription) — retrying in 3s")
        delegate?.meshManager(self, didEncounterError: error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.advertiser?.startAdvertisingPeer()
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshManager: MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        
//        foundPeer(B) fires on A
//                │
//                ▼
//        Is B in recentlyEvicted and cooldown active?  → return (blocked)
//                │ NO
//                ▼
//        Is B already in candidatePeers?  → refresh lastSeen, return
//                │ NO
//                ▼
//        Is B already connected or pending?  → return
//                │ NO
//                ▼
//        Is my UUID > B's UUID?  → NO → return ("waiting for B to invite me")
//                │ YES
//                ▼
//        Is totalActive < maxNeighbors (K=5)?  → NO → queue B in candidatePeers, return
//                │ YES
//                ▼
//        Is this the last slot? → YES → mark B as randomSlotPeer
//                │
//                ▼
//        pendingPeers.insert(B)
//        makeSession(for: B)        ← creates MCSession, stores in sessions[B]
//        browser.invitePeer(B, to: session, timeout: 10)   ← INVITATION SENT

        // Hysteresis: skip peers we evicted recently so they don't immediately
        // bounce back into the candidate queue before moving physically closer.
        if let evictedAt = recentlyEvicted[peerID] {
            if Date().timeIntervalSince(evictedAt) < evictionCooldown {
                print("[MeshManager] ⏳ \(peerID.displayName) in eviction cooldown (\(Int(evictionCooldown))s) — skipping")
                return
            }
            // Cooldown expired — clear the record and allow re-queuing.
            recentlyEvicted.removeValue(forKey: peerID)
            print("[MeshManager] ✅ \(peerID.displayName) cooldown expired — eligible for re-queue")
        }

        // Refresh lastSeen if already a candidate, then bail — no other action needed.
        if candidatePeers[peerID] != nil {
            candidatePeers[peerID]?.lastSeen = Date()
            print("[MeshManager] 📋 Re-seen candidate \(peerID.displayName) — lastSeen refreshed")
            return
        }

        guard !connectedPeerSet.contains(peerID), !pendingPeers.contains(peerID) else {
            print("[MeshManager] ↩️ Skipping \(peerID.displayName) — already connected or pending")
            return
        }

        // UUID tiebreaker: higher UUID sends the invitation, preventing the
        // double-invite race condition that causes immediate disconnect loops.
        if let peerSID = info?["sid"] {
            guard sessionUUID > peerSID else {
                print("[MeshManager] ↩️ Lower UUID — waiting for \(peerID.displayName) to invite us")
                return
            }
        }

        guard totalActive < maxNeighbors else {
            // At K capacity. Queue as candidate — will be promoted when a slot opens
            // (either by natural disconnect or distance-based eviction).
            candidatePeers[peerID] = CandidateInfo(sessionUUID: info?["sid"] ?? "",
                                                    lastSeen: Date())
            print("[MeshManager] 📋 At K=\(maxNeighbors) — \(peerID.displayName) queued (\(candidatePeers.count) waiting)")
            return
        }

        // If this fills the last slot, mark it as the random long-range peer.
        if totalActive == maxNeighbors - 1 {
            randomSlotPeer = peerID
            print("[MeshManager] 🎲 \(peerID.displayName) fills random long-range slot")
        }

        pendingPeers.insert(peerID)
        print("[MeshManager] 🔍 Found \(peerID.displayName) — inviting… (\(totalActive + 1)/\(maxNeighbors) slots)")
        browser.invitePeer(peerID, to: makeSession(for: peerID), withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
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
}

// MARK: - MCSessionDelegate

extension MeshManager: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // With per-peer sessions, each callback identifies itself by the session object.
        // Stale callbacks from a session we've already replaced are silently dropped.
        guard sessions[peerID] === session else {
            print("[MeshManager] ↩️ Stale session callback — \(peerID.displayName) \(state.rawValue)")
            return
        }

        switch state {

        case .connected:
            pendingPeers.remove(peerID)
            connectedPeerSet.insert(peerID)
            print("[MeshManager] ✅ Connected: \(peerID.displayName)  total=\(connectedPeerSet.count)")
            delegate?.meshManager(self, connectedPeer: peerID)
            delegate?.meshManager(self, didUpdateState: "Connected to \(peerID.displayName)")
            sendMyToken(to: peerID)

        case .connecting:
            print("[MeshManager] ⏳ Connecting: \(peerID.displayName)…")
            delegate?.meshManager(self, didUpdateState: "Connecting to \(peerID.displayName)…")

        case .notConnected:
            pendingPeers.remove(peerID)
            connectedPeerSet.remove(peerID)
            sessions.removeValue(forKey: peerID)
            peerTokens.removeValue(forKey: peerID)
            connectedPeers.removeValue(forKey: peerID)
            evictionInFlight.remove(peerID)
            if randomSlotPeer == peerID { randomSlotPeer = nil }

            print("[MeshManager] ❌ Disconnected: \(peerID.displayName)  remaining=\(connectedPeerSet.count)")
            delegate?.meshManager(self, disconnectedPeer: peerID)
            delegate?.meshManager(self, didUpdateState: "Disconnected from \(peerID.displayName)")

            // Slot just opened — promote best waiting candidate immediately.
            connectNextCandidate()

            if connectedPeerSet.isEmpty && pendingPeers.isEmpty {
                // Truly alone — recreate NISession so its token is fresh for the next peer.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.niSession?.invalidate()
                    self.niSession = NISession()
                    self.niSession?.delegate = self
                    print("[MeshManager] 🔄 NISession recreated — token ready: \(self.niSession?.discoveryToken != nil)")
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.niSession == nil {
                        self.niSession = NISession()
                        self.niSession?.delegate = self
                    }
                    for (pid, token) in self.peerTokens where self.connectedPeerSet.contains(pid) {
                        self.niSession?.run(NINearbyPeerConfiguration(peerToken: token))
                    }
                }
            }

        @unknown default:
            fatalError("Unhandled MCSessionState")
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard sessions[peerID] === session else { return }

        if let probe = try? JSONDecoder().decode(MessageTypeProbe.self, from: data) {
            switch probe.messageType {
            case "ripple":
                if let ripple = try? JSONDecoder().decode(RippleMessage.self, from: data) {
                    print("[MeshManager] 📡 Ripple from \(peerID.displayName)  age=\(String(format:"%.3f", Date().timeIntervalSince1970 - ripple.wallTime))s")
                    DispatchQueue.main.async { self.delegate?.meshManager(self, didReceiveRipple: ripple, fromPeer: peerID) }
                }
            case "stroke":
                if let stroke = try? JSONDecoder().decode(StrokeMessage.self, from: data) {
                    DispatchQueue.main.async { self.delegate?.meshManager(self, didReceiveStroke: stroke, fromPeer: peerID) }
                }
            default:
                break
            }
            return
        }

        // NIDiscoveryToken (binary)
        if let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) {
            peerTokens[peerID] = token
            print("[MeshManager] 🤝 Received NI token from \(peerID.displayName)")
            delegate?.meshManager(self, didUpdateState: "Received NI token from \(peerID.displayName)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let niSession = self.niSession else {
                    self.delegate?.meshManager(self, didUpdateState: "⚠️ NI session nil for \(peerID.displayName)")
                    return
                }
                niSession.run(NINearbyPeerConfiguration(peerToken: token))
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - NISessionDelegate

extension MeshManager: NISessionDelegate {

    // NISession calls delegate methods on the main thread.

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        for object in nearbyObjects {
            guard let peerID = peerTokens.first(where: { $1 == object.discoveryToken })?.key else { continue }
            connectedPeers[peerID] = object
            delegate?.meshManager(self, didReceiveNearbyObject: object, forPeer: peerID)

            guard let dist = object.distance else { continue }

            let slotLabel = peerID == randomSlotPeer ? " [random-slot 🎲 exempt]" : ""
            print("[MeshManager] 📏 \(peerID.displayName): \(String(format: "%.2f", dist))m\(slotLabel)")

            // ── Distance-based eviction ───────────────────────────────────────
            // Trigger only when:
            //   1. This is a proximity slot (not the random long-range peer).
            //   2. The peer has drifted beyond the eviction threshold.
            //   3. At least one candidate is waiting (no point evicting into a vacuum).
            //   4. No eviction for this peer is already in flight.
            guard peerID != randomSlotPeer,
                  dist > evictDistanceThreshold,
                  !candidatePeers.isEmpty,
                  !evictionInFlight.contains(peerID)
            else { continue }

            // Extra check: is the farthest peer actually THIS peer?
            // Avoids evicting a mid-range peer when someone else is farther.
            if let (farthestID, farthestDist) = farthestProximityPeer(),
               farthestID == peerID {
                print("[MeshManager] ⚡ \(peerID.displayName) is farthest at \(String(format:"%.1f",farthestDist))m — evicting")
                evict(peer: peerID)
            }
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject],
                 reason: NINearbyObject.RemovalReason) {
        for object in nearbyObjects {
            guard let peerID = peerTokens.first(where: { $1 == object.discoveryToken })?.key else { continue }
            connectedPeers.removeValue(forKey: peerID)
            delegate?.meshManager(self, didUpdateState: "NI removed \(peerID.displayName): reason \(reason.rawValue)")

            if connectedPeerSet.contains(peerID), let token = peerTokens[peerID] {
                niSession?.run(NINearbyPeerConfiguration(peerToken: token))
            }
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        delegate?.meshManager(self, didEncounterError: error)
        delegate?.meshManager(self, didUpdateState: "NI invalidated: \(error.localizedDescription)")
        niSession = NISession()
        niSession?.delegate = self
        for (peerID, token) in peerTokens where connectedPeerSet.contains(peerID) {
            niSession?.run(NINearbyPeerConfiguration(peerToken: token))
        }
    }
}
