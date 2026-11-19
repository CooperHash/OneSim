import Foundation
import SimKit

struct WebInputCommand: Decodable, Sendable {
    enum Action: String, Decodable, Sendable {
        case down, move, up, cancel, back, home, apps, rotate, fold, hinge, text, refreshVideo
    }
    let panel: Int
    let action: Action
    let x: Double?
    let y: Double?
    let revision: UInt32?
    let text: String?
    let angle: Double?
    let interactive: Bool?
    let digitizer: Bool?

    var point: CGPoint? {
        guard let x, let y, (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    var isValid: Bool {
        guard (0...2).contains(panel) else { return false }
        switch action {
        case .down, .move, .up, .cancel: return point != nil && revision != nil
        case .hinge: return panel == 2 && angle.map { (0...180).contains($0) } == true
        case .text:
            guard let text, (1...80).contains(text.utf8.count) else { return false }
            return text.utf8.allSatisfy { (32...126).contains($0) }
        default: return true
        }
    }
}

struct WebPanelLayout: Equatable, Sendable {
    let width: Int
    let height: Int
    let rotation: Int
    var screenID: UInt32? = nil

    func digitizerPoint(_ upright: CGPoint) -> CGPoint {
        switch rotation {
        case 1: return CGPoint(x: upright.y, y: 1 - upright.x)
        case 2: return CGPoint(x: 1 - upright.x, y: 1 - upright.y)
        case 3: return CGPoint(x: 1 - upright.y, y: upright.x)
        default: return upright
        }
    }

    func pixelPoint(_ point: CGPoint) -> (x: Int, y: Int) {
        (min(width - 1, Int(point.x * Double(width))), min(height - 1, Int(point.y * Double(height))))
    }
}

@MainActor
final class WebMultiSimInput {
    private struct Frame {
        let layout: WebPanelLayout
        let revision: UInt32
    }

    private struct Contact {
        let client: UUID
        let start: CGPoint
        var latest: CGPoint
        let started = ContinuousClock.now
        let send: (GesturePhase, CGPoint) -> Bool
        let fallback: ((CGPoint, CGPoint, Int) -> Void)?
    }

    private weak var model: AppModel?
    private let androidID: String
    var feeds: [IOSSimulatorKind: SimulatorFrameFeed] = [:]
    private var frames: [Int: Frame] = [:]
    private var contacts: [Int: Contact] = [:]
    private var revision: UInt32 = 0
    private var active = true
    private(set) var interactionDeadline = ContinuousClock.now

    init(model: AppModel, androidID: String) {
        self.model = model
        self.androidID = androidID
    }

    func setFrame(panel: Int, layout: WebPanelLayout?) -> UInt32? {
        if let existing = frames[panel], existing.layout == layout {
            return existing.revision
        }
        endTouch(panel: panel, cancelled: true)
        guard let layout else {
            frames[panel] = nil
            return nil
        }
        revision &+= 1
        if revision == 0 { revision = 1 }
        frames[panel] = Frame(layout: layout, revision: revision)
        return revision
    }

    func stop() {
        active = false
        for panel in Array(contacts.keys) { endTouch(panel: panel, cancelled: true) }
        feeds.removeAll()
        frames.removeAll()
    }

    func receive(client: UUID, command: WebInputCommand?) {
        guard active else { return }
        guard let command else {
            for panel in contacts.keys.filter({ contacts[$0]?.client == client }) {
                endTouch(panel: panel, cancelled: true)
            }
            return
        }
        interactionDeadline = ContinuousClock.now + .seconds(2)
        switch command.action {
        case .down, .move, .up, .cancel:
            touch(client: client, command: command)
        default:
            guard contacts[command.panel] == nil else { return }
            control(command)
        }
    }

    private func touch(client: UUID, command: WebInputCommand) {
        let panel = command.panel
        guard let frame = frames[panel], frame.revision == command.revision, let point = command.point else { return }
        if command.action == .down {
            guard contacts[panel] == nil, let contact = beginTouch(client: client, panel: panel, frame: frame, point: point, digitizer: command.digitizer == true) else { return }
            contacts[panel] = contact
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, contacts[panel]?.started == contact.started else { return }
                endTouch(panel: panel, cancelled: true)
            }
            return
        }
        guard var contact = contacts[panel], contact.client == client else { return }
        contact.latest = point
        contacts[panel] = contact
        switch command.action {
        case .move: _ = contact.send(.move, point)
        case .up: endTouch(panel: panel, cancelled: false)
        case .cancel: endTouch(panel: panel, cancelled: true)
        default: break
        }
    }

    private func beginTouch(client: UUID, panel: Int, frame: Frame, point: CGPoint, digitizer: Bool) -> Contact? {
        guard let model else { return nil }
        let layout = frame.layout
        if panel == 0 {
            guard let runtime = model.runtimes[androidID],
                  runtime.state == .running, runtime.displayRotation == layout.rotation,
                  runtime.frames.image?.width == layout.width, runtime.frames.image?.height == layout.height,
                  !runtime.isFoldTransitioning, let serial = runtime.serial else { return nil }
            let send: (GesturePhase, CGPoint) -> Bool = { [weak runtime] phase, point in
                let pixel = layout.pixelPoint(point)
                let phase: TouchPhase = phase == .down ? .began : phase == .move ? .moved : .ended
                return runtime?.touch(x: pixel.x, y: pixel.y, phase: phase) ?? false
            }
            if send(.down, point) {
                return Contact(client: client, start: point, latest: point, send: send, fallback: nil)
            }
            let paths = model.settings
            return Contact(client: client, start: point, latest: point, send: { _, _ in false }) { start, end, duration in
                let a = layout.pixelPoint(start)
                let b = layout.pixelPoint(end)
                Task {
                    if abs(a.x - b.x) + abs(a.y - b.y) < 10 && duration < 350 {
                        await AndroidRepository.tap(serial: serial, x: b.x, y: b.y, paths: paths)
                    } else {
                        await AndroidRepository.swipe(serial: serial, x1: a.x, y1: a.y, x2: b.x, y2: b.y,
                                                      duration: min(1_000, max(120, duration)), paths: paths)
                    }
                }
            }
        }

        let kind = IOSSimulatorKind.allCases[panel - 1]
        guard let runtime = model.iosRuntimes[kind], runtime.state == .running, !runtime.isRotating,
              !runtime.isChangingHinge, let feed = feeds[kind], let screenID = layout.screenID else { return nil }
        let send: (GesturePhase, CGPoint) -> Bool = { [weak feed] phase, point in
            feed?.sendTouch(phase, normalized: digitizer ? point : layout.digitizerPoint(point), screenID: screenID) ?? false
        }
        guard send(.down, point) else { return nil }
        return Contact(client: client, start: point, latest: point, send: send, fallback: nil)
    }

    private func endTouch(panel: Int, cancelled: Bool) {
        guard let contact = contacts.removeValue(forKey: panel) else { return }
        _ = contact.send(.up, contact.latest)
        if !cancelled {
            let elapsed = (ContinuousClock.now - contact.started).components
            let milliseconds = Int(elapsed.seconds) * 1_000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
            contact.fallback?(contact.start, contact.latest, milliseconds)
        }
    }

    private func control(_ command: WebInputCommand) {
        guard let model else { return }
        if command.panel == 0 {
            guard let runtime = model.runtimes[androidID], runtime.state == .running else { return }
            if command.action == .rotate { model.rotate(deviceID: androidID); return }
            if command.action == .text, let text = command.text { model.typeText(deviceID: androidID, text: text); return }
            let keyCodes: [WebInputCommand.Action: Int] = [.back: 4, .home: 3, .apps: 187]
            if let key = keyCodes[command.action], !runtime.sendKey(key) { model.key(deviceID: androidID, code: key) }
        } else {
            let kind = IOSSimulatorKind.allCases[command.panel - 1]
            guard let runtime = model.iosRuntimes[kind], runtime.state == .running, let feed = feeds[kind] else { return }
            switch command.action {
            case .home:
                _ = feed.press(.home)
                Task { try? await runtime.goHome() }
            case .apps: _ = feed.press(.appSwitcher)
            case .rotate: runtime.rotateRight()
            case .fold where kind == .iphoneDuo: runtime.setDuoFolded(runtime.duoHingeAngle > 45)
            case .hinge where kind == .iphoneDuo:
                if let angle = command.angle { runtime.setDuoHingeAngle(angle, interactive: command.interactive == true) }
            case .text: if let text = command.text { feed.typeText(text) }
            default: break
            }
        }
    }
}
