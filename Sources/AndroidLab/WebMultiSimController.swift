import AppKit
import IOSurface
import SimKit
import SwiftUI

@MainActor
final class WebMultiSimController: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting(Double, String)
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var lanURL: URL?
    @Published private(set) var isStartingLAN = false
    @Published private(set) var publicURL: URL?
    @Published private(set) var isStartingPublic = false
    @Published var sharingError: String?
    private var publicServer: WebMultiSimServer?
    private var publicTunnel: CloudflareQuickTunnel?
    private var publicTask: Task<Void, Never>?
    @Published var lanPowerSaving = false
    private var lanServer: WebMultiSimServer?
    private var lanTask: Task<Void, Never>?
    private var input: WebMultiSimInput?
    private var task: Task<Void, Never>?
    private var server: WebMultiSimServer?
    private var feeds: [IOSSimulatorKind: SimulatorFrameFeed] = [:]

    func start(model: AppModel, workspace: MultiSimWorkspace) {
        guard task == nil else { return }
        state = .starting(0.05, "Starting Android and preparing Quick Boot…")
        let androidID = workspace.androidID
        let input = WebMultiSimInput(model: model, androidID: androidID)
        self.input = input
        task = Task { [weak self, weak model] in
            guard let self, let model else { return }
            do {
                guard let android = model.devices.first(where: { $0.id == androidID }),
                      let androidRuntime = model.runtimes[android.id] else {
                    throw SetupError("The primary Android device is missing.")
                }
                if !androidRuntime.state.isBusy && androidRuntime.state != .running {
                    model.startDevice(android)
                }
                try await untilReady {
                    if androidRuntime.state == .error {
                        throw SetupError(androidRuntime.errorMessage ?? "The Android emulator failed to boot.")
                    }
                    return androidRuntime.state == .running && androidRuntime.frames.image != nil
                }
                state = .starting(0.75, "Checking iPhone simulator availability…")
                let compatible = Set(await IOSSimulatorRuntime.compatibleRuntimeIDs().keys)
                try Task.checkCancellation()
                let iosStartup = Task {
                    // Start compatible devices sequentially to limit boot load.
                    for kind in IOSSimulatorKind.allCases where compatible.contains(kind) {
                        guard !Task.isCancelled, let runtime = model.iosRuntimes[kind] else { return }
                        runtime.start()
                        try? await self.untilReady {
                            if case .error = runtime.state { return true }
                            return runtime.state == .running
                        }
                    }
                }
                defer { iosStartup.cancel() }

                let server = makeServer(input: input)
                self.server = server
                state = .starting(0.95, "Starting the local WebSocket listener…")
                try await server.start()
                try Task.checkCancellation()
                state = .running

                let stream = WebFrameStream()
                let clock = ContinuousClock()
                while !Task.isCancelled {
                    let now = clock.now
                    let servers = [server, lanServer, publicServer].compactMap { $0 }
                    let hasViewers = servers.contains { $0.hasViewers }
                    var spinning = false
                    if hasViewers {
                        refreshFeeds(model.iosRuntimes)
                        input.feeds = feeds
                        spinning = input.interactionDeadline > now
                            || model.iosRuntimes.values.contains { $0.isChangingHinge || $0.isRotating }
                        prepareFrames(android: androidRuntime, androidDensity: android.density, ios: model.iosRuntimes,
                                      compatibleIOS: compatible, input: input,
                                      stream: stream, servers: servers)
                    } else {
                        stream.setServers(servers)
                    }
                    try await clock.sleep(until: now + .milliseconds(hasViewers ? (spinning ? 16 : 33) : 250))
                }
            } catch {
                guard !Task.isCancelled else { return }
                stop()
                state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        stopLAN()
        input?.stop()
        input = nil
        task?.cancel()
        task = nil
        server?.stop()
        server = nil
        feeds.removeAll()
        state = .stopped
    }

    func startLAN(address: String) {
        guard state == .running, let input, lanServer == nil, WebLANAddresses.available().contains(address) else { return }
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let candidate = makeServer(input: input, address: address, key: key)
        lanServer = candidate
        isStartingLAN = true
        lanTask = Task {
            do {
                try await candidate.start()
                guard !Task.isCancelled, lanServer === candidate else { return }
                lanURL = candidate.shareURL
                isStartingLAN = false
            } catch {
                guard !Task.isCancelled, lanServer === candidate else { return }
                stopLAN()
                sharingError = error.localizedDescription
            }
        }
    }

    func stopLAN() {
        stopPublic()
        lanTask?.cancel()
        lanTask = nil
        lanServer?.stop()
        lanServer = nil
        lanURL = nil
        lanPowerSaving = false
        isStartingLAN = false
    }

    func startPublic() {
        guard state == .running, lanURL != nil, let input, publicTunnel == nil else { return }
        let tunnel = CloudflareQuickTunnel()
        publicTunnel = tunnel
        isStartingPublic = true
        sharingError = nil
        let onInput: @Sendable (UUID, WebInputCommand?) -> Void = { [weak self, weak input, weak tunnel] client, command in
            DispatchQueue.main.async {
                guard command == nil || (tunnel != nil && self?.publicTunnel === tunnel) else { return }
                input?.receive(client: client, command: command)
            }
        }
        publicTask = Task {
            do {
                try Task.checkCancellation()
                let key = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                let candidate = WebMultiSimServer(tunnelKey: key, onInput: onInput)
                self.publicServer = candidate
                let port = try await candidate.start()
                try Task.checkCancellation()
                try await tunnel.run(port: port) { origin in
                    try Task.checkCancellation()
                    candidate.acceptPublicOrigin(origin)
                    self.publicURL = candidate.shareURL
                    self.isStartingPublic = false
                }
            } catch {
                guard !Task.isCancelled, publicTunnel === tunnel else { return }
                stopPublic()
                sharingError = error.localizedDescription
            }
        }
    }

    func stopPublic() {
        guard publicTunnel != nil else { return }
        publicTask?.cancel()
        publicTask = nil
        publicServer?.stop()
        publicServer = nil
        publicTunnel?.stop()
        publicTunnel = nil
        publicURL = nil
        isStartingPublic = false
    }

    private func makeServer(input: WebMultiSimInput, address: String = "127.0.0.1", key: String? = nil) -> WebMultiSimServer {
        WebMultiSimServer(bindAddress: address, accessKey: key) { [weak input] client, command in
            DispatchQueue.main.async {
                input?.receive(client: client, command: command)
            }
        }
    }

    private func prepareFrames(android: DeviceRuntime, androidDensity: Int, ios: [IOSSimulatorKind: IOSSimulatorRuntime],
                               compatibleIOS: Set<IOSSimulatorKind>,
                               input: WebMultiSimInput, stream: WebFrameStream, servers: [WebMultiSimServer]) {
        stream.setServers(servers)
        if let image = android.frames.image, android.state == .running, !android.isFoldTransitioning,
           let revision = input.setFrame(panel: 0, layout: WebPanelLayout(
               width: image.width, height: image.height, rotation: android.displayRotation
           )) {
            stream.submit(WebDeviceStatus(panel: 0, revision: revision, width: image.width, height: image.height,
                                         orientation: android.displayRotation, density: 460 / Double(max(1, androidDensity))),
                          source: .android(image, android.frames.frameNumber))
        } else {
            _ = input.setFrame(panel: 0, layout: nil)
            stream.submit(WebDeviceStatus(panel: 0), source: nil)
        }
        for (offset, kind) in IOSSimulatorKind.allCases.enumerated() {
            let panel = offset + 1
            guard let runtime = ios[kind], runtime.state == .running else {
                _ = input.setFrame(panel: panel, layout: nil)
                let note: String?
                if !compatibleIOS.contains(kind) { note = IOSSimulatorRuntime.missingRuntimeMessage(for: kind) }
                else if case .error(let message) = ios[kind]?.state { note = message }
                else { note = nil }
                stream.submit(WebDeviceStatus(panel: panel, unavailableReason: note), source: nil)
                continue
            }
            var status = WebDeviceStatus(panel: panel, orientation: runtime.orientation.clockwiseQuarterTurns)
            if kind == .iphoneDuo {
                status.angle = runtime.duoHingeAngle
                status.is3DPoseActive = runtime.duoHingeAngle < 179.5 || runtime.isChangingHinge
                status.hingeBusy = runtime.isChangingHinge
            }
            guard let surface = feeds[kind]?.surface else {
                _ = input.setFrame(panel: panel, layout: nil)
                stream.submit(status, source: nil)
                continue
            }
            let width = IOSurfaceGetWidth(surface)
            let height = IOSurfaceGetHeight(surface)
            let inner = kind == .iphoneDuo && width * height >= 4_000_000
            let turns = inner && height > width ? runtime.orientation.duoInnerQuarterTurns : status.orientation
            let layout = WebPanelLayout(width: width, height: height, rotation: turns,
                                        screenID: inner ? IOSSimulatorRuntime.duoInnerScreenID : 1)
            status.width = width
            status.height = height
            status.rotation = turns
            if kind == .iphoneDuo { status.activeDisplay = inner ? "inner" : "outer" }
            status.revision = input.setFrame(panel: panel,
                                              layout: runtime.isRotating ? nil : layout)
            stream.submit(status, source: .ios(surface))
        }
    }

    private func refreshFeeds(_ runtimes: [IOSSimulatorKind: IOSSimulatorRuntime]) {
        for (kind, runtime) in runtimes {
            feeds[kind] = runtime.state == .running ? try? runtime.frameFeed() : nil
            feeds[kind]?.prepareInput()
        }
    }

    private func untilReady(_ condition: @MainActor () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(720)
        while !Task.isCancelled {
            if try condition() { return }
            guard ContinuousClock.now < deadline else { throw SetupError("Timed out waiting for the simulator.") }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CancellationError()
    }
}

struct WebMultiSimToolbar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var web: WebMultiSimController
    let workspace: MultiSimWorkspace
    @State private var selectedLANAddress: String?
    @State private var showLANConfirmation = false
    @State private var showPublicConfirmation = false

    var body: some View {
        HStack(spacing: 7) {
            switch web.state {
            case .stopped:
                startButton
            case .failed(let error):
                startButton
                Text(error).lineLimit(1).frame(maxWidth: 215).help(error).foregroundStyle(.secondary)
            case .starting(let progress, let stage):
                ZStack {
                    Circle().stroke(.secondary.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: progress).stroke(Theme.accent, lineWidth: 2).rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .accessibilityLabel("Startup progress")
                .accessibilityValue(Text("\(Int(progress * 100)) percent"))
                Text(stage).lineLimit(1).frame(maxWidth: 250).help(stage)
                Button("Cancel") { web.stop() }
            case .running:
                Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Running")
                Link("Open", destination: WebMultiSimServer.address).help("Open Web MultiSim")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(WebMultiSimServer.address.absoluteString, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy local address")
                lanMenu
                if web.lanURL != nil { publicMenu }
                Button("Stop") { web.stop() }
            }
        }
        .font(.system(size: 11))
        .confirmationDialog("Share simulator screens and controls on your network?",
                            isPresented: $showLANConfirmation, titleVisibility: .visible) {
            Button("Enable LAN Access") {
                if let selectedLANAddress { web.startLAN(address: selectedLANAddress) }
            }
        } message: {
            Text("Anyone with the copied link can see and control these simulators until you stop sharing. Use a trusted Wi-Fi or Ethernet network.")
        }
        .alert("Web sharing", isPresented: Binding(
            get: { web.sharingError != nil },
            set: { if !$0 { web.sharingError = nil } }
        )) {
            Button("OK") { web.sharingError = nil }
        } message: {
            Text(web.sharingError ?? "")
        }
    }

    private var publicMenu: some View {
        Menu {
            if let url = web.publicURL {
                Text(url.host ?? "")
                Button("Copy Public Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Button("Stop Public Access") { web.stopPublic() }
            } else if web.isStartingPublic {
                Button("Cancel Public Access") { web.stopPublic() }
            } else {
                Button("Enable Public Access…") { showPublicConfirmation = true }
            }
        } label: {
            Label(web.isStartingPublic ? "Connecting…" : web.publicURL == nil ? "Public Access" : "Public Access On",
                  systemImage: "globe")
        }
        .confirmationDialog("Allow control over the internet?", isPresented: $showPublicConfirmation, titleVisibility: .visible) {
            Button("Enable Public Access") { web.startPublic() }
        } message: {
            Text("Anyone with the public link can view and control these simulators through Cloudflare until you stop sharing.")
        }
    }

    private var lanMenu: some View {
        Menu {
            if let url = web.lanURL {
                if let host = url.host { Text("\(host):8080") }
                Button("Copy LAN Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Toggle("LAN Power Saving", isOn: $web.lanPowerSaving)
                Button("Stop Sharing") { web.stopLAN() }
            } else {
                let addresses = WebLANAddresses.available()
                if addresses.isEmpty {
                    Text("No active Wi-Fi or Ethernet IPv4 address")
                }
                ForEach(addresses, id: \.self) { address in
                    Button("Share on \(address)") {
                        selectedLANAddress = address
                        showLANConfirmation = true
                    }
                }
            }
        } label: {
            Label(web.isStartingLAN ? "Sharing…" : web.lanURL == nil ? "Share on LAN" : "LAN Shared",
                  systemImage: web.lanURL == nil ? "wifi" : "wifi.circle.fill")
        }
        .disabled(web.isStartingLAN)
    }

    private var startButton: some View {
        Button {
            web.start(model: model, workspace: workspace)
        } label: {
            Label("Start Web Service", systemImage: "globe")
        }
    }
}
