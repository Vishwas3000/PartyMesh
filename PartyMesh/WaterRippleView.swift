import UIKit
import Metal
import MetalKit

// MARK: - GPU Data Structures (must match WaterRipple.metal exactly)

struct WaterRipplePoint {
    var center: SIMD2<Float>    // 8 bytes
    var startTime: Float        // 4 bytes
    var padding: Float = 0      // 4 bytes — keeps struct 16-byte aligned
}

struct WaterRippleUniforms {
    var time: Float             // offset  0 — 4 bytes
    var rippleCount: Int32      // offset  4 — 4 bytes
    var aspectRatio: Float      // offset  8 — 4 bytes
    var colorStrength: Float    // offset 12 — 4 bytes
    var peakColor: SIMD4<Float>   // offset 16 — 16 bytes (crest tint)
    var troughColor: SIMD4<Float> // offset 32 — 16 bytes (valley tint)
    // Total: 48 bytes — matches Metal Uniforms layout exactly
}

// MARK: - WaterRippleView

/// A full-screen MTKView overlay that renders a Metal water-distortion shader.
/// Add it on top of a `captureSource` view. Call `addRipple(at:)` on every tap.
class WaterRippleView: MTKView {

    // MARK: Public

    /// The view whose content will be captured as the background texture.
    /// Should NOT include this view as a subview to avoid feedback loops.
    weak var captureSource: UIView?

    // MARK: Private — Metal

    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var vertexBuffer: MTLBuffer!
    private var textureLoader: MTKTextureLoader!
    private var backgroundTexture: MTLTexture?

    // MARK: Private — Ripple State

    private var ripples: [WaterRipplePoint] = []
    private let startTime: CFTimeInterval = CACurrentMediaTime()
    private let maxRipples = 8
    private let rippleLifetime: Float = 3.0

    // Capture the background texture every N frames (keeps main thread cost low)
    private var frameCount = 0
    private let captureInterval = 4   // ~15 fps background updates at 60 fps render

    // MARK: - Init

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        commonInit()
    }

    private func commonInit() {
        guard let device = self.device else { return }

        backgroundColor = .clear
        isOpaque = false
        framebufferOnly = false
        isPaused = false
        preferredFramesPerSecond = 60
        isUserInteractionEnabled = false  // let touches pass to views below

        commandQueue = device.makeCommandQueue()
        textureLoader = MTKTextureLoader(device: device)

        buildPipeline()
        buildVertexBuffer()
    }

    // MARK: - Metal Setup

    private func buildPipeline() {
        guard let device = self.device else {
            print("[WaterRipple] ❌ No Metal device")
            return
        }
        guard let library = device.makeDefaultLibrary() else {
            print("[WaterRipple] ❌ makeDefaultLibrary() returned nil — did you add WaterRipple.metal to the Xcode target?")
            return
        }

        print("[WaterRipple] ✅ Default library loaded. Functions: \(library.functionNames)")

        guard let vertFn = library.makeFunction(name: "waterVertexShader") else {
            print("[WaterRipple] ❌ waterVertexShader not found in library")
            return
        }
        guard let fragFn = library.makeFunction(name: "waterFragmentShader") else {
            print("[WaterRipple] ❌ waterFragmentShader not found in library")
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = vertFn
        desc.fragmentFunction = fragFn
        desc.colorAttachments[0].pixelFormat = colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            print("[WaterRipple] ✅ Pipeline state created")
        } catch {
            print("[WaterRipple] ❌ Pipeline state creation failed: \(error)")
        }
    }

    private func buildVertexBuffer() {
        guard let device = self.device else { return }

        // Full-screen triangle strip.
        // Each vertex: (clip-x, clip-y, tex-u, tex-v)
        // Metal clip space: Y-up; UIKit texture: Y-down (origin top-left)
        let vertices: [Float] = [
            // clip-x  clip-y  tex-u  tex-v
            -1.0,  -1.0,   0.0,   1.0,   // bottom-left
             1.0,  -1.0,   1.0,   1.0,   // bottom-right
            -1.0,   1.0,   0.0,   0.0,   // top-left
             1.0,   1.0,   1.0,   0.0,   // top-right
        ]

        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    // MARK: - Public API

    /// Call this from your gesture recogniser with the touch point in this view's coordinate space.
    func addRipple(at point: CGPoint) {
        let t = Float(CACurrentMediaTime() - startTime)
        let nx = Float(point.x / bounds.width)
        let ny = Float(point.y / bounds.height)
        print("[WaterRipple] 💧 addRipple — point=\(point)  normalized=(\(String(format:"%.2f",nx)), \(String(format:"%.2f",ny)))  t=\(String(format:"%.2f",t))  bounds=\(bounds)")
        let ripple = WaterRipplePoint(center: SIMD2<Float>(nx, ny), startTime: t)
        ripples.append(ripple)
        pruneOldRipples(currentTime: t)
    }

    /// Called when a ripple event arrives from a remote peer.
    /// `normalizedPoint` is already in 0–1 space. `wallTime` is the Unix
    /// timestamp of the original tap so we can fast-forward the animation
    /// by the network transit time — the wave continues mid-ring rather than
    /// restarting from zero.
    func addRemoteRipple(normalizedPoint: CGPoint, wallTime: Double) {
        let now = Float(CACurrentMediaTime() - startTime)
        let age = max(0, Float(Date().timeIntervalSince1970 - wallTime))
        let adjustedStart = now - age   // makes the ripple appear already `age` seconds old

        print("[WaterRipple] 📡 Remote ripple — normalized=(\(String(format:"%.2f",normalizedPoint.x)), \(String(format:"%.2f",normalizedPoint.y)))  transit=\(String(format:"%.3f",age))s")

        let ripple = WaterRipplePoint(
            center: SIMD2<Float>(Float(normalizedPoint.x), Float(normalizedPoint.y)),
            startTime: adjustedStart
        )
        ripples.append(ripple)
        pruneOldRipples(currentTime: now)
    }

    // MARK: - Private Helpers

    private func pruneOldRipples(currentTime: Float) {
        ripples = ripples.filter { currentTime - $0.startTime < rippleLifetime }
        if ripples.count > maxRipples {
            ripples.removeFirst(ripples.count - maxRipples)
        }
    }

    /// Renders captureSource into a Metal texture at 1× scale for performance.
    private func captureBackground() {
        guard let source = captureSource else {
            print("[WaterRipple] ⚠️ captureBackground — captureSource is nil")
            return
        }

        guard source.bounds.width > 0, source.bounds.height > 0 else {
            print("[WaterRipple] ⚠️ captureBackground — source.bounds is zero-sized: \(source.bounds)")
            return
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0   // 1× keeps texture small (~390×844 px on iPhone)
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(bounds: source.bounds, format: format)
        let image = renderer.image { _ in
            source.drawHierarchy(in: source.bounds, afterScreenUpdates: false)
        }

        guard let cgImage = image.cgImage else {
            print("[WaterRipple] ❌ captureBackground — cgImage is nil")
            return
        }

        do {
            backgroundTexture = try textureLoader.newTexture(
                cgImage: cgImage,
                options: [
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                    .textureStorageMode: MTLStorageMode.shared.rawValue,
                    .generateMipmaps: false,
                ]
            )
            if frameCount <= captureInterval + 1 {
                print("[WaterRipple] ✅ Background texture created: \(cgImage.width)×\(cgImage.height)")
            }
        } catch {
            print("[WaterRipple] ❌ Texture upload failed: \(error)")
        }
    }

    // MARK: - MTKView Draw

    override func draw(_ rect: CGRect) {
        frameCount += 1

        if frameCount % captureInterval == 1 {
            captureBackground()
        }

        if frameCount == 1 {
            print("[WaterRipple] 🖼 First draw — bounds=\(bounds)  pipelineState=\(pipelineState != nil ? "✅" : "❌ nil")")
        }

        guard let bg = backgroundTexture else {
            if frameCount <= 10 { print("[WaterRipple] ⏳ frame \(frameCount) — waiting for backgroundTexture") }
            return
        }
        guard
            let drawable = currentDrawable,
            let passDesc = currentRenderPassDescriptor,
            let cmdBuf = commandQueue.makeCommandBuffer(),
            let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)
        else {
            print("[WaterRipple] ❌ frame \(frameCount) — drawable/passDesc/cmdBuf/encoder is nil")
            return
        }

        let now = Float(CACurrentMediaTime() - startTime)
        pruneOldRipples(currentTime: now)

        var uniforms = WaterRippleUniforms(
            time: now,
            rippleCount: Int32(ripples.count),
            aspectRatio: Float(bounds.width / bounds.height),
            colorStrength: 0.55,
            peakColor:   SIMD4<Float>(0.55, 1.00, 1.00, 1.0),  // bright cyan — crest highlight
            troughColor: SIMD4<Float>(0.00, 0.10, 0.75, 1.0)   // deep blue   — valley shadow
        )

        // Always bind at least one element so the Metal buffer isn't nil
        var ripplesData: [WaterRipplePoint] = ripples.isEmpty
            ? [WaterRipplePoint(center: .zero, startTime: -999)]
            : ripples

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<WaterRippleUniforms>.stride,
                                 index: 0)
        encoder.setFragmentTexture(bg, index: 0)
        encoder.setFragmentBytes(&ripplesData,
                                 length: ripplesData.count * MemoryLayout<WaterRipplePoint>.stride,
                                 index: 1)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
