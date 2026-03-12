import UIKit

/// Full-screen transparent drawing overlay.
/// Set `isDrawingEnabled = true` to capture touches; when false, all touches pass through.
class ScribbleView: UIView {

    // MARK: - Public

    var isDrawingEnabled = false {
        didSet { if !isDrawingEnabled { cancelActiveStroke() } }
    }

    var strokeColor: UIColor = .white {
        didSet { activeLayer.strokeColor = strokeColor.cgColor }
    }

    var lineWidth: CGFloat = 4 {
        didSet { activeLayer.lineWidth = lineWidth }
    }

    /// Called for every local stroke event that should be sent to peers.
    var onStrokeEvent: ((StrokeMessage) -> Void)?

    // MARK: - Rendering

    private let finishedImageView = UIImageView()
    private var finishedImage: UIImage?

    private let activeLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = UIColor.clear.cgColor
        l.lineCap = .round
        l.lineJoin = .round
        return l
    }()

    // MARK: - Local stroke state

    private var activePath: UIBezierPath?
    private var lastPoint: CGPoint?
    private var currentStrokeID = UUID().uuidString

    // MARK: - Remote stroke state

    private struct RemoteStroke {
        let layer: CAShapeLayer
        var path: UIBezierPath
        var lastPoint: CGPoint?
        let color: UIColor
        let lineWidth: CGFloat
    }
    private var remoteStrokes: [String: RemoteStroke] = [:]

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false

        finishedImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(finishedImageView)
        NSLayoutConstraint.activate([
            finishedImageView.topAnchor.constraint(equalTo: topAnchor),
            finishedImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            finishedImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            finishedImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        activeLayer.strokeColor = strokeColor.cgColor
        activeLayer.lineWidth = lineWidth
        layer.addSublayer(activeLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        activeLayer.frame = bounds
    }

    // MARK: - Touch passthrough

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return isDrawingEnabled ? super.hitTest(point, with: event) : nil
    }

    // MARK: - Local touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled, let touch = touches.first else { return }
        let pt = touch.location(in: self)
        currentStrokeID = UUID().uuidString
        lastPoint = pt
        activePath = UIBezierPath()
        activePath?.lineCapStyle = .round
        activePath?.lineJoinStyle = .round
        activePath?.move(to: pt)
        activeLayer.strokeColor = strokeColor.cgColor
        activeLayer.lineWidth = lineWidth
        updateActiveLayer()
        emit(event: "begin", at: pt)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled, let touch = touches.first, let last = lastPoint else { return }
        let pt = touch.location(in: self)
        let mid = CGPoint(x: (last.x + pt.x) / 2, y: (last.y + pt.y) / 2)
        activePath?.addQuadCurve(to: mid, controlPoint: last)
        lastPoint = pt
        updateActiveLayer()
        emit(event: "move", at: pt)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled else { return }
        if let pt = touches.first?.location(in: self) { emit(event: "end", at: pt) }
        bakeActiveStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        bakeActiveStroke()
    }

    // MARK: - Private helpers

    private func updateActiveLayer() {
        activeLayer.path = activePath?.cgPath
    }

    private func cancelActiveStroke() {
        activePath = nil
        lastPoint = nil
        activeLayer.path = nil
    }

    private func bakeActiveStroke() {
        guard let path = activePath else { return }
        bake(path: path, color: strokeColor, width: lineWidth)
        cancelActiveStroke()
    }

    private func bake(path: UIBezierPath, color: UIColor, width: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { ctx in
            finishedImage?.draw(at: .zero)
            ctx.cgContext.setStrokeColor(color.cgColor)
            ctx.cgContext.setLineWidth(width)
            ctx.cgContext.setLineCap(.round)
            ctx.cgContext.setLineJoin(.round)
            ctx.cgContext.addPath(path.cgPath)
            ctx.cgContext.strokePath()
        }
        finishedImage = image
        finishedImageView.image = image
    }

    private func emit(event: String, at pt: CGPoint) {
        let rgba = strokeColor.rgba
        onStrokeEvent?(StrokeMessage(
            messageType: "stroke",
            event: event,
            strokeID: currentStrokeID,
            x: Float(pt.x / max(1, bounds.width)),
            y: Float(pt.y / max(1, bounds.height)),
            r: Float(rgba.red), g: Float(rgba.green), b: Float(rgba.blue),
            lineWidth: Float(lineWidth)
        ))
    }

    // MARK: - Remote strokes

    func applyRemoteStroke(_ msg: StrokeMessage) {
        let pt = CGPoint(x: CGFloat(msg.x) * bounds.width,
                         y: CGFloat(msg.y) * bounds.height)
        let color = UIColor(red: CGFloat(msg.r), green: CGFloat(msg.g),
                            blue: CGFloat(msg.b), alpha: 1)
        let width = CGFloat(msg.lineWidth)

        switch msg.event {
        case "begin":
            let sl = CAShapeLayer()
            sl.fillColor = UIColor.clear.cgColor
            sl.strokeColor = color.cgColor
            sl.lineWidth = width
            sl.lineCap = .round
            sl.lineJoin = .round
            layer.addSublayer(sl)
            let path = UIBezierPath()
            path.move(to: pt)
            remoteStrokes[msg.strokeID] = RemoteStroke(layer: sl, path: path,
                                                       lastPoint: pt,
                                                       color: color, lineWidth: width)
        case "move":
            guard var rs = remoteStrokes[msg.strokeID] else { return }
            let last = rs.lastPoint ?? pt
            let mid = CGPoint(x: (last.x + pt.x) / 2, y: (last.y + pt.y) / 2)
            rs.path.addQuadCurve(to: mid, controlPoint: last)
            rs.lastPoint = pt
            rs.layer.path = rs.path.cgPath
            remoteStrokes[msg.strokeID] = rs

        case "end":
            guard let rs = remoteStrokes[msg.strokeID] else { return }
            bake(path: rs.path, color: rs.color, width: rs.lineWidth)
            rs.layer.removeFromSuperlayer()
            remoteStrokes.removeValue(forKey: msg.strokeID)

        case "clear":
            clearAll()

        default: break
        }
    }

    // MARK: - Clear

    /// Clears locally and broadcasts a clear event to peers.
    func clear() {
        clearAll()
        let rgba = strokeColor.rgba
        onStrokeEvent?(StrokeMessage(
            messageType: "stroke", event: "clear", strokeID: "",
            x: 0, y: 0,
            r: Float(rgba.red), g: Float(rgba.green), b: Float(rgba.blue),
            lineWidth: Float(lineWidth)
        ))
    }

    private func clearAll() {
        finishedImage = nil
        finishedImageView.image = nil
        cancelActiveStroke()
        remoteStrokes.values.forEach { $0.layer.removeFromSuperlayer() }
        remoteStrokes.removeAll()
    }
}
