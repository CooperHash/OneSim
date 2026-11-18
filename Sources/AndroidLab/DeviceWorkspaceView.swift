import SwiftUI
import AppKit

/// The emulator lives inside the selected device's main-window workspace.
struct DeviceWorkspaceView: View {
    let deviceID: String
    var showsWindowToolbar = true
    var pairedPhoneScreenHeight: CGFloat? = nil
    @EnvironmentObject private var model: AppModel

    @State private var zoom: CGFloat = 1
    @State private var showType = false
    @State private var showApps = false
    @State private var showLog = false
    @State private var text = ""
    @StateObject private var resources = SimulatorResourceMonitor()

    private var device: AvdDevice? {
        model.devices.first { $0.id == deviceID }
    }

    @ObservedObject var runtime: DeviceRuntime

    var body: some View {
        Group {
            if let device {
                HStack(spacing: 0) {
                    LiveDeviceCanvas(
                        device: device, runtime: runtime, frames: runtime.frames,
                        zoom: zoom, pairedPhoneScreenHeight: pairedPhoneScreenHeight
                    )
                        .allowsHitTesting(!runtime.isFoldTransitioning)
                    Divider()
                    toolbar(device, runtime)
                }
                .navigationTitle(showsWindowToolbar ? "\(device.displayName) — Emulator" : "MultiSim")
                .toolbar {
                    if showsWindowToolbar {
                      ToolbarItemGroup(placement: .automatic) {
                        Button { zoom = max(0.5, zoom - 0.15) } label: {
                            Label("Zoom Out", systemImage: "minus.magnifyingglass")
                        }
                        .help("Zoom out")
                        .disabled(!runtime.isScreenConnected || zoom <= 0.5)
                        Button { zoom = 1 } label: {
                            Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .help("Zoom to fit")
                        .disabled(!runtime.isScreenConnected)
                        Button { zoom = min(2.5, zoom + 0.15) } label: {
                            Label("Zoom In", systemImage: "plus.magnifyingglass")
                        }
                        .help("Zoom in")
                        .disabled(!runtime.isScreenConnected || zoom >= 2.5)
                    }
                      ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 8) {
                            if runtime.state == .running {
                                SimulatorResourceBadge(usage: resources.readings["android:\(deviceID)"])
                            }
                            AndroidSlimMenu(device: device, paths: model.settings, runtime: runtime)
                            StatusBadge(state: runtime.state)
                            Button {
                                showLog = true
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            .popover(isPresented: $showLog, arrowEdge: .bottom) {
                                logPopover(runtime)
                            }
                            .help("Session log")
                        }
                      }
                    }
                }
                .sheet(isPresented: $showApps) {
                    AppsView(deviceID: device.id).environmentObject(model)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text("This emulator no longer exists.")
                        .font(.system(size: 14, weight: .semibold))
                    Text(deviceID)
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.stage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Could not change fold state", isPresented: Binding(
            get: { runtime.foldError != nil },
            set: { if !$0 { runtime.foldError = nil } }
        )) {
            Button("OK") { runtime.foldError = nil }
        } message: {
            Text(runtime.foldError ?? "")
        }
        .task(id: runtime.state) {
            guard showsWindowToolbar else { return }
            while !Task.isCancelled {
                let targets: [SimulatorResourceTarget] = runtime.state == .running
                    ? [.android(key: "android:\(deviceID)", avdName: deviceID)] : []
                await resources.refresh(targets)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: - Vertical toolbar

    private func toolbar(_ device: AvdDevice, _ runtime: DeviceRuntime) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                VerticalToolButton(icon: "rotate.right", title: "Rotate") { model.rotate(deviceID: device.id) }
                    .disabled(!runtime.state.isLive)
                if device.isFoldable {
                    VerticalToolButton(
                        icon: runtime.isFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                        title: runtime.isFoldTransitioning ? "Waiting…" : (!runtime.isFoldStateKnown ? "Fold / Unfold" : (runtime.isFolded ? "Unfold" : "Fold")),
                        isActive: runtime.isFolded
                    ) { model.toggleFold(device) }
                    .disabled(runtime.state != .running || runtime.isFoldTransitioning)
                }
                Divider().padding(.vertical, 3)
                Group {
                    VerticalToolButton(icon: "chevron.backward", title: "Back") { model.key(deviceID: device.id, code: 4) }
                    VerticalToolButton(icon: "house", title: "Home") { model.key(deviceID: device.id, code: 3) }
                    VerticalToolButton(icon: "square.on.square", title: "Recents") { model.key(deviceID: device.id, code: 187) }
                }.disabled(!runtime.state.isLive)
                Divider().padding(.vertical, 3)
                Group {
                    VerticalToolButton(icon: "speaker.minus", title: "Vol −") { model.key(deviceID: device.id, code: 25) }
                    VerticalToolButton(icon: "speaker.plus", title: "Vol +") { model.key(deviceID: device.id, code: 24) }
                    VerticalToolButton(icon: "power", title: "Power") { model.key(deviceID: device.id, code: 26) }
                }.disabled(!runtime.state.isLive)
                Divider().padding(.vertical, 3)
                Group {
                    VerticalToolButton(icon: "keyboard", title: "Type") { showType.toggle() }
                        .popover(isPresented: $showType, arrowEdge: .leading) { typePopover(device) }
                    VerticalToolButton(icon: "square.and.arrow.down", title: "APK") { model.installAPK(deviceID: device.id) }
                    VerticalToolButton(icon: "list.bullet.rectangle", title: "Apps") {
                        Task { await model.reloadApps(deviceID: device.id); showApps = true }
                    }
                    VerticalToolButton(icon: "camera", title: "Shot") { model.screenshot(deviceID: device.id) }
                }.disabled(!runtime.state.isLive)
                Spacer(minLength: 6)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .frame(width: 68)
        .background(.bar)
    }

    private func typePopover(_ device: AvdDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send text to \(device.displayName)").font(.system(size: 12, weight: .semibold))
            TextField("Hello world", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { sendText(device) }
            HStack {
                Text("ASCII only. Use the on-screen keyboard for other languages.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Send") { sendText(device) }.disabled(text.isEmpty)
            }
        }.padding(12)
    }

    private func sendText(_ device: AvdDevice) {
        guard !text.isEmpty else { return }
        model.typeText(deviceID: device.id, text: text)
        text = ""
        showType = false
    }

    private func logPopover(_ runtime: DeviceRuntime) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session log").font(.system(size: 12, weight: .semibold))
            ScrollView {
                Text(runtime.bootLog.isEmpty ? "No log output yet." : runtime.bootLog)
                    .font(Theme.mono).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: 560, height: 300)
        }.padding(12)
    }
}

private struct LiveDeviceCanvas: View {
    let device: AvdDevice
    @ObservedObject var runtime: DeviceRuntime
    @ObservedObject var frames: ScreenFrameStore
    let zoom: CGFloat
    let pairedPhoneScreenHeight: CGFloat?
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.stage

                if let image = frames.image {
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        VStack(spacing: 0) {
                            Spacer(minLength: pairedPhoneScreenHeight == nil ? 26 : 18)
                            HStack(spacing: 0) {
                                Spacer(minLength: pairedPhoneScreenHeight == nil ? 26 : 18)
                                DeviceStage(
                                    device: device,
                                    image: image,
                                    onTap: { model.tap(deviceID: device.id, x: $0, y: $1) },
                                    onSwipe: { model.swipe(deviceID: device.id, x1: $0, y1: $1, x2: $2, y2: $3, duration: $4) },
                                    onLongPress: { model.swipe(deviceID: device.id, x1: $0, y1: $1, x2: $0, y2: $1, duration: 720) },
                                    onTouch: { model.touch(deviceID: device.id, x: $0, y: $1, phase: $2) },
                                    zoom: zoom,
                                    pairedPhoneScreenHeight: pairedPhoneScreenHeight,
                                    frameStore: frames
                                )
                                Spacer(minLength: pairedPhoneScreenHeight == nil ? 26 : 18)
                            }
                            Spacer(minLength: pairedPhoneScreenHeight == nil ? 26 : 18)
                        }
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                } else {
                    if runtime.state == .starting || runtime.state == .booting {
                        BootPlaceholder(runtime: runtime)
                    } else if runtime.state == .running {
                        ConnectingPlaceholder(runtime: runtime) {
                            model.coldBootDevice(device)
                        }
                    } else if runtime.state == .error {
                        ErrorPlaceholder(runtime: runtime) {
                            model.startDevice(device)
                        }
                    } else {
                        StoppedPlaceholder(device: device) {
                            model.startDevice(device)
                        }
                    }
                }

                VStack {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Theme.statusColor(runtime.state))
                            .frame(width: 7, height: 7)
                        Text(device.displayName)
                            .font(.system(size: 11, weight: .medium))
                        Text(runtime.state.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
                    .padding(.top, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            .clipped()
        }
    }
}

struct VerticalToolButton: View {
    let icon: String
    let title: String
    var isActive: Bool = false
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 54, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint ?? .primary)
        .background(
            isActive ? Theme.accent.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .help(title)
    }
}
