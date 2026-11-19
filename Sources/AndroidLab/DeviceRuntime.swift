import Foundation
import CoreGraphics
import Combine

@MainActor
final class ScreenFrameStore: ObservableObject {
    private(set) var image: CGImage?
    private(set) var frameNumber: UInt64 = 0
    @Published private(set) var pixelSize: CGSize?
    private weak var surface: ScreenNSView?

    func present(_ image: CGImage?) {
        self.image = image
        frameNumber &+= 1
        if let surface, !surface.previewPaused { surface.image = image }
        let size = image.map { CGSize(width: $0.width, height: $0.height) }
        if pixelSize != size { pixelSize = size }
    }

    func attach(_ view: ScreenNSView) {
        if view.frameStore !== self { view.frameStore?.detach(view) }
        surface = view
        view.frameStore = self
        if !view.previewPaused { view.image = image }
    }

    func detach(_ view: ScreenNSView) {
        if surface === view { surface = nil }
        if view.frameStore === self { view.frameStore = nil }
    }
}

@MainActor
final class DeviceRuntime: ObservableObject {
    let avdName: String
    let frames = ScreenFrameStore()

    @Published private(set) var state: DeviceState = .stopped
    private(set) var frame: CGImage? {
        get { frames.image }
        set { frames.present(newValue) }
    }
    @Published private(set) var serial: String?
    @Published private(set) var bootLog: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isScreenConnected = false
    @Published var rotationQuarter = 0
    @Published private(set) var isFolded = false
    @Published private(set) var isFoldTransitioning = false
    @Published private(set) var isFoldStateKnown = false
    @Published var foldError: String?
    @Published var displayRotation = 0
    @Published private(set) var slimMode: AndroidSlimMode = .balanced
    @Published private(set) var slimmedPackages = 0
    @Published private(set) var isChangingSlim = false
    @Published var slimError: String?

    private var process: RunningEmulator?
    private var client: EmulatorClient?
    private var inputClient: EmulatorInputClient?
    private var touchCoordinates: FrameCoordinates?
    private var activeTouch: (Int, Int)?
    private var frameCoordinates: FrameCoordinates?
    private var streamGeneration = 0
    private var streamStartupTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var isStopping = false
    private var lastBootCheck = Date.distantPast
    private var foldTask: Task<Void, Never>?
    private var foldGeneration = 0
    private var slimTask: Task<Void, Never>?
    private var slimAppliedPID: Int?

    init(avdName: String) {
        self.avdName = avdName
    }

    var grpcPort: Int?
    var grpcToken: String?

    func setState(_ state: DeviceState, error: String? = nil) {
        self.state = state
        if let error { self.errorMessage = error }
        if state != .error { self.errorMessage = state == .stopped ? nil : errorMessage }
    }

    func appendLog(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        bootLog += "[\(stamp)] \(line)\n"
        if bootLog.count > 12_000 {
            bootLog = String(bootLog.suffix(12_000))
        }
    }

    func attach(endpoint: EmulatorEndpoint, booted: Bool, paths: ToolPaths) {
        let portChanged = grpcPort != endpoint.grpcPort || serial != endpoint.serial
        if portChanged { invalidateFoldSession() }
        slimMode = AndroidSlimClient.mode(avdName: avdName, paths: paths)
        serial = endpoint.serial
        grpcPort = endpoint.grpcPort
        grpcToken = endpoint.token
        if state == .stopped || state == .error {
            state = booted ? .running : .booting
        }
        if booted && state == .booting {
            state = .running
        }
        if client == nil || portChanged {
            startStreaming()
        }
        if booted, process == nil, slimAppliedPID != endpoint.pid, slimTask == nil {
            applySlimToAttachedDevice(endpoint: endpoint, paths: paths)
        }
    }

    private func applySlimToAttachedDevice(endpoint: EmulatorEndpoint, paths: ToolPaths) {
        isChangingSlim = true
        slimTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isChangingSlim = false
                self.slimTask = nil
            }
            do {
                self.slimmedPackages = try await AndroidSlimClient.reconcile(
                    serial: endpoint.serial, avdName: self.avdName, paths: paths)
                self.slimAppliedPID = endpoint.pid
                self.appendLog("Balanced Android profile: \(self.slimmedPackages) optional packages disabled.")
            } catch {
                self.slimError = error.localizedDescription
                self.appendLog("Android profile: \(error.localizedDescription)")
            }
        }
    }

    func setSlimMode(_ mode: AndroidSlimMode, device: AvdDevice, paths: ToolPaths) {
        guard state == .running, let serial, slimTask == nil else { return }
        slimError = nil
        isChangingSlim = true
        slimTask = Task { [weak self] in
            guard let self else { return }
            do {
                try AndroidSlimClient.setMode(mode, avdName: self.avdName, paths: paths)
                self.slimMode = mode
                self.slimmedPackages = try await AndroidSlimClient.reconcile(
                    serial: serial, avdName: self.avdName, paths: paths)
                self.slimAppliedPID = nil
                self.isChangingSlim = false
                self.slimTask = nil
                self.coldBoot(device: device, paths: paths)
            } catch {
                self.slimError = error.localizedDescription
                self.isChangingSlim = false
                self.slimTask = nil
            }
        }
    }

    func start(device: AvdDevice, paths: ToolPaths, coldBoot: Bool, wipeData: Bool) {
        guard !state.isBusy else { return }
        slimMode = AndroidSlimClient.mode(avdName: avdName, paths: paths)
        slimAppliedPID = nil
        invalidateFoldSession()
        startTask?.cancel()
        isStopping = false
        errorMessage = nil
        bootLog = ""
        state = .starting
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.appendLog("Starting emulator…")
                let running = try await AndroidRepository.start(
                    device: device,
                    coldBoot: coldBoot,
                    wipeData: wipeData,
                    paths: paths
                )
                self.process = running
                self.appendLog("Emulator process started. Waiting for gRPC endpoint…")
                running.process.terminationHandler = { [weak self] proc in
                    DispatchQueue.main.async {
                        guard let self, self.process === running else { return }
                        if !self.isStopping {
                            self.appendLog("Emulator exited with status \(proc.terminationStatus).")
                            self.stopStreaming()
                            self.process = nil
                            self.serial = nil
                            self.grpcPort = nil
                            self.grpcToken = nil
                            self.frame = nil
                            self.state = .stopped
                        }
                    }
                }

                let endpoint = try await AndroidRepository.waitForEndpoint(
                    avdName: self.avdName,
                    consolePort: running.consolePort,
                    isAlive: { running.process.isRunning }
                )
                guard !Task.isCancelled, !self.isStopping else { return }
                self.serial = endpoint.serial
                self.grpcPort = endpoint.grpcPort
                self.grpcToken = endpoint.token
                self.state = .booting
                self.appendLog("Control endpoint ready on \(endpoint.serial).")
                self.startStreaming()

                try await AndroidRepository.waitForBoot(serial: endpoint.serial, paths: paths)
                guard !Task.isCancelled, !self.isStopping else { return }
                do {
                    self.slimmedPackages = try await AndroidSlimClient.reconcile(
                        serial: endpoint.serial, avdName: self.avdName, paths: paths)
                    self.slimAppliedPID = Int(running.process.processIdentifier)
                    self.appendLog("Android profile: \(self.slimmedPackages) optional packages disabled.")
                    try await AndroidSlimClient.prepareDefaultSnapshot(
                        device: device, serial: endpoint.serial, paths: paths, wipe: wipeData
                    )
                } catch {
                    self.slimError = error.localizedDescription
                    self.appendLog("Android profile: \(error.localizedDescription)")
                }
                self.appendLog("Android boot completed.")
                self.state = .running
            } catch {
                guard !self.isStopping else { return }
                self.appendLog("Error: \(error.localizedDescription)")
                self.errorMessage = error.localizedDescription
                self.state = .error
                self.stopStreaming()
                if let process = self.process {
                    process.process.terminate()
                    self.process = nil
                }
            }
        }
    }

    func stop(paths: ToolPaths) {
        guard state != .stopped && state != .stopping else { return }
        slimAppliedPID = nil
        isStopping = true
        state = .stopping
        startTask?.cancel()
        startTask = nil
        stopStreaming()
        let serial = self.serial
        let avdName = self.avdName
        Task { [weak self] in
            await AndroidRepository.stop(serial: serial, avdName: avdName, paths: paths)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                guard let self else { return }
                if let process = self.process, process.process.isRunning {
                    process.process.terminate()
                }
                self.process = nil
                self.serial = nil
                self.grpcPort = nil
                self.grpcToken = nil
                self.frame = nil
                self.isScreenConnected = false
                self.state = .stopped
                self.isStopping = false
            }
        }
    }

    func wipe(device: AvdDevice, paths: ToolPaths) {
        stop(paths: paths)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !self.isStopping else { return }
            self.start(device: device, paths: paths, coldBoot: true, wipeData: true)
        }
    }

    func coldBoot(device: AvdDevice, paths: ToolPaths) {
        stop(paths: paths)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !self.isStopping else { return }
            self.start(device: device, paths: paths, coldBoot: true, wipeData: false)
        }
    }

    func setRotation(quarter: Int) {
        releaseActiveTouch()
        rotationQuarter = quarter
        displayRotation = quarter % 4
        client?.setDisplayRotation(displayRotation)
        client?.setPhysicalModel(target: 1, values: [Float(quarter * 90)])
    }

    func toggleFold(paths: ToolPaths) {
        guard let serial, state == .running, !isFoldTransitioning else { return }
        releaseActiveTouch()
        foldGeneration += 1
        let generation = foldGeneration
        isFoldTransitioning = true
        foldError = nil
        foldTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.foldGeneration == generation {
                    self.isFoldTransitioning = false
                    self.foldTask = nil
                }
            }
            do {
                // Never choose the target from a cached/optimistic toolbar label.
                let actual = try await AndroidRepository.foldState(serial: serial, paths: paths)
                guard self.isCurrentFoldSession(serial, generation) else { return }
                self.applyFoldState(actual)
                let target = !actual.isFolded
                self.appendLog(target ? "Folding emulator…" : "Unfolding emulator…")
                let confirmed = try await AndroidRepository.setFoldState(serial: serial, folded: target, paths: paths)
                guard self.isCurrentFoldSession(serial, generation) else { return }
                self.applyFoldState(confirmed)
                // The repository awaits physical-panel console acknowledgement
                // and verifies the guest posture before publishing success.
                if let rotation = await AndroidRepository.displayRotation(serial: serial, paths: paths) {
                    guard self.isCurrentFoldSession(serial, generation) else { return }
                    self.displayRotation = rotation
                    self.rotationQuarter = rotation
                    self.client?.setDisplayRotation(rotation, redrawLatest: true)
                }
                guard self.isCurrentFoldSession(serial, generation) else { return }
                self.appendLog(confirmed.isFolded ? "Fold confirmed by Android." : "Unfold confirmed by Android.")
            } catch {
                guard self.isCurrentFoldSession(serial, generation) else { return }
                let message = error.localizedDescription
                // A timed-out command may still have completed. Resynchronize,
                // but never report success just because the request was sent.
                if let actual = try? await AndroidRepository.foldState(serial: serial, paths: paths) {
                    guard self.isCurrentFoldSession(serial, generation) else { return }
                    self.applyFoldState(actual)
                }
                guard self.isCurrentFoldSession(serial, generation) else { return }
                self.foldError = message
                self.appendLog("Fold change failed: \(message)")
            }
        }
    }

    private func isCurrentFoldSession(_ serial: String, _ generation: Int) -> Bool {
        !Task.isCancelled && self.serial == serial && foldGeneration == generation && state == .running
    }

    private func applyFoldState(_ snapshot: FoldStateSnapshot) {
        if isFolded != snapshot.isFolded { releaseActiveTouch() }
        isFolded = snapshot.isFolded
        isFoldStateKnown = true
    }

    func closeStreamForShutdown() {
        stopStreaming()
    }

    func markStopped() {
        guard !state.isBusy else { return }
        slimAppliedPID = nil
        stopStreaming()
        frame = nil
        serial = nil
        grpcPort = nil
        grpcToken = nil
        isScreenConnected = false
        state = .stopped
    }

    func refreshBootState(paths: ToolPaths, isFoldable: Bool = false) {
        guard let serial, state == .booting || state == .running else { return }
        guard Date().timeIntervalSince(lastBootCheck) > 6 else { return }
        lastBootCheck = Date()
        let generation = foldGeneration
        let shouldReadFold = isFoldable && !isFoldTransitioning
        Task { [weak self] in
            let booted = await AndroidRepository.isBooted(serial: serial, paths: paths)
            let rotation = await AndroidRepository.displayRotation(serial: serial, paths: paths)
            let foldState: FoldStateSnapshot?
            if shouldReadFold { foldState = try? await AndroidRepository.foldState(serial: serial, paths: paths) }
            else { foldState = nil }
            guard let self, self.serial == serial, self.foldGeneration == generation,
                  self.state == .booting || self.state == .running, !Task.isCancelled else { return }
            if booted, self.state == .booting { self.state = .running }
            if let rotation, !self.isFoldTransitioning {
                self.displayRotation = rotation
                self.rotationQuarter = rotation
                self.client?.setDisplayRotation(rotation, redrawLatest: true)
            }
            if let foldState, !self.isFoldTransitioning { self.applyFoldState(foldState) }
        }
    }

    func touch(x: Int, y: Int, phase: TouchPhase) -> Bool {
        // Some emulator versions normalize folded secondary-screen touches using
        // the primary panel dimensions, even with an explicit display ID. Use
        // Android's logical-coordinate input path until that backend is reliable.
        if isFolded {
            if phase == .began { releaseActiveTouch() }
            return false
        }
        guard let inputClient else { return false }
        if phase != .began && activeTouch == nil { return false }
        if phase == .began { releaseActiveTouch() }
        let pressure: Int32 = phase == .ended ? 0 : 1
        let coordinates = touchCoordinates ?? frameCoordinates
        guard let coordinates else { return false }
        let point = coordinates.panelPoint(x: x, y: y)
        let accepted = inputClient.sendTouch(x: point.0, y: point.1, pressure: pressure)
        if PerformanceMetrics.enabled, phase != .moved {
            DebugLog.write("PERF directTouch phase=\(phase) accepted=\(accepted)")
        }
        if pressure > 0, accepted {
            touchCoordinates = coordinates
            activeTouch = point
        } else if pressure == 0 {
            touchCoordinates = nil
            activeTouch = nil
        }
        return accepted
    }

    private func releaseActiveTouch() {
        if let point = activeTouch { _ = inputClient?.sendTouch(x: point.0, y: point.1, pressure: 0) }
        activeTouch = nil
        touchCoordinates = nil
    }

    func sendKey(_ code: Int) -> Bool {
        inputClient?.sendAndroidKey(code) ?? false
    }

    // MARK: - Streaming

    private func startStreaming() {
        guard let port = grpcPort else { return }
        stopClient()
        streamGeneration += 1
        let generation = streamGeneration
        let token = grpcToken ?? ""
        let client = EmulatorClient()
        self.client = client
        let input = EmulatorInputClient()
        self.inputClient = input
        input.onState = { state in
            if case .disconnected(let reason) = state {
                DebugLog.write("Input stream unavailable: \(reason)")
            }
        }
        client.setDisplayRotation(displayRotation)
        client.onFrame = { [weak self] image, coordinates in
            guard let self else { return }
            self.frameCoordinates = coordinates
            self.frame = image
            if !self.isScreenConnected { self.isScreenConnected = true }
        }
        client.onState = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.streamGeneration == generation else { return }
                switch state {
                case .connecting:
                    self.isScreenConnected = false
                case .connected:
                    self.isScreenConnected = true
                case .disconnected:
                    self.isScreenConnected = false
                    if self.state == .running || self.state == .booting {
                        self.scheduleReconnect()
                    }
                }
            }
        }
        streamStartupTask = Task { [weak self] in
            guard let self, self.streamGeneration == generation, !Task.isCancelled else { return }
            do {
                try await client.start(port: port, token: token)
                guard self.streamGeneration == generation, !Task.isCancelled else { return }
                do { try await input.start(port: port, token: token) }
                catch { DebugLog.write("Input connection failed: \(error.localizedDescription)") }
            } catch {
                DebugLog.write("client start failed \(self.avdName): \(error)")
                await MainActor.run {
                    guard self.streamGeneration == generation, !Task.isCancelled else { return }
                    self.isScreenConnected = false
                    if self.state == .running || self.state == .booting {
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                guard let self else { return }
                self.reconnectTask = nil
                guard self.state == .running || self.state == .booting else { return }
                self.startStreaming()
            }
        }
    }

    private func stopStreaming() {
        invalidateFoldSession()
        stopClient()
        reconnectTask?.cancel()
        reconnectTask = nil
        streamGeneration += 1
        isScreenConnected = false
    }

    private func invalidateFoldSession() {
        foldGeneration += 1
        foldTask?.cancel()
        foldTask = nil
        isFoldTransitioning = false
        isFoldStateKnown = false
        foldError = nil
        lastBootCheck = .distantPast
    }

    private func stopClient() {
        streamStartupTask?.cancel()
        streamStartupTask = nil
        releaseActiveTouch()
        inputClient?.stop()
        inputClient = nil
        frameCoordinates = nil
        client?.onFrame = nil
        client?.onState = nil
        client?.stop()
        client = nil
    }

}
