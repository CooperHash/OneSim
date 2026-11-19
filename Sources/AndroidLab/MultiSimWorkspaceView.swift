import AppKit
import SwiftUI
import SimKit

/// A workspace of independently sized devices. Narrow windows scroll instead of scaling screens.
struct MultiSimWorkspaceView: View {
    let workspace: MultiSimWorkspace
    @ObservedObject var web: WebMultiSimController
    @State private var windowVisible = true
    private var previewVisible: Bool { windowVisible && !web.lanPowerSaving }

    @EnvironmentObject private var model: AppModel
    @StateObject private var resources = SimulatorResourceMonitor()

    private var availableAndroids: [AvdDevice] {
        model.devices.filter { !workspace.members.contains(.android($0.id)) }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(workspace.members) { member in
                            memberColumn(member).id(member.id)
                        }
                    }
                    .padding(18)
                    .frame(minWidth: geometry.size.width, alignment: .topLeading)
                }
                .onChange(of: workspace.members) { oldMembers, newMembers in
                    guard let added = newMembers.first(where: { !oldMembers.contains($0) }) else { return }
                    withAnimation { scrollProxy.scrollTo(added.id, anchor: .trailing) }
                }
                .background(Theme.stage)
            }
        }
        .environment(\.simulatorPreviewPaused, !previewVisible)
        .background(WindowPreviewVisibility(visible: $windowVisible))
        .navigationTitle("MultiSim")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Section("Android") {
                        ForEach(availableAndroids) { device in
                            Button(device.displayName) {
                                model.addToMultiSim(.android(device.id), androidID: workspace.androidID)
                            }
                        }
                        Button("New Android Device…") {
                            model.createDeviceForWorkspaceID = workspace.androidID
                            model.showCreate = true
                        }
                    }
                    Section("Apple") {
                        ForEach(IOSSimulatorKind.allCases) { kind in
                            if !workspace.members.contains(.ios(kind)) {
                                Button(kind.name) {
                                    model.addToMultiSim(.ios(kind), androidID: workspace.androidID)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add Simulator", systemImage: "plus")
                }
                .help("Add a simulator to this workspace")

                WebMultiSimToolbar(web: model.web, workspace: workspace)
            }
        }
        .task(id: previewVisible ? workspace.members : []) {
            guard previewVisible else { return }
            while !Task.isCancelled {
                await resources.refresh(activeResourceTargets)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private var activeResourceTargets: [SimulatorResourceTarget] {
        workspace.members.compactMap { member in
            switch member {
            case .android(let id):
                guard model.runtimes[id]?.state == .running else { return nil }
                return .android(key: member.id, avdName: id)
            case .ios(let kind):
                guard let runtime = model.iosRuntimes[kind], runtime.state == .running,
                      let udid = runtime.udid else { return nil }
                return .ios(key: member.id, udid: udid)
            }
        }
    }

    @ViewBuilder
    private func memberColumn(_ member: MultiSimMember) -> some View {
        switch member {
        case .android(let id):
            if let device = model.devices.first(where: { $0.id == id }),
               let runtime = model.runtimes[id] {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Circle().fill(Color(red: 0.30, green: 0.82, blue: 0.52))
                            .frame(width: 7, height: 7)
                        Text("ANDROID")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(.secondary)
                        Text(device.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("\(device.width) × \(device.height) · \(runtime.state.label)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        AndroidSlimMenu(device: device, paths: model.settings, runtime: runtime)
                        if id != workspace.androidID {
                            removeButton(member)
                        }
                    }
                    .padding(.horizontal, 8)
                    if runtime.state == .running {
                        SimulatorResourceBadge(usage: resources.readings[member.id])
                            .padding(.horizontal, 8)
                    }
                    DeviceWorkspaceView(
                        deviceID: id, showsWindowToolbar: false,
                        pairedPhoneScreenHeight: CGFloat(device.height) / CGFloat(max(device.density, 1))
                            * 460 * IOSSimulatorColumn.pointsPerNativePixel,
                        runtime: runtime
                    )
                    .environmentObject(model)
                    .frame(width: 440, height: 790)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.separator))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        case .ios(let kind):
            if let runtime = model.iosRuntimes[kind] {
                IOSSimulatorColumn(kind: kind, runtime: runtime, previewVisible: previewVisible,
                                   resourceUsage: resources.readings[member.id]) {
                    model.removeFromMultiSim(member, androidID: workspace.androidID)
                }
            }
        }
    }

    private func memberName(_ member: MultiSimMember) -> String {
        switch member {
        case .android(let id): model.devices.first { $0.id == id }?.displayName ?? id
        case .ios(let kind): kind.name
        }
    }

    private func removeButton(_ member: MultiSimMember) -> some View {
        Button {
            model.removeFromMultiSim(member, androidID: workspace.androidID)
        } label: {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Remove from MultiSim")
        .accessibilityLabel("Remove \(memberName(member)) from MultiSim")
    }
}

private struct IOSSimulatorColumn: View {
    let kind: IOSSimulatorKind
    @ObservedObject var runtime: IOSSimulatorRuntime
    let previewVisible: Bool
    let resourceUsage: SimulatorResourceUsage?
    let onRemove: () -> Void
    @State private var screenError: String?
    @State private var iosImageSize: CGSize?
    @State private var zoom: CGFloat = 1
    @State private var showHinge = false

    // The 16 Pro's 2622-pixel display is 678 points tall in this workspace.
    // Every screen is drawn at the same physical scale using the simulator's
    // native pixel dimensions and its 460 ppi screen density.
    static let innerScreenID: UInt32 = IOSSimulatorRuntime.duoInnerScreenID
    static let outerScreenID: UInt32 = IOSSimulatorRuntime.duoOuterScreenID

    static let pointsPerNativePixel: CGFloat = 678.0 / 2622.0

    private var duoDisplay: DuoActiveDisplay {
        if let iosImageSize {
            return iosImageSize.width * iosImageSize.height >= 4_000_000 ? .inner : .outer
        }
        return runtime.duoHingeAngle <= 45 ? .outer : .inner
    }

    private var isLandscape: Bool {
        displayScreenSize.width > displayScreenSize.height
    }

    // CoreSimulator exposes fixed panel-sized IOSurfaces. Their pixels do not
    // change dimensions when the physical device rotates, so rotate the image,
    // chrome, and touch coordinates together.
    private var screenQuarterTurns: Int {
        let physical = runtime.orientation.clockwiseQuarterTurns
        if kind == .iphoneDuo, duoDisplay == .inner,
           nativeScreenSize.height > nativeScreenSize.width {
            return runtime.orientation.duoInnerQuarterTurns
        }
        return physical
    }

    private var nativeScreenSize: CGSize {
        if let iosImageSize, iosImageSize.width > 0, iosImageSize.height > 0 {
            return iosImageSize
        }
        switch kind {
        case .iphone16Pro:
            return CGSize(width: 1206, height: 2622)
        case .iphoneDuo:
            return duoDisplay == .inner
                ? CGSize(width: 2007, height: 2853)
                : CGSize(width: 1398, height: 2034)
        }
    }

    private var displayScreenSize: CGSize {
        screenQuarterTurns.isMultiple(of: 2)
            ? nativeScreenSize
            : CGSize(width: nativeScreenSize.height, height: nativeScreenSize.width)
    }

    private var pointsPerPixel: CGFloat { Self.pointsPerNativePixel * zoom }

    private var screenWidth: CGFloat { displayScreenSize.width * pointsPerPixel }
    private var screenHeight: CGFloat { displayScreenSize.height * pointsPerPixel }

    // DeviceKit's chrome art is in points at the simulator's 3x pixel scale.
    private var duoChromeScale: CGFloat { 3 * pointsPerPixel }

    private var shellWidth: CGFloat {
        guard kind == .iphoneDuo else { return screenWidth + 22 * zoom }
        let horizontalPadding: CGFloat = duoDisplay == .outer ? 48 : 34
        let verticalPadding: CGFloat = duoDisplay == .outer ? 28 : 34
        return screenWidth + (isLandscape ? verticalPadding : horizontalPadding) * duoChromeScale
    }

    private var shellHeight: CGFloat {
        guard kind == .iphoneDuo else { return screenHeight + 22 * zoom }
        let horizontalPadding: CGFloat = duoDisplay == .outer ? 48 : 34
        let verticalPadding: CGFloat = duoDisplay == .outer ? 28 : 34
        return screenHeight + (isLandscape ? horizontalPadding : verticalPadding) * duoChromeScale
    }

    private var duoUnfoldedShellSize: CGSize {
        let padding = 34 * duoChromeScale
        let portraitOrient = runtime.orientation.clockwiseQuarterTurns.isMultiple(of: 2)
        let w = (portraitOrient ? 2853 : 2007) * pointsPerPixel + padding
        let h = (portraitOrient ? 2007 : 2853) * pointsPerPixel + padding
        return CGSize(width: w, height: h)
    }

    private var stageHeight: CGFloat {
        if kind == .iphoneDuo && runtime.is3DPoseActive {
            return max(720 * zoom, shellHeight + 28, duoUnfoldedShellSize.height + 28)
        }
        return max(260, shellHeight + 28)
    }
    private var panelWidth: CGFloat {
        let width = kind == .iphoneDuo && runtime.is3DPoseActive
            ? max(shellWidth, duoUnfoldedShellSize.width) : shellWidth
        return max(230, width + 30)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 0.58, green: 0.66, blue: 1))
                    .frame(width: 7, height: 7)
                Text("APPLE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Text(kind.name)
                    .font(.system(size: 12, weight: .medium))
                if kind == .iphoneDuo {
                    Text("\(duoDisplay.title) · \(Int(runtime.duoHingeAngle.rounded()))°")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if runtime.state == .running {
                    Text("\(Int(displayScreenSize.width)) × \(Int(displayScreenSize.height))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if let footprint = runtime.memoryFootprint {
                        Text("Process memory (snapshot): \(footprint)")
                    }
                    if let disabled = runtime.disabledServices,
                       let managed = runtime.managedServices {
                        Text("Background services disabled: \(disabled) / \(managed)")
                    }
                    Button("Refresh Memory Reading") {
                        runtime.refreshMemorySnapshot()
                    }
                    Button("Reduce Background Services") {
                        runtime.setMemoryOptimized(true)
                    }
                    .disabled(runtime.memoryMode == .balanced || runtime.isChangingMemory)
                    Button("Restore All Services") {
                        runtime.setMemoryOptimized(false)
                    }
                    .disabled(runtime.memoryMode == .normal || runtime.isChangingMemory)
                    Divider()
                    Text("Balanced keeps push, StoreKit, Universal Links, account sign-in, photo selection, and sharing.")
                } label: {
                    Label(runtime.isChangingMemory ? "Working…" : runtime.memoryMode.title,
                          systemImage: "memorychip")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(runtime.state != .running || runtime.isChangingMemory)
                .help("iOS simulator memory mode")
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove from MultiSim")
                .accessibilityLabel("Remove \(kind.name) from MultiSim")
            }
            .padding(.horizontal, 8)
            if runtime.state == .running {
                SimulatorResourceBadge(usage: resourceUsage)
                    .padding(.horizontal, 8)
            }
            iosPanel
                .frame(width: panelWidth + 69, height: stageHeight)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.separator))
        }
        .fixedSize(horizontal: true, vertical: false)
        .alert("Could not change Duo posture", isPresented: Binding(
            get: { runtime.hingeError != nil },
            set: { if !$0 { runtime.hingeError = nil } }
        )) {
            Button("OK") { runtime.hingeError = nil }
        } message: {
            Text(runtime.hingeError ?? "")
        }
        .alert("Could not change memory mode", isPresented: Binding(
            get: { runtime.memoryError != nil },
            set: { if !$0 { runtime.memoryError = nil } }
        )) {
            Button("OK") { runtime.memoryError = nil }
        } message: {
            Text(runtime.memoryError ?? "")
        }
        .alert("Could not rotate simulator", isPresented: Binding(
            get: { runtime.rotationError != nil },
            set: { if !$0 { runtime.rotationError = nil } }
        )) {
            Button("OK") { runtime.rotationError = nil }
        } message: {
            Text(runtime.rotationError ?? "")
        }
    }

    private var iosPanel: some View {
        HStack(spacing: 0) {
            ZStack {
                Theme.stage
                switch runtime.state {
                case .running:
                    if let udid = runtime.udid { iphoneFrame(udid: udid) }
                case .starting, .booting:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Starting \(kind.name)…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                case .stopped:
                    VStack(spacing: 12) {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 42, weight: .ultraLight))
                        Text("\(kind.name) is stopped")
                        Button("Start \(kind.name)") { runtime.start() }
                            .buttonStyle(.borderedProminent)
                    }
                case .error(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30))
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: panelWidth - 80)
                        Button("Retry") { runtime.start() }
                    }
                }
                if kind == .iphoneDuo, runtime.state == .running {
                    if runtime.is3DPoseActive {
                        Theme.stage.allowsHitTesting(false)
                    }
                    DuoFlipCanvas(display: duoDisplay, visible: runtime.is3DPoseActive && previewVisible, paused: !previewVisible, zoom: zoom) { runtime.flipRenderer = $0 }
                        .frame(width: panelWidth, height: stageHeight)
                        .opacity(runtime.is3DPoseActive ? 1 : 0)
                        .allowsHitTesting(false)
                    DuoPointerSurface(
                        runtime: runtime,
                        screenID: duoDisplay == .inner ? Self.innerScreenID : Self.outerScreenID,
                        quarterTurns: screenQuarterTurns
                    )
                    .frame(width: runtime.is3DPoseActive ? panelWidth : screenWidth,
                           height: runtime.is3DPoseActive ? stageHeight : screenHeight)
                    .offset(runtime.is3DPoseActive ? .zero : outerScreenOffset)
                    .allowsHitTesting(iosImageSize != nil)
                }
                if let screenError {
                    VStack {
                        Spacer()
                        Text(screenError)
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .padding(12)
                    }
                }
            }
            .frame(width: panelWidth, height: stageHeight)

            Divider()
            ScrollView(.vertical, showsIndicators: false) {
              VStack(spacing: 4) {
                SimulatorZoomButton(zoom: $zoom)
                Divider().padding(.vertical, 3)
                if kind == .iphoneDuo {
                    let isFolded = duoDisplay == .outer
                    VerticalToolButton(
                        icon: runtime.isChangingHinge ? "hourglass" : "rectangle.split.2x1",
                        title: runtime.isChangingHinge ? "Moving…" : (isFolded ? "Unfold" : "Fold")
                    ) {
                        runtime.setDuoFolded(!isFolded)
                    }
                    .disabled(runtime.isChangingHinge || runtime.isRotating)
                    VerticalToolButton(icon: "slider.horizontal.3", title: "Hinge") { showHinge.toggle() }
                        .popover(isPresented: $showHinge, arrowEdge: .trailing) {
                            duoHingeControlBar.frame(width: 380).padding(.vertical, 10)
                        }
                        .disabled(runtime.isRotating)
                }
                VerticalToolButton(icon: runtime.isRotating ? "hourglass" : "rotate.right",
                                   title: runtime.isRotating ? "Turning…" : "Rotate") {
                    runtime.rotateRight()
                }
                .disabled(runtime.isRotating || runtime.isChangingHinge)
                VerticalToolButton(icon: "house", title: "Home") {
                    _ = runtime.screenView?.press(.home)
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        do { try await runtime.goHome() }
                        catch { screenError = error.localizedDescription }
                    }
                }
                VerticalToolButton(icon: "square.on.square", title: "Apps") {
                    if runtime.screenView?.press(.appSwitcher) != true {
                        screenError = "App switcher input is unavailable."
                    }
                }
                VerticalToolButton(icon: "lock", title: "Lock") {
                    if runtime.screenView?.press(.power) != true {
                        screenError = "Side button input is unavailable."
                    }
                }
                VerticalToolButton(icon: "speaker.minus", title: "Vol −") {
                    if runtime.screenView?.press(.volumeDown) != true {
                        screenError = "Volume input is unavailable."
                    }
                }
                VerticalToolButton(icon: "speaker.plus", title: "Vol +") {
                    if runtime.screenView?.press(.volumeUp) != true {
                        screenError = "Volume input is unavailable."
                    }
                }
                VerticalToolButton(icon: "arrow.clockwise", title: "Restart") {
                    runtime.restart()
                }
              }
              .padding(.vertical, 8)
              .padding(.horizontal, 4)
              .frame(maxWidth: .infinity)
            }
            .frame(width: 68, height: stageHeight)
            .background(.bar)
            .disabled(runtime.state != .running)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .onChange(of: runtime.state) { _, state in
            if state != .running { iosImageSize = nil }
        }
    }

    private var duoHingeControlBar: some View {
        let activePreset = DuoPosePreset.matching(angle: runtime.duoHingeAngle)
        return HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(DuoPosePreset.allCases) { preset in
                    let isSelected = activePreset == preset
                    Button {
                        runtime.setDuoPose(preset)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: preset.systemImage)
                                .font(.system(size: 11, weight: .medium))
                            Text(preset.shortTitle)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            isSelected ? Theme.accent.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(isSelected ? Theme.accent : .primary)
                    .help(preset.title)
                }
            }

            Divider()
                .frame(height: 16)

            Slider(
                value: Binding(
                    get: { runtime.duoHingeAngle },
                    set: { runtime.setDuoHingeAngle($0, interactive: true) }
                ),
                in: 0...180,
                step: 1
            )
            .controlSize(.small)
            .frame(maxWidth: 220)
            .help("Hinge angle (\(Int(runtime.duoHingeAngle.rounded()))°)")

            Text("\(Int(runtime.duoHingeAngle.rounded()))°")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 14)
    }

    private func iphoneFrame(udid: String) -> some View {
        Group {
            if kind == .iphoneDuo {
                duoFrame(udid: udid)
            } else {
                standardIPhoneFrame(udid: udid)
            }
        }
    }

    @ViewBuilder
    private func simulatorScreen(udid: String) -> some View {
        let screen = SimulatorScreen(
            deviceUDID: udid,
            sharedFeed: try? runtime.frameFeed(),
            previewPaused: !previewVisible,
            showTouchIndicators: false,
            allowsDirectHitTesting: kind != .iphoneDuo && screenQuarterTurns == 0,
            onImageSize: {
                iosImageSize = $0
                let isInner = $0.width * $0.height >= 4_000_000
                if kind == .iphoneDuo {
                    runtime.syncInitialDuoDisplay(isInner: isInner)
                }
                screenError = nil
            },
            onSurfaceFrame: { runtime.flipRenderer?.receive(surface: $0) },
            onError: { screenError = $0.localizedDescription },
            onAttached: { runtime.screenView = $0 }
        )
        if kind == .iphoneDuo || screenQuarterTurns != 0 {
            screen
                .frame(width: nativeScreenSize.width * pointsPerPixel,
                       height: nativeScreenSize.height * pointsPerPixel)
                .rotationEffect(.degrees(Double(screenQuarterTurns * 90)))
                .frame(width: screenWidth, height: screenHeight)
        } else {
            screen.frame(width: screenWidth, height: screenHeight)
        }
    }

    private func standardIPhoneFrame(udid: String) -> some View {
        ZStack {
            if let chrome = DuoChromeAssets.iphone16Pro {
                Image(nsImage: chrome)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: screenQuarterTurns.isMultiple(of: 2) ? screenWidth + 22 * zoom : screenHeight + 22 * zoom,
                        height: screenQuarterTurns.isMultiple(of: 2) ? screenHeight + 22 * zoom : screenWidth + 22 * zoom
                    )
                    .rotationEffect(.degrees(Double(screenQuarterTurns * 90)))
                    .frame(width: screenWidth + 22 * zoom, height: screenHeight + 22 * zoom)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: 49 * zoom, style: .continuous)
                    .fill(Color(white: 0.12))
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .allowsHitTesting(false)
            }
            simulatorScreen(udid: udid)
                .clipShape(RoundedRectangle(cornerRadius: 39 * zoom, style: .continuous))
                .allowsHitTesting(screenQuarterTurns == 0)
            if screenQuarterTurns != 0 {
                DuoPointerSurface(runtime: runtime, screenID: 1,
                                  quarterTurns: screenQuarterTurns)
                    .frame(width: screenWidth, height: screenHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 39 * zoom, style: .continuous))
            }
        }
        .frame(width: screenWidth + 22 * zoom, height: screenHeight + 22 * zoom)
    }

    private var duoScreenShape: UnevenRoundedRectangle {
        let outer = duoDisplay == .outer
        let small: CGFloat = 5 * duoChromeScale
        let large: CGFloat = 57 * duoChromeScale
        let seamAtTop = screenQuarterTurns == 1
        let seamAtRight = screenQuarterTurns == 2
        let seamAtBottom = screenQuarterTurns == 3
        return UnevenRoundedRectangle(
            topLeadingRadius: outer && (screenQuarterTurns == 0 || seamAtTop) ? small : large,
            bottomLeadingRadius: outer && (screenQuarterTurns == 0 || seamAtBottom) ? small : large,
            bottomTrailingRadius: outer && (seamAtRight || seamAtBottom) ? small : large,
            topTrailingRadius: outer && (seamAtTop || seamAtRight) ? small : large,
            style: .continuous)
    }

    private func duoFrame(udid: String) -> some View {
        ZStack {
            duoChrome
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                .allowsHitTesting(false)
            simulatorScreen(udid: udid)
                .clipShape(duoScreenShape)
                .allowsHitTesting(false)
                .offset(outerScreenOffset)
        }
        .frame(width: shellWidth, height: shellHeight)
    }

    private var outerScreenOffset: CGSize {
        guard duoDisplay == .outer else { return .zero }
        let offset = 2 * duoChromeScale
        switch screenQuarterTurns {
        case 1: return CGSize(width: 0, height: offset)
        case 2: return CGSize(width: -offset, height: 0)
        case 3: return CGSize(width: 0, height: -offset)
        default: return CGSize(width: offset, height: 0)
        }
    }

    @ViewBuilder
    private var duoChrome: some View {
        let image = duoDisplay == .outer ? DuoChromeAssets.outer : DuoChromeAssets.inner
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(
                    width: screenQuarterTurns.isMultiple(of: 2) ? shellWidth : shellHeight,
                    height: screenQuarterTurns.isMultiple(of: 2) ? shellHeight : shellWidth
                )
                .rotationEffect(.degrees(Double(screenQuarterTurns * 90)))
                .frame(width: shellWidth, height: shellHeight)
        } else {
            duoScreenShape
                .fill(Color(white: 0.10))
                .frame(width: shellWidth, height: shellHeight)
        }
    }
}

/// The Simulator's own Duo chrome is installed with Xcode's DeviceKit. Refer to
/// it in place instead of embedding a copied approximation in SimLab.
enum DuoChromeAssets {
    private static let root = "/Library/Developer/DeviceKit/Chrome"

    private static func load(_ id: Int) -> NSImage? {
        if let url = Bundle.main.url(forResource: "phone\(id)", withExtension: "pdf", subdirectory: "DeviceChrome"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(contentsOfFile: "\(root)/phone\(id).devicechrome/Contents/Resources/PhoneComposite.pdf")
    }

    static let iphone16Pro = load(12)
    static let outer = load(15)
    static let inner = load(14)
}
