import SwiftUI
import AppKit

struct DeviceDetailView: View {
    let device: AvdDevice
    @ObservedObject var runtime: DeviceRuntime
    @EnvironmentObject private var model: AppModel

    @State private var showType = false
    @State private var showDelete = false
    @State private var showLog = false
    @State private var text = ""

    private var isLive: Bool { runtime.state == .running || runtime.state == .booting }
    private var isBusy: Bool { runtime.state.isBusy }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stage
            Divider()
            controls
        }
        .navigationTitle(device.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isLive {
                    Button {
                        model.stopDevice(device)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop emulator")
                } else {
                    Button {
                        model.startDevice(device)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || !model.settings.isUsable)
                    .help("Start emulator")
                }

                Menu {
                    Button("Cold Boot") { model.coldBootDevice(device) }
                    Button("Wipe Data…") { model.wipeDevice(device) }
                    Divider()
                    Button("Show AVD in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.path)])
                    }
                    Button("Copy ADB command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "\(model.settings.adb) -s \(runtime.serial ?? "emulator-5554") shell",
                            forType: .string
                        )
                        model.toast = "ADB command copied."
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { showDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Delete \(device.displayName)?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deleteDevice(device) }
        } message: {
            Text("The AVD and its user data will be removed from disk.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                Image(systemName: iconName)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(device.displayName)
                        .font(.system(size: 17, weight: .semibold))
                    StatusBadge(state: runtime.state)
                }
                HStack(spacing: 8) {
                    Text(device.subtitle)
                    if let profile = device.profile {
                        Text("·")
                        Text(profile.name)
                    }
                    if let serial = runtime.serial {
                        Text("·")
                        Text(serial).font(Theme.mono)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let error = runtime.errorMessage, runtime.state == .error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .trailing)
            }

            Button {
                showLog = true
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Emulator log")
            .popover(isPresented: $showLog, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session log")
                        .font(.system(size: 12, weight: .semibold))
                    ScrollView {
                        Text(runtime.bootLog.isEmpty ? "No log output yet." : runtime.bootLog)
                            .font(Theme.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 540, height: 260)
                }
                .padding(12)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var iconName: String {
        switch device.profile?.category {
        case "tablet": return "ipad.gen2"
        case "watch": return "applewatch"
        case "tv": return "tv"
        case "foldable": return "iphone.gen3.radiowaves.left.and.right"
        default: return "iphone.gen3"
        }
    }

    // MARK: - Stage

    private var stage: some View {
        ZStack {
            Theme.stage
            if let image = runtime.frame {
                DeviceStage(
                    device: device,
                    image: image,
                    onTap: { model.tap($0, $1) },
                    onSwipe: { model.swipe($0, $1, $2, $3, $4) },
                    onLongPress: { model.swipe($0, $1, $0, $1, 720) },
                    onTouch: { model.touch(deviceID: device.id, x: $0, y: $1, phase: $2) },
                    onKeyboard: { model.sendKeyboard($0, to: device.id) }
                )
                if runtime.state == .booting || runtime.state == .starting {
                    VStack {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Booting Android…")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(.top, 18)
                        Spacer()
                    }
                }
            } else {
                if runtime.state == .running {
                    ConnectingPlaceholder(runtime: runtime) { model.coldBootDevice(device) }
                } else if runtime.state == .starting || runtime.state == .booting {
                    BootPlaceholder(runtime: runtime)
                } else if runtime.state == .error {
                    ErrorPlaceholder(runtime: runtime) { model.startDevice(device) }
                } else {
                    StoppedPlaceholder(device: device) { model.startDevice(device) }
                        .disabled(!model.settings.isUsable)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 5) {
            ControlButton(icon: "chevron.backward", title: "Back") { model.key(4) }
            ControlButton(icon: "house", title: "Home") { model.key(3) }
            ControlButton(icon: "square.on.square", title: "Recents") { model.key(187) }

            Divider().frame(height: 22).padding(.horizontal, 4)

            ControlButton(icon: "rotate.right", title: "Rotate") { model.rotate() }
            ControlButton(icon: "speaker.minus", title: "Vol −") { model.key(25) }
            ControlButton(icon: "speaker.plus", title: "Vol +") { model.key(24) }
            ControlButton(icon: "power", title: "Power") { model.key(26) }

            Divider().frame(height: 22).padding(.horizontal, 4)

            Button {
                showType.toggle()
            } label: {
                Label("Type", systemImage: "keyboard")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showType, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Send text to the device")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("Hello world", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit(sendText)
                    HStack {
                        Text("You can also click the simulator and type with your Mac keyboard.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Send", action: sendText)
                            .disabled(text.isEmpty)
                    }
                }
                .padding(12)
            }

            Button {
                model.installAPK()
            } label: {
                Label("APK", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)

            Button {
                model.loadApps()
            } label: {
                Label("Apps", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)

            Button {
                model.screenshot()
            } label: {
                Label("Shot", systemImage: "camera")
            }
            .buttonStyle(.borderless)

            Spacer()

            if model.isInstalling {
                ProgressView().controlSize(.small)
            }

            Text(device.api.replacingOccurrences(of: "android-", with: "API "))
                .font(Theme.mono)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .disabled(!isLive)
        .opacity(isLive ? 1 : 0.55)
    }

    private func sendText() {
        guard !text.isEmpty else { return }
        model.typeText(text)
        text = ""
        showType = false
    }
}

struct StatusBadge: View {
    let state: DeviceState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.statusColor(state))
                .frame(width: 6, height: 6)
            Text(state.label)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.statusColor(state).opacity(0.12), in: Capsule())
        .foregroundStyle(Theme.statusColor(state))
    }
}

struct DeviceStage: View {
    let device: AvdDevice
    let image: CGImage
    let onTap: (Int, Int) -> Void
    let onSwipe: (Int, Int, Int, Int, Int) -> Void
    let onLongPress: (Int, Int) -> Void
    var onTouch: ((Int, Int, TouchPhase) -> Bool)? = nil
    var onKeyboard: ((SimulatorKeyboardInput) -> Void)?
    var zoom: CGFloat = 1
    var pairedPhoneScreenHeight: CGFloat? = nil
    var frameStore: ScreenFrameStore? = nil

    private struct StageLayout {
        let screen: CGSize
        let frame: CGSize
        let bezel: CGFloat
        let corner: CGFloat
        let isCircular: Bool
        let isTablet: Bool
        let isOpenFold: Bool
    }

    private func stageLayout() -> StageLayout {
        let profile = device.profile
        let isCircular = profile?.isCircular ?? false
        let isTablet = profile?.isTablet ?? false
        let isOpenFold = device.isFoldable && CGFloat(image.width) > CGFloat(image.height) * 0.8
        let bezel: CGFloat = isCircular ? 16 : (isOpenFold ? 18 : (isTablet ? 22 : 13))
        let corner: CGFloat = isOpenFold ? 16 : (device.isFoldable ? 24 : (profile?.cornerRadius ?? 32))
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let isLandscape = image.width > image.height
        let phoneHeight = pairedPhoneScreenHeight ?? 640
        let baseHeight: CGFloat = isOpenFold ? 520 : (isLandscape ? 420 : (isCircular ? 420 : (isTablet ? 470 : phoneHeight)))
        let baseWidth: CGFloat = isOpenFold ? 630 : (isLandscape ? 760 : (isTablet ? 620 : 360))
        let maxHeight = baseHeight * zoom
        let maxWidth = baseWidth * zoom
        var screenHeight = maxHeight
        var screenWidth = screenHeight * aspect
        if screenWidth > maxWidth {
            screenWidth = maxWidth
            screenHeight = screenWidth / aspect
        }
        return StageLayout(
            screen: CGSize(width: screenWidth, height: screenHeight),
            frame: CGSize(width: screenWidth + bezel * 2, height: screenHeight + bezel * 2),
            bezel: bezel, corner: corner,
            isCircular: isCircular, isTablet: isTablet, isOpenFold: isOpenFold
        )
    }

    var body: some View {
        let layout = stageLayout()
        let screenWidth = layout.screen.width
        let screenHeight = layout.screen.height
        let frameWidth = layout.frame.width
        let frameHeight = layout.frame.height
        let bezel = layout.bezel
        let corner = layout.corner
        let isCircular = layout.isCircular
        let isTablet = layout.isTablet
        let isOpenFold = layout.isOpenFold

        ZStack {
            if isCircular {
                Circle()
                    .fill(Theme.bezel)
                    .overlay(Circle().stroke(Theme.bezelHighlight, lineWidth: 2))
                    .frame(width: frameWidth, height: frameHeight)
                    .shadow(color: .black.opacity(0.55), radius: 34, y: 18)
                ScreenSurface(image: image, onTap: onTap, onSwipe: onSwipe, onLongPress: onLongPress, onTouch: onTouch, onKeyboard: onKeyboard, frameStore: frameStore)
                    .frame(width: screenWidth, height: screenHeight)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.black.opacity(0.55), lineWidth: 2).allowsHitTesting(false))
            } else {
                RoundedRectangle(cornerRadius: corner + bezel, style: .continuous)
                    .fill(Theme.bezel)
                    .overlay(
                        RoundedRectangle(cornerRadius: corner + bezel, style: .continuous)
                            .stroke(Theme.bezelHighlight, lineWidth: 1.5)
                    )
                    .frame(width: frameWidth, height: frameHeight)
                    .shadow(color: .black.opacity(0.55), radius: 36, y: 20)

                if isOpenFold {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(white: 0.28))
                            .frame(width: 5)
                        Spacer()
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(white: 0.14))
                            .frame(width: 5)
                    }
                    .frame(width: frameWidth + 8, height: frameHeight * 0.83)
                    .allowsHitTesting(false)
                }

                ScreenSurface(image: image, onTap: onTap, onSwipe: onSwipe, onLongPress: onLongPress, onTouch: onTouch, onKeyboard: onKeyboard, frameStore: frameStore)
                    .frame(width: screenWidth, height: screenHeight)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(.black.opacity(0.6), lineWidth: 1)
                            .allowsHitTesting(false)
                    )

                if isOpenFold {
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [.black.opacity(0.24), .white.opacity(0.10), .black.opacity(0.18)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: 9, height: screenHeight - 4)
                        .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.20))
                    .frame(width: 3, height: frameHeight * 0.10)
                    .offset(x: frameWidth / 2 + 1, y: -frameHeight * 0.18)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.18))
                    .frame(width: 3, height: frameHeight * 0.06)
                    .offset(x: frameWidth / 2 + 1, y: -frameHeight * 0.02)
                if device.isFoldable && !isOpenFold {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.35))
                        .frame(width: 5, height: frameHeight * 0.8)
                        .offset(x: -frameWidth / 2 - 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: frameWidth, height: frameHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BootPlaceholder: View {
    @ObservedObject var runtime: DeviceRuntime

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text("Starting Android")
                    .font(.system(size: 16, weight: .semibold))
                Text("Cold boot can take 30–120 seconds on the first run.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(runtime.bootLog.isEmpty ? "Waiting for the emulator…" : runtime.bootLog)
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 520)
            .frame(height: 130)
            .padding(10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(30)
    }
}

struct ConnectingPlaceholder: View {
    @ObservedObject var runtime: DeviceRuntime
    let restart: () -> Void
    @State private var showRestart = false

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to the live screen…")
                .font(.system(size: 16, weight: .semibold))
            Text(runtime.isScreenConnected ? "Waiting for the first frame." : "The emulator is running, but its screen stream is not responding.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if showRestart {
                Button("Restart Emulator", action: restart)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                showRestart = true
            }
        }
    }
}

struct ErrorPlaceholder: View {
    @ObservedObject var runtime: DeviceRuntime
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38, weight: .thin))
                .foregroundStyle(.orange)
            Text("Emulator failed to start")
                .font(.system(size: 16, weight: .semibold))
            Text(runtime.errorMessage ?? "Unknown error")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(30)
    }
}

struct StoppedPlaceholder: View {
    let device: AvdDevice
    let start: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            DeviceArtwork(device: device)
            VStack(spacing: 5) {
                Text(device.displayName)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(device.api.replacingOccurrences(of: "android-", with: "Android ")) Emulator")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button("Start", action: start)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(minWidth: 72)
        }
        .padding(32)
    }
}

struct ControlButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 9))
            }
            .frame(width: 44, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}
