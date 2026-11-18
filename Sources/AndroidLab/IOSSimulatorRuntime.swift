import Foundation
import SimKit

enum IOSDeviceOrientation: String {
    case portrait
    case landscapeRight
    case portraitUpsideDown
    case landscapeLeft

    var clockwiseQuarterTurns: Int {
        switch self {
        case .portrait: 0
        case .landscapeRight: 1
        case .portraitUpsideDown: 2
        case .landscapeLeft: 3
        }
    }

    var rotatedRight: IOSDeviceOrientation {
        switch self {
        case .portrait: .landscapeRight
        case .landscapeRight: .portraitUpsideDown
        case .portraitUpsideDown: .landscapeLeft
        case .landscapeLeft: .portrait
        }
    }

    /// The Duo inner IOSurface is portrait-mounted. Its two physical landscape
    /// orientations need opposite half-turns to keep the guest's top above the
    /// home indicator in the visible portrait frame.
    var duoInnerQuarterTurns: Int { (1 + clockwiseQuarterTurns) % 4 }
}

/// Pose presets matching https://safearea.info/ for iPhone Duo.
enum DuoPosePreset: String, CaseIterable, Identifiable {
    case closed
    case partiallyOpen
    case open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .closed: "Closed"
        case .partiallyOpen: "Partially Open"
        case .open: "Fully Open"
        }
    }

    var shortTitle: String {
        switch self {
        case .closed: "Closed"
        case .partiallyOpen: "135°"
        case .open: "Open"
        }
    }

    var systemImage: String {
        switch self {
        case .closed: "rectangle.portrait"
        case .partiallyOpen: "book"
        case .open: "rectangle"
        }
    }

    var angleDegrees: Double {
        switch self {
        case .closed: 0
        case .partiallyOpen: 135
        case .open: 180
        }
    }

    static func matching(angle: Double) -> DuoPosePreset? {
        if abs(angle - 0) < 1 { return .closed }
        if abs(angle - 135) < 1 { return .partiallyOpen }
        if abs(angle - 180) < 1 { return .open }
        return nil
    }
}

/// Owns one CoreSimulator device shown in a MultiSim workspace.
@MainActor
final class IOSSimulatorRuntime: ObservableObject {
    let kind: IOSSimulatorKind
    enum State: Equatable {
        case stopped
        case starting
        case booting
        case running
        case error(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Preparing"
            case .booting: return "Booting"
            case .running: return "Running"
            case .error: return "Error"
            }
        }
    }

    static let duoOuterScreenID: UInt32 = 1
    static let duoInnerScreenID: UInt32 = 3

    @Published private(set) var state: State = .stopped
    @Published private(set) var udid: String?
    @Published private(set) var orientation: IOSDeviceOrientation = .portrait
    @Published private(set) var isRotating = false
    @Published var rotationError: String?
    @Published private(set) var isChangingHinge = false
    @Published var hingeError: String?
    @Published private(set) var duoHingeAngle: Double = 180
    @Published private(set) var is3DPoseActive = false
    @Published private(set) var memoryMode: IOSMemoryMode = .unknown
    @Published private(set) var memoryFootprint: String?
    @Published private(set) var disabledServices: Int?
    @Published private(set) var managedServices: Int?
    @Published private(set) var isChangingMemory = false
    @Published var memoryError: String?

    weak var flipRenderer: DuoFlipSceneView? {
        didSet {
            flipRenderer?.onSettled = { [weak self] _ in self?.evaluate3DPoseVisibility() }
            if is3DPoseActive {
                _ = flipRenderer?.transitionTo(angleDegrees: duoHingeAngle, orientation: orientation, interactive: true)
            } else {
                flipRenderer?.syncPoseIfIdle(angleDegrees: duoHingeAngle, orientation: orientation)
            }
        }
    }
    weak var screenView: SimulatorScreenView? {
        didSet {
            pointerView?.screen = screenView
            if screenView !== oldValue, let confirmedDuoPanel {
                screenView?.preferDuoPanel(isInner: confirmedDuoPanel.display == .inner)
            }
        }
    }
    weak var pointerView: DuoPointerView? {
        didSet { pointerView?.screen = screenView }
    }

    private var startTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var hingeTask: Task<Void, Never>?
    private struct HingeRequest {
        let angle: Int
        let display: DuoActiveDisplay
        let interactive: Bool
    }

    private struct DuoPanelStatus {
        let display: DuoActiveDisplay
        let illuminated: Bool
    }

    private var pendingHingeRequest: HingeRequest?
    private var requestedDuoDisplay: DuoActiveDisplay = .inner
    private var confirmedDuoPanel: DuoPanelStatus?
    private var lastCommandedHingeAngle = 180
    private var hasSyncedInitialDuoAngle = false
    private var rotationTask: Task<Void, Never>?
    private var memoryStatusTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    private var lastBootStateCheck = Date.distantPast

    init(kind: IOSSimulatorKind) {
        self.kind = kind
    }

    func start() {
        guard startTask == nil, state != .running, !isChangingMemory else { return }
        state = .starting
        memoryMode = .unknown
        memoryFootprint = nil
        disabledServices = nil
        managedServices = nil
        hasSyncedInitialDuoAngle = false
        startTask = Task {
            defer { startTask = nil }
            do {
                let deviceID = try await Self.findOrCreateDevice(kind: kind)
                udid = deviceID
                let devices = try await Self.simctlJSON(["list", "-j", "devices"])
                let current = Self.deviceState(udid: deviceID, in: devices)
                if current != "Booted" {
                    state = .booting
                    try await Self.run(["boot", deviceID], timeout: 60)
                }
                guard !Task.isCancelled else { return }
                state = .booting
                try await Self.run(["bootstatus", deviceID, "-b"], timeout: 240)
                guard !Task.isCancelled else { return }
                if let current = await Self.readOrientation(udid: deviceID) { orientation = current }
                if kind == .iphoneDuo {
                    confirmedDuoPanel = await Self.readDuoPanel(udid: deviceID)
                    if let currentAngle = await Self.readHingeAngle(udid: deviceID) {
                        applyInitialDuoAngle(currentAngle)
                    }
                }
                state = .running
                if let confirmedDuoPanel, confirmedDuoPanel.display != requestedDuoDisplay, kind == .iphoneDuo {
                    setDuoHingeAngle(duoHingeAngle, interactive: true)
                }
                refreshMemorySnapshot()
            } catch {
                if !Task.isCancelled { state = .error(error.localizedDescription) }
            }
        }
    }

    private func applyInitialDuoAngle(_ angle: Double) {
        let clamped = max(0, min(180, angle.rounded()))
        duoHingeAngle = clamped
        lastCommandedHingeAngle = Int(clamped)
        requestedDuoDisplay = DuoActiveDisplay.resolve(
            angleDegrees: clamped, current: confirmedDuoPanel?.display ?? (clamped <= 45 ? .outer : .inner)
        )
        hasSyncedInitialDuoAngle = true
        let midPose = clamped > 0.5 && clamped < 179.5
        is3DPoseActive = midPose
        if midPose {
            _ = flipRenderer?.transitionTo(angleDegrees: clamped, orientation: orientation, interactive: true)
        } else {
            flipRenderer?.syncPoseIfIdle(angleDegrees: clamped, orientation: orientation)
        }
    }

    func stop() {
        guard let udid else { return }
        guard !isChangingMemory else {
            memoryError = "Wait for the memory operation to finish before stopping this simulator."
            return
        }
        screenView = nil
        memoryStatusTask?.cancel()
        memoryMode = .unknown
        memoryFootprint = nil
        disabledServices = nil
        managedServices = nil
        startTask?.cancel()
        startTask = nil
        restartTask?.cancel()
        restartTask = nil
        hingeTask?.cancel()
        pendingHingeRequest = nil
        confirmedDuoPanel = nil
        is3DPoseActive = false
        hasSyncedInitialDuoAngle = false
        flipRenderer?.finish()
        rotationTask?.cancel()
        rotationTask = nil
        isRotating = false
        Task {
            do {
                try await Self.run(["shutdown", udid], timeout: 45)
                state = .stopped
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func restart() {
        guard restartTask == nil, !isChangingMemory, !isRotating, !isChangingHinge else { return }
        guard let udid else { start(); return }
        screenView = nil
        memoryStatusTask?.cancel()
        memoryMode = .unknown
        memoryFootprint = nil
        disabledServices = nil
        managedServices = nil
        startTask?.cancel()
        startTask = nil
        is3DPoseActive = false
        hasSyncedInitialDuoAngle = false
        flipRenderer?.finish()
        state = .starting
        restartTask = Task {
            defer { restartTask = nil }
            do {
                try await Self.run(["shutdown", udid], timeout: 45)
                guard !Task.isCancelled else { return }
                state = .stopped
                start()
            } catch {
                if !Task.isCancelled { state = .error(error.localizedDescription) }
            }
        }
    }

    /// Syncs the initial hinge angle from the first live framebuffer when `hinge get`
    /// has not yet reported an explicit posture.
    func syncInitialDuoDisplay(isInner: Bool) {
        guard kind == .iphoneDuo, !hasSyncedInitialDuoAngle, !isChangingHinge, !is3DPoseActive else { return }
        applyInitialDuoAngle(isInner ? 180 : 0)
    }

    func setDuoPose(_ preset: DuoPosePreset) {
        setDuoHingeAngle(preset.angleDegrees, interactive: false)
    }

    func setDuoFolded(_ folded: Bool) {
        setDuoHingeAngle(folded ? 0 : 180, interactive: false)
    }

    /// Coalesces slider events and preset commands into one worker. A superseded
    /// command may already be running in simctl; wait for it before sending the
    /// latest angle so a sweep cannot overwrite a newer slider position.
    func setDuoHingeAngle(_ rawAngle: Double, interactive: Bool) {
        guard kind == .iphoneDuo, state == .running, let udid, !isRotating else { return }
        guard let script = Self.hingeScriptPath() else {
            hingeError = "The bundled Duo hinge controller is missing. Rebuild SimLab.app."
            return
        }
        let targetAngle = max(0, min(180, rawAngle.rounded()))
        hingeError = nil

        if !is3DPoseActive {
            flipRenderer?.syncPoseIfIdle(angleDegrees: duoHingeAngle, orientation: orientation)
        }
        duoHingeAngle = targetAngle
        requestedDuoDisplay = DuoActiveDisplay.resolve(angleDegrees: targetAngle, current: requestedDuoDisplay)
        hasSyncedInitialDuoAngle = true

        if flipRenderer?.transitionTo(angleDegrees: targetAngle, orientation: orientation, interactive: interactive) == true {
            is3DPoseActive = true
        }

        // CoreSimulator activates the cover below 45°, so send 44° at the UI's 45° boundary.
        let angle = targetAngle == 45 && requestedDuoDisplay == .outer ? 44 : Int(targetAngle)
        pendingHingeRequest = HingeRequest(angle: angle, display: requestedDuoDisplay, interactive: interactive)
        guard hingeTask == nil else { return }

        isChangingHinge = true
        hingeTask = Task {
            defer {
                isChangingHinge = false
                hingeTask = nil
                evaluate3DPoseVisibility()
            }
            while !Task.isCancelled, let request = pendingHingeRequest {
                pendingHingeRequest = nil
                do {
                    try await applyHingeRequest(request, script: script, udid: udid)
                } catch {
                    if !Task.isCancelled, pendingHingeRequest == nil {
                        hingeError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func applyHingeRequest(_ request: HingeRequest, script: String, udid: String) async throws {
        let from = lastCommandedHingeAngle
        if confirmedDuoPanel?.display != request.display {
            confirmedDuoPanel = nil
        }
        if !request.interactive, abs(from - request.angle) > 2 {
            let duration = String(format: "%.2f", max(0.22, min(0.50, Double(abs(from - request.angle)) / 360)))
            let result = try await Shell.run(
                script, ["-d", udid, "sweep", String(from), String(request.angle), duration], timeout: 8
            )
            guard result.ok else { throw IOSSimulatorError.message(result.combined) }
            lastCommandedHingeAngle = request.angle
        }
        guard !Task.isCancelled, pendingHingeRequest == nil else { return }

        // A recent close can leave the cover active at an intermediate angle.
        // Reach 180° and wait for the actual inner backlight before returning
        // to the requested angle. The visual hinge stays at the requested pose.
        if request.display == .inner, request.angle < 180,
           from <= 44 || confirmedDuoPanel?.illuminated != true {
            try await setHingeAngle(180, script: script, udid: udid)
            guard try await waitForDuoPanel(.inner, udid: udid) else { return }
        }
        guard !Task.isCancelled, pendingHingeRequest == nil else { return }
        try await setHingeAngle(request.angle, script: script, udid: udid, interactive: request.interactive)
        _ = try await waitForDuoPanel(request.display, udid: udid)
    }

    private func setHingeAngle(_ angle: Int, script: String, udid: String, interactive: Bool = false) async throws {
        let result = try await Shell.run(
            script, ["-d", udid, "-t", interactive ? "0" : "1.5", "set", String(angle)], timeout: 8
        )
        guard result.ok else { throw IOSSimulatorError.message(result.combined) }
        lastCommandedHingeAngle = angle
    }

    private func waitForDuoPanel(_ display: DuoActiveDisplay, udid: String) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(4)
        while !Task.isCancelled, pendingHingeRequest == nil {
            if let panel = await Self.readDuoPanel(udid: udid), !Task.isCancelled {
                confirmedDuoPanel = panel
                screenView?.preferDuoPanel(isInner: panel.display == .inner)
                if panel.display == display, panel.illuminated { return pendingHingeRequest == nil }
            }
            if ContinuousClock.now >= deadline {
                throw IOSSimulatorError.message("The simulator did not light the \(display.title.lowercased()).")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func evaluate3DPoseVisibility() {
        guard kind == .iphoneDuo else { return }
        let atEndpoint = duoHingeAngle <= 0.5 || duoHingeAngle >= 179.5
        let rendererBusy = flipRenderer?.isAnimating == true
        if flipRenderer?.canAnimate != true || (atEndpoint && !rendererBusy && !isChangingHinge && !isRotating) {
            flipRenderer?.finish()
            is3DPoseActive = false
        } else {
            if !rendererBusy {
                flipRenderer?.finish()
            }
            is3DPoseActive = true
        }
    }

    func rotateRight() {
        guard state == .running, let udid, !isRotating, !isChangingHinge else { return }
        rotationError = nil
        isRotating = true
        let previousOrientation = orientation
        let nextOrientation = orientation.rotatedRight

        if kind == .iphoneDuo {
            if !is3DPoseActive {
                flipRenderer?.syncPoseIfIdle(angleDegrees: duoHingeAngle, orientation: previousOrientation)
            }
            orientation = nextOrientation
            if flipRenderer?.transitionTo(angleDegrees: duoHingeAngle, orientation: nextOrientation, interactive: false) == true {
                is3DPoseActive = true
            }
        }

        rotationTask = Task {
            defer {
                isRotating = false
                rotationTask = nil
                evaluate3DPoseVisibility()
            }
            do {
                let result: CommandResult
                if kind == .iphoneDuo {
                    guard let script = Self.hingeScriptPath() else {
                        throw IOSSimulatorError.message("The bundled Duo orientation controller is missing. Rebuild SimLab.app.")
                    }
                    result = try await Shell.run(script, ["-d", udid, "rotate", "right"], timeout: 30)
                } else {
                    result = try await Shell.run("/usr/bin/xcrun",
                        ["devicectl", "device", "orientation", "rotate", "-d", udid, "right"],
                        timeout: 20)
                }
                guard result.ok else { throw IOSSimulatorError.message(result.combined) }
                guard let current = await Self.readOrientation(udid: udid) else {
                    throw IOSSimulatorError.message("Could not confirm the simulator's orientation.")
                }
                guard state == .running, self.udid == udid else { return }
                orientation = current
                if kind == .iphoneDuo && current != nextOrientation {
                    _ = flipRenderer?.transitionTo(angleDegrees: duoHingeAngle, orientation: current, interactive: false)
                }
            } catch {
                if kind == .iphoneDuo {
                    orientation = previousOrientation
                    _ = flipRenderer?.transitionTo(angleDegrees: duoHingeAngle, orientation: previousOrientation, interactive: false)
                }
                if !Task.isCancelled { rotationError = error.localizedDescription }
            }
        }
    }

    /// CoreSimulator devices can be shut down outside SimLab (for example from Xcode).
    /// Keep the workspace state in sync without blocking the main actor.
    func refreshBootState() async {
        guard state == .running, startTask == nil, let udid,
              Date().timeIntervalSince(lastBootStateCheck) >= 6 else { return }
        lastBootStateCheck = Date()
        guard let devices = try? await Self.simctlJSON(["list", "-j", "devices"]) else { return }
        if Self.deviceState(udid: udid, in: devices) != "Booted" {
            state = .stopped
            is3DPoseActive = false
            flipRenderer?.finish()
            memoryStatusTask?.cancel()
            memoryMode = .unknown
            memoryFootprint = nil
            disabledServices = nil
            managedServices = nil
        } else if !isRotating, let current = await Self.readOrientation(udid: udid) {
            if current != orientation {
                orientation = current
                if kind == .iphoneDuo && is3DPoseActive {
                    _ = flipRenderer?.transitionTo(angleDegrees: duoHingeAngle, orientation: current, interactive: false)
                } else if kind == .iphoneDuo {
                    flipRenderer?.syncPoseIfIdle(angleDegrees: duoHingeAngle, orientation: current)
                }
            }
        }
    }

    func refreshMemorySnapshot() {
        guard state == .running, let udid, !isChangingMemory else { return }
        memoryStatusTask?.cancel()
        memoryStatusTask = Task {
            do {
                let snapshot = try await SimSlimClient.snapshot(udid: udid)
                guard !Task.isCancelled, self.udid == udid, state == .running else { return }
                memoryMode = snapshot.mode
                memoryFootprint = snapshot.formattedFootprint
                disabledServices = snapshot.disabledServices
                managedServices = snapshot.managedServices
            } catch {
                guard !Task.isCancelled, self.udid == udid else { return }
                memoryError = error.localizedDescription
            }
        }
    }

    func setMemoryOptimized(_ optimized: Bool) {
        guard state == .running, let udid, memoryTask == nil, !isChangingHinge else { return }
        memoryStatusTask?.cancel()
        memoryError = nil
        isChangingMemory = true
        // Both profile changes restart the guest; reattach its fresh IOSurface.
        screenView = nil
        state = .booting
        memoryTask = Task {
            defer {
                isChangingMemory = false
                memoryTask = nil
            }
            do {
                if optimized {
                    try await SimSlimClient.optimize(udid: udid)
                } else {
                    try await SimSlimClient.restore(udid: udid)
                }
                state = .running
                let snapshot = try await SimSlimClient.snapshot(udid: udid)
                guard self.udid == udid else { return }
                memoryMode = snapshot.mode
                memoryFootprint = snapshot.formattedFootprint
                disabledServices = snapshot.disabledServices
                managedServices = snapshot.managedServices
            } catch {
                memoryError = error.localizedDescription
                if let devices = try? await Self.simctlJSON(["list", "-j", "devices"]),
                   Self.deviceState(udid: udid, in: devices) == "Booted" {
                    state = .running
                } else {
                    state = .stopped
                }
            }
        }
    }

    /// Launch SpringBoard after a Home event, including when leaving the app switcher.
    func goHome() async throws {
        guard let udid else { return }
        try await Self.run(["launch", udid, "com.apple.springboard"], timeout: 30)
    }

    private static func hingeScriptPath() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("HingeControl/hinge").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return nil
    }

    private static func readHingeAngle(udid: String) async -> Double? {
        guard let script = hingeScriptPath(),
              let response = try? await Shell.run(script, ["-d", udid, "get"], timeout: 8),
              response.ok else { return nil }
        return Double(response.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func readDuoPanel(udid: String) async -> DuoPanelStatus? {
        guard let response = try? await Shell.run("/usr/bin/xcrun", [
            "devicectl", "device", "info", "displays", "-d", udid, "-q", "-j", "-",
        ], timeout: 3), response.ok,
            let json = try? JSONSerialization.jsonObject(with: Data(response.stdout.utf8)) as? [String: Any],
            let result = json["result"] as? [String: Any],
            let displays = result["displays"] as? [[String: Any]],
            let active = displays.first(where: { $0["active"] as? Bool == true }),
            let id = active["displayId"] as? UInt32,
            id == duoInnerScreenID || id == duoOuterScreenID else { return nil }
        return DuoPanelStatus(display: id == duoInnerScreenID ? .inner : .outer,
                              illuminated: active["backlightState"] as? String != "off")
    }

    private static func readOrientation(udid: String) async -> IOSDeviceOrientation? {
        guard let response = try? await Shell.run("/usr/bin/xcrun", [
            "devicectl", "device", "orientation", "get", "-d", udid, "-q", "-j", "-",
        ], timeout: 12), response.ok,
            let data = response.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any],
            let value = result["deviceOrientationNonFlat"] as? String else { return nil }
        return IOSDeviceOrientation(rawValue: value)
    }

    private static func findOrCreateDevice(kind: IOSSimulatorKind) async throws -> String {
        let devices = try await simctlJSON(["list", "-j", "devices"])
        if let saved = UserDefaults.standard.string(forKey: kind.savedDeviceKey),
           deviceType(udid: saved, in: devices) == kind.deviceTypeIdentifier {
            return saved
        }
        if let found = firstNamedDevice(kind: kind, in: devices) {
            UserDefaults.standard.set(found, forKey: kind.savedDeviceKey)
            return found
        }
        let runtimes = try await simctlJSON(["list", "-j", "runtimes"])
        let available = (runtimes["runtimes"] as? [[String: Any]] ?? [])
            .filter { ($0["isAvailable"] as? Bool) == true }
            .filter { runtime in
                (runtime["supportedDeviceTypes"] as? [[String: Any]] ?? [])
                    .contains { ($0["identifier"] as? String) == kind.deviceTypeIdentifier }
            }
            .sorted {
                ($0["version"] as? String ?? "").compare($1["version"] as? String ?? "", options: .numeric) == .orderedDescending
            }
        guard let runtimeID = available.first?["identifier"] as? String else {
            throw IOSSimulatorError.message("Install an iOS Simulator runtime supporting \(kind.name) in Xcode.")
        }
        let result = try await Shell.run("/usr/bin/xcrun", [
            "simctl", "create", "SimLab \(kind.name)",
            kind.deviceTypeIdentifier, runtimeID,
        ], timeout: 90)
        guard result.ok else { throw IOSSimulatorError.message(result.combined) }
        let id = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else {
            throw IOSSimulatorError.message("CoreSimulator did not return a valid device ID.")
        }
        UserDefaults.standard.set(id, forKey: kind.savedDeviceKey)
        return id
    }

    private static func firstNamedDevice(kind: IOSSimulatorKind, in json: [String: Any]) -> String? {
        let groups = json["devices"] as? [String: [[String: Any]]] ?? [:]
        for name in ["SimLab \(kind.name)", kind.name] {
            for group in groups.values {
                if let device = group.first(where: {
                    ($0["name"] as? String) == name &&
                    ($0["deviceTypeIdentifier"] as? String) == kind.deviceTypeIdentifier
                }), let id = device["udid"] as? String {
                    return id
                }
            }
        }
        return nil
    }

    private static func deviceType(udid: String, in json: [String: Any]) -> String? {
        let groups = json["devices"] as? [String: [[String: Any]]] ?? [:]
        return groups.values.lazy.flatMap { $0 }
            .first { ($0["udid"] as? String) == udid }?["deviceTypeIdentifier"] as? String
    }

    private static func deviceState(udid: String, in json: [String: Any]) -> String? {
        let groups = json["devices"] as? [String: [[String: Any]]] ?? [:]
        for group in groups.values {
            if let device = group.first(where: { ($0["udid"] as? String) == udid }) {
                return device["state"] as? String
            }
        }
        return nil
    }

    private static func simctlJSON(_ arguments: [String]) async throws -> [String: Any] {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: 30)
        guard result.ok else { throw IOSSimulatorError.message(result.combined) }
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        guard let json = object as? [String: Any] else {
            throw IOSSimulatorError.message("Could not read CoreSimulator device list.")
        }
        return json
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) async throws {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: timeout)
        guard result.ok else { throw IOSSimulatorError.message(result.combined) }
    }
}

private enum IOSSimulatorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
