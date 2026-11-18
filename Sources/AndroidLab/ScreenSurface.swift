import SwiftUI
import AppKit

struct ScreenSurface: NSViewRepresentable {
    let image: CGImage?
    let onTap: (Int, Int) -> Void
    let onSwipe: (Int, Int, Int, Int, Int) -> Void
    let onLongPress: (Int, Int) -> Void
    var onTouch: ((Int, Int, TouchPhase) -> Bool)? = nil
    var frameStore: ScreenFrameStore? = nil

    func makeNSView(context: Context) -> ScreenNSView {
        let view = ScreenNSView()
        if let frameStore { frameStore.attach(view) } else { view.image = image }
        view.onTap = onTap
        view.onSwipe = onSwipe
        view.onLongPress = onLongPress
        view.onTouch = onTouch
        return view
    }

    func updateNSView(_ view: ScreenNSView, context: Context) {
        if let frameStore { frameStore.attach(view) } else { view.image = image }
        view.onTap = onTap
        view.onSwipe = onSwipe
        view.onLongPress = onLongPress
        view.onTouch = onTouch
    }
}

final class ScreenNSView: NSView {
    weak var frameStore: ScreenFrameStore?
    var image: CGImage? {
        didSet {
            if image !== oldValue {
                PerformanceMetrics.record("surface")
                needsDisplay = true
                if let image {
                    currentSize = NSSize(width: image.width, height: image.height)
                }
            }
        }
    }
    var onTap: ((Int, Int) -> Void)?
    var onSwipe: ((Int, Int, Int, Int, Int) -> Void)?
    var onLongPress: ((Int, Int) -> Void)?
    var onTouch: ((Int, Int, TouchPhase) -> Bool)?
    private var directGesture = false
    private var lastTouch: (Int, Int)?
    private var focusObservers: [NSObjectProtocol] = []

    private var currentSize: NSSize = .zero
    private var startWindowPoint: NSPoint?
    private var startTime: TimeInterval = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .linear
        layer?.magnificationFilter = .linear
        let center = NotificationCenter.default
        focusObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, window === self.window else { return }
            self.releaseTouch(); self.startWindowPoint = nil
        })
        focusObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseTouch(); self?.startWindowPoint = nil
        })
    }

    deinit { for observer in focusObservers { NotificationCenter.default.removeObserver(observer) } }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Let Core Animation present the CGImage directly. No NSImage allocation
        // or CPU redraw/scaling on every frame, and no implicit frame fades.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startWindowPoint = event.locationInWindow
        startTime = event.timestamp
        if let point = devicePoint(fromWindow: event.locationInWindow) {
            lastTouch = point
            directGesture = onTouch?(point.0, point.1, .began) == true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard directGesture, let point = devicePoint(fromWindow: event.locationInWindow) else { return }
        lastTouch = point
        _ = onTouch?(point.0, point.1, .moved)
    }

    private func releaseTouch() {
        if directGesture, let point = lastTouch { _ = onTouch?(point.0, point.1, .ended) }
        directGesture = false
        lastTouch = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { releaseTouch(); startWindowPoint = nil }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        releaseTouch()
        startWindowPoint = nil
        return super.resignFirstResponder()
    }

    override func cancelOperation(_ sender: Any?) {
        releaseTouch()
        startWindowPoint = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startWindowPoint else { return }
        startWindowPoint = nil
        if directGesture {
            if let point = devicePoint(fromWindow: event.locationInWindow) { lastTouch = point }
            releaseTouch()
            return
        }
        let end = event.locationInWindow
        guard let a = devicePoint(fromWindow: start), let b = devicePoint(fromWindow: end) else {
            return
        }
        let distance = hypot(end.x - start.x, end.y - start.y)
        let duration = event.timestamp - startTime
        if distance < 6 {
            if duration > 0.65 {
                onLongPress?(a.0, a.1)
            } else {
                onTap?(a.0, a.1)
            }
        } else {
            let ms = Int(max(120, min(900, distance * 1.35)))
            onSwipe?(a.0, a.1, b.0, b.1, ms)
        }
    }

    private func devicePoint(fromWindow point: NSPoint) -> (Int, Int)? {
        guard let image else { return nil }
        let local = convert(point, from: nil)
        let rect = aspectFitRect(for: NSSize(width: image.width, height: image.height))
        guard rect.width > 0, rect.height > 0, rect.contains(local) else { return nil }
        let x = (local.x - rect.minX) / rect.width
        let y = (rect.maxY - local.y) / rect.height
        return (min(image.width - 1, max(0, Int(x * CGFloat(image.width)))),
                min(image.height - 1, max(0, Int(y * CGFloat(image.height)))))
    }

    private func aspectFitRect(for size: NSSize) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }


}
