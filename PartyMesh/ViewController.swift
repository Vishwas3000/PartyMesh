//
//  ViewController.swift
//  PartyMesh
//
//  Created by Vishwas Prakash on 12/03/26.
//

import UIKit
import Metal
import MultipeerConnectivity
import NearbyInteraction

class ViewController: UIViewController, MeshManagerDelegate {

    var meshManager: MeshManager!

    // MARK: - UI

    /// All regular UI lives inside containerView.
    /// WaterRippleView captures containerView so it is never in its own capture.
    private let containerView: UIView = {
        let v = UIView()
        v.backgroundColor = .systemBackground
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Initializing..."
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    let nearbyObjectsTextView: UITextView = {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.isUserInteractionEnabled = false  // prevents UIScrollView from eating taps
        textView.text = "No nearby objects yet."
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        return textView
    }()

    // MARK: - Water Ripple

    private var waterRippleView: WaterRippleView?

    // MARK: - Color Constants

    let minDistanceForColorChange: Float = 0.1
    let maxDistanceForColorChange: Float = 3.0
    let closeColor = UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
    let farColor   = UIColor(red: 0.2, green: 1.0, blue: 0.2, alpha: 1.0)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupWaterRipple()

        meshManager = MeshManager()
        meshManager.delegate = self
        meshManager.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        meshManager.stop()
    }

    deinit {
        meshManager.stop()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        // containerView fills the whole screen
        view.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        containerView.addSubview(statusLabel)
        containerView.addSubview(nearbyObjectsTextView)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            statusLabel.heightAnchor.constraint(equalToConstant: 100),

            nearbyObjectsTextView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            nearbyObjectsTextView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            nearbyObjectsTextView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            nearbyObjectsTextView.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    private func setupWaterRipple() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[WaterRipple] ❌ Metal is not available on this device")
            return
        }
        print("[WaterRipple] ✅ setupWaterRipple — view.bounds=\(view.bounds)")

        let ripple = WaterRippleView(frame: view.bounds, device: device)
        ripple.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ripple.captureSource = containerView
        view.addSubview(ripple)
        waterRippleView = ripple

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false  // don't block underlying scroll views
        view.addGestureRecognizer(tap)
        print("[WaterRipple] ✅ Tap gesture added to view")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        print("[WaterRipple] 👆 handleTap — point=\(point)  rippleView=\(waterRippleView != nil ? "✅" : "❌ nil")")
        waterRippleView?.addRipple(at: point)

        // Broadcast to all connected peers. Include wall-clock time so each
        // receiver can fast-forward the wave animation by the transit delay.
        if let rv = waterRippleView, rv.bounds.width > 0 {
            let nx = Float(point.x / rv.bounds.width)
            let ny = Float(point.y / rv.bounds.height)
            meshManager.sendRipple(normalizedX: nx, normalizedY: ny)
        }
    }

    // MARK: - Color Update Logic

    private func updateBackgroundColor(for distance: Float?) {
        guard let distance = distance else {
            containerView.backgroundColor = .systemBackground
            return
        }

        let clamped    = max(minDistanceForColorChange, min(maxDistanceForColorChange, distance))
        let normalized = CGFloat((clamped - minDistanceForColorChange) /
                                 (maxDistanceForColorChange - minDistanceForColorChange))

        let r = closeColor.rgba.red   + (farColor.rgba.red   - closeColor.rgba.red)   * normalized
        let g = closeColor.rgba.green + (farColor.rgba.green - closeColor.rgba.green) * normalized
        let b = closeColor.rgba.blue  + (farColor.rgba.blue  - closeColor.rgba.blue)  * normalized
        let a = closeColor.rgba.alpha + (farColor.rgba.alpha - closeColor.rgba.alpha) * normalized

        containerView.backgroundColor = UIColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: - MeshManagerDelegate

    func meshManager(_ manager: MeshManager, didReceiveNearbyObject object: NINearbyObject, forPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            var text = ""
            var minDistance: Float? = nil

            manager.connectedPeers.forEach { (pID, obj) in
                let distance  = obj.distance.map { String(format: "%.2f", $0) + "m" } ?? "N/A"
                let direction = obj.direction.map { v -> String in
                    "(\(String(format: "%.2f", v.x)), \(String(format: "%.2f", v.y)), \(String(format: "%.2f", v.z)))"
                } ?? "N/A"
                text += "Peer: \(pID.displayName)\n"
                text += "  Distance: \(distance)\n"
                text += "  Direction: \(direction)\n\n"

                if let d = obj.distance, minDistance == nil || d < minDistance! {
                    minDistance = d
                }
            }

            if text.isEmpty {
                self.nearbyObjectsTextView.text = "No nearby objects yet."
                self.updateBackgroundColor(for: nil)
            } else {
                self.nearbyObjectsTextView.text = text
                self.updateBackgroundColor(for: minDistance)
            }
        }
    }

    func meshManager(_ manager: MeshManager, connectedPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.statusLabel.text = "Connected to \(peerID.displayName)"
        }
    }

    func meshManager(_ manager: MeshManager, disconnectedPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.statusLabel.text = "Disconnected from \(peerID.displayName)"
            if manager.connectedPeers.isEmpty {
                self.nearbyObjectsTextView.text = "No nearby objects yet."
                self.updateBackgroundColor(for: nil)
            } else {
                var minDistance: Float? = nil
                manager.connectedPeers.forEach { (_, obj) in
                    if let d = obj.distance, minDistance == nil || d < minDistance! {
                        minDistance = d
                    }
                }
                self.updateBackgroundColor(for: minDistance)
            }
        }
    }

    func meshManager(_ manager: MeshManager, didUpdateState state: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = state
        }
    }

    func meshManager(_ manager: MeshManager, didReceiveRipple ripple: RippleMessage, fromPeer peerID: MCPeerID) {
        // Already on main thread (MeshManager dispatches to main before calling delegate)
        let normalizedPoint = CGPoint(x: CGFloat(ripple.x), y: CGFloat(ripple.y))
        waterRippleView?.addRemoteRipple(normalizedPoint: normalizedPoint, wallTime: ripple.wallTime)
    }

    func meshManager(_ manager: MeshManager, didEncounterError error: Error) {
        DispatchQueue.main.async {
            self.statusLabel.text = "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - UIColor RGBA Helper

extension UIColor {
    var rgba: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}
