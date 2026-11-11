import AppKit
import LibretillaDocx

/// Resize handles on the selected picture (backlog 12): a frame with eight handles over the text view. Dragging a
/// corner scales the picture, keeping its proportions; dragging an edge stretches it one way (a rotated picture
/// has only corners). The picture shows each new size as it's dragged, and the release makes one Format Picture
/// change, as the sheet does.
final class PictureHandles: NSView {
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
        /// -1, 0 or 1: which way the handle moves the picture's right (bottom) edge.
        var dx: CGFloat {
            switch self {
            case .topLeft, .left, .bottomLeft: -1
            case .top, .bottom: 0
            case .topRight, .right, .bottomRight: 1
            }
        }
        var dy: CGFloat {
            switch self {
            case .topLeft, .top, .topRight: -1
            case .left, .right: 0
            case .bottomLeft, .bottom, .bottomRight: 1
            }
        }
    }

    static let handleSize: CGFloat = 7

    /// The picture's frame, in the text view's coordinates.
    var pictureFrame: CGRect = .zero {
        didSet {
            frame = pictureFrame.insetBy(dx: -Self.handleSize, dy: -Self.handleSize)
            needsDisplay = true
        }
    }
    var cornersOnly = false
    /// While dragging: the size to show (nil: the picture's own).
    var onDrag: ((CGSize) -> Void)?
    var onEnd: ((CGSize?) -> Void)?

    private var dragging: (handle: Handle, start: CGPoint, size: CGSize)?

    override var isFlipped: Bool { true }

    /// The handles' squares, in this view's coordinates.
    func handleRects() -> [(Handle, CGRect)] {
        let r = bounds.insetBy(dx: Self.handleSize, dy: Self.handleSize)
        let s = Self.handleSize
        return Handle.allCases.filter { !cornersOnly || $0.isCorner }.map { handle in
            let x = handle.dx < 0 ? r.minX : handle.dx > 0 ? r.maxX : r.midX
            let y = handle.dy < 0 ? r.minY : handle.dy > 0 ? r.maxY : r.midY
            return (handle, CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: Self.handleSize, dy: Self.handleSize)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
        for (_, rect) in handleRects() {
            NSColor.white.setFill()
            rect.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    /// Only the handles take clicks; elsewhere the text view gets them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return handleRects().contains { $0.1.insetBy(dx: -2, dy: -2).contains(local) } ? self : nil
    }

    override func resetCursorRects() {
        for (handle, rect) in handleRects() {
            let cursor: NSCursor =
                handle.isCorner ? .crosshair : handle.dx != 0 ? .resizeLeftRight : .resizeUpDown
            addCursorRect(rect.insetBy(dx: -2, dy: -2), cursor: cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let handle = handleRects().first(where: { $0.1.insetBy(dx: -2, dy: -2).contains(local) })?.0 else {
            return
        }
        dragging = (handle, local, pictureFrame.size)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let local = convert(event.locationInWindow, from: nil)
        onDrag?(
            Self.size(
                dragging.size, handle: dragging.handle,
                moved: CGSize(width: local.x - dragging.start.x, height: local.y - dragging.start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragging else { return }
        self.dragging = nil
        let local = convert(event.locationInWindow, from: nil)
        let moved = CGSize(width: local.x - dragging.start.x, height: local.y - dragging.start.y)
        onEnd?(moved == .zero ? nil : Self.size(dragging.size, handle: dragging.handle, moved: moved))
    }

    /// The size a drag of `handle` by `moved` gives a picture of `size`: corners scale it (by the larger of the two
    /// movements), edges stretch it. At least 8 points each way.
    static func size(_ size: CGSize, handle: Handle, moved: CGSize) -> CGSize {
        let width = size.width + handle.dx * moved.width
        let height = size.height + handle.dy * moved.height
        if handle.isCorner, size.width > 0, size.height > 0 {
            let scale = max(width / size.width, height / size.height)
            let minimum = 8 / min(size.width, size.height)
            let s = max(scale, minimum)
            return CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
        }
        return CGSize(width: max(8, width.rounded()), height: max(8, height.rounded()))
    }
}
