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

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession!

    var niSession: NISession?
    var peerTokens: [MCPeerID: NIDiscoveryToken] = [:] // Map peerID to their discovery token
    var connectedPeers: [MCPeerID: NINearbyObject] = [:] // Map peerID to their last known nearby object

    override init() {
        super.init()
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    func start() {
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        niSession = NISession()
        niSession?.delegate = self
        delegate?.meshManager(self, didUpdateState: "Advertising and browsing started. NearbyInteraction session initialized.")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        niSession?.invalidate()
        niSession = nil // Clear the session
        delegate?.meshManager(self, didUpdateState: "Stopped.")
    }

    // MARK: - MCNearbyServiceAdvertiserDelegate

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        delegate?.meshManager(self, didUpdateState: "Received invitation from \(peerID.displayName)")
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        delegate?.meshManager(self, didEncounterError: error)
    }

    // MARK: - MCNearbyServiceBrowserDelegate

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        delegate?.meshManager(self, didUpdateState: "Found peer: \(peerID.displayName). Inviting...")
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        delegate?.meshManager(self, didUpdateState: "Lost peer: \(peerID.displayName)")
        delegate?.meshManager(self, disconnectedPeer: peerID)
        
        peerTokens.removeValue(forKey: peerID)
        connectedPeers.removeValue(forKey: peerID)
        
        // Check if there are still connected peers to maintain NI sessions for
        if !session.connectedPeers.isEmpty {
            // Re-run configurations for remaining connected peers if NISession was invalidated
            if niSession == nil {
                niSession = NISession()
                niSession?.delegate = self
            }
            for (connectedPeerID, token) in peerTokens where session.connectedPeers.contains(connectedPeerID) {
                let config = NINearbyPeerConfiguration(peerToken: token)
                niSession?.run(config)
            }
        } else {
            // If no more connected peers, invalidate and nil out NISession
            niSession?.invalidate()
            niSession = nil
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        delegate?.meshManager(self, didEncounterError: error)
    }

    // MARK: - MCSessionDelegate

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            delegate?.meshManager(self, connectedPeer: peerID)
            delegate?.meshManager(self, didUpdateState: "Connected to \(peerID.displayName)")
            sendMyToken(to: peerID)
        case .connecting:
            delegate?.meshManager(self, didUpdateState: "Connecting to \(peerID.displayName)")
        case .notConnected:
            delegate?.meshManager(self, disconnectedPeer: peerID)
            delegate?.meshManager(self, didUpdateState: "Disconnected from \(peerID.displayName)")
            
            peerTokens.removeValue(forKey: peerID)
            connectedPeers.removeValue(forKey: peerID)
            
            // Check if there are still connected peers to maintain NI sessions for
            if !session.connectedPeers.isEmpty {
                // If NISession was previously invalidated, reinitialize and run configs for active peers
                if niSession == nil {
                    niSession = NISession()
                    niSession?.delegate = self
                }
                for (connectedPeerID, token) in peerTokens where session.connectedPeers.contains(connectedPeerID) {
                    let config = NINearbyPeerConfiguration(peerToken: token)
                    niSession?.run(config)
                }
            } else {
                // If no more connected peers, invalidate and nil out NISession
                niSession?.invalidate()
                niSession = nil
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
                delegate?.meshManager(self, didUpdateState: "Received token from \(peerID.displayName). Starting Nearby Interaction.")

                guard let niSession = self.niSession else {
                    delegate?.meshManager(self, didUpdateState: "NISession is nil, cannot run configuration for \(peerID.displayName)")
                    return
                }
                let config = NINearbyPeerConfiguration(peerToken: token)
                niSession.run(config)
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

    private func sendMyToken(to peerID: MCPeerID) {
        guard let myDiscoveryToken = niSession?.discoveryToken else {
            delegate?.meshManager(self, didUpdateState: "NISession discovery token not available yet.")
            return
        }

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: myDiscoveryToken, requiringSecureCoding: true)
            try session.send(data, toPeers: [peerID], with: .reliable)
            delegate?.meshManager(self, didUpdateState: "Sent token to \(peerID.displayName)")
        } catch {
            delegate?.meshManager(self, didEncounterError: error)
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
