import AppKit
import CoreImage
import ImageIO
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
    private var task: Task<Void, Never>?
    private var server: WebMultiSimServer?
    private var feeds: [IOSSimulatorKind: SimulatorFrameFeed] = [:]
    private var feedUDIDs: [IOSSimulatorKind: String] = [:]
    private var surfaces: [IOSSimulatorKind: IOSurface] = [:]

    func start(model: AppModel, workspace: MultiSimWorkspace) {
        guard task == nil else { return }
        state = .starting(0.05, "[1/4] Starting Android and preparing Quick Boot…")
        let previousSelection = workspace.androidID
        task = Task { [weak self, weak model] in
            guard let self, let model else { return }
            do {
                guard let android = model.devices.first(where: { $0.id == previousSelection }),
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
                for (index, kind) in IOSSimulatorKind.allCases.enumerated() {
                    state = .starting(index == 0 ? 0.32 : 0.55, "[2/4] Applying SimSlim and starting \(kind.name)…")
                    guard let runtime = model.iosRuntimes[kind] else { throw SetupError("Missing \(kind.name).") }
                    runtime.start()
                    try await untilReady {
                        if case .error(let message) = runtime.state { throw SetupError(message) }
                        return runtime.state == .running
                    }
                }
                state = .starting(0.78, "[3/4] Connecting the IOSurface streams…")
                try await untilReady {
                    try self.refreshFeeds(model.iosRuntimes)
                    return self.surfaces.count == IOSSimulatorKind.allCases.count
                }

                let server = WebMultiSimServer()
                self.server = server
                state = .starting(0.95, "[4/4] Starting the local WebSocket listener…")
                try await server.start()
                try Task.checkCancellation()
                state = .running

                let encoder = WebFrameEncoder()
                while !Task.isCancelled {
                    if server.hasViewers {
                        try? refreshFeeds(model.iosRuntimes)
                        let orientation = model.iosRuntimes.mapValues(\.orientation)
                        let frames = surfaces
                        let androidImage = androidRuntime.frames.image
                        await Task.detached(priority: .utility) {
                            if let androidImage,
                               let encoded = encoder.encode(CIImage(cgImage: androidImage)) {
                                server.publish(encoded, panel: 0)
                            }
                            for (index, kind) in IOSSimulatorKind.allCases.enumerated() {
                                guard let surface = frames[kind], let orientation = orientation[kind] else { continue }
                                let raw = CIImage(ioSurface: surface)
                                let inner = kind == .iphoneDuo && raw.extent.width * raw.extent.height >= 4_000_000
                                    && raw.extent.height > raw.extent.width
                                let turns = inner ? orientation.duoInnerQuarterTurns : orientation.clockwiseQuarterTurns
                                let transforms: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
                                if let encoded = encoder.encode(raw.oriented(transforms[turns])) {
                                    server.publish(encoded, panel: UInt8(index + 1))
                                }
                            }
                        }.value
                    }
                    try await Task.sleep(for: .milliseconds(server.hasViewers ? 150 : 500))
                }
            } catch {
                guard !Task.isCancelled else { return }
                stop()
                state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        server?.stop()
        server = nil
        feeds.values.forEach { $0.stop() }
        feeds.removeAll()
        feedUDIDs.removeAll()
        surfaces.removeAll()
        state = .stopped
    }

    private func refreshFeeds(_ runtimes: [IOSSimulatorKind: IOSSimulatorRuntime]) throws {
        for (kind, runtime) in runtimes {
            guard runtime.state == .running, let udid = runtime.udid else {
                if let previous = feeds.removeValue(forKey: kind) { previous.stop() }
                feedUDIDs[kind] = nil
                surfaces[kind] = nil
                continue
            }
            if feedUDIDs[kind] != udid {
                feeds.removeValue(forKey: kind)?.stop()
                surfaces[kind] = nil
                feedUDIDs[kind] = udid
                do {
                    feeds[kind] = try SimulatorFrameFeed(udid: udid) { [weak self] surface in
                        guard let self, self.feedUDIDs[kind] == udid else { return }
                        self.surfaces[kind] = surface
                    }
                } catch {
                    feedUDIDs[kind] = nil
                    throw error
                }
            }
            if let inner = runtime.isDuoInnerPanelActive {
                feeds[kind]?.preferInnerDisplay(inner)
            }
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

private final class WebFrameEncoder: Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func encode(_ image: CIImage) -> Data? {
        let scale = min(1, 840 / max(image.extent.width, image.extent.height))
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.jpegRepresentation(of: resized, colorSpace: colorSpace,
                                          options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.70])
    }
}

struct WebMultiSimToolbar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var web: WebMultiSimController
    let workspace: MultiSimWorkspace

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
                Button("Stop") { web.stop() }
                Text("127.0.0.1:8080").lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
    }

    private var startButton: some View {
        Button {
            web.start(model: model, workspace: workspace)
        } label: {
            Label("Start Web Service", systemImage: "globe")
        }
    }
}
