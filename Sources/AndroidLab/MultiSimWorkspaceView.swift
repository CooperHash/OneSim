import AppKit
import SwiftUI
import SimKit

/// A workspace of independently sized devices. Narrow windows scroll instead of scaling screens.
struct MultiSimWorkspaceView: View {
    let workspace: MultiSimWorkspace
    @EnvironmentObject private var model: AppModel
    @State private var focusedMemberID: String?
    @StateObject private var resources = SimulatorResourceMonitor()

    private var focusedIndex: Int {
        workspace.members.firstIndex { $0.id == focusedMemberID } ?? 0
    }

    private var availableAndroids: [AvdDevice] {
        model.devices.filter { !workspace.members.contains(.android($0.id)) }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Button {
                            moveFocus(by: -1, using: scrollProxy)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(focusedIndex == 0)
                        .help("Previous simulator")

                        ScrollViewReader { chipProxy in
                            ScrollView(.horizontal, showsIndicators: true) {
                                HStack(spacing: 6) {
                                    ForEach(workspace.members) { member in
                                        Button(memberName(member)) {
                                            focus(member, using: scrollProxy)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .id("chip:\(member.id)")
                                    }
                                }
                            }
                            .onChange(of: focusedMemberID) { _, newID in
                                guard let newID else { return }
                                withAnimation { chipProxy.scrollTo("chip:\(newID)", anchor: .center) }
                            }
                        }
                        .frame(maxWidth: .infinity)

                        Button {
                            moveFocus(by: 1, using: scrollProxy)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(focusedIndex >= workspace.members.count - 1)
                        .help("Next simulator")

                        Text("\(workspace.members.count) simulators")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24).onEnded { value in
                            let horizontal = value.translation.width
                            guard abs(horizontal) > 40,
                                  abs(horizontal) > abs(value.translation.height) else { return }
                            moveFocus(by: horizontal < 0 ? 1 : -1, using: scrollProxy)
                        }
                    )
                    Divider()

                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        HStack(alignment: .top, spacing: 20) {
                            ForEach(workspace.members) { member in
                                memberColumn(member)
                                    .id(member.id)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .frame(minWidth: geometry.size.width,
                               minHeight: max(0, geometry.size.height - 43),
                               alignment: .center)
                    }
                    .onChange(of: workspace.members) { oldMembers, newMembers in
                        if !newMembers.contains(where: { $0.id == focusedMemberID }) {
                            focusedMemberID = newMembers.first?.id
                        }
                        guard let last = newMembers.last,
                              !oldMembers.contains(last) else { return }
                        focusedMemberID = last.id
                        withAnimation { scrollProxy.scrollTo(last.id, anchor: .trailing) }
                    }
                    .onChange(of: workspace.androidID) { _, _ in
                        focusedMemberID = workspace.members.first?.id
                    }
                }
                .background(Theme.stage)
            }
        }
        .navigationTitle("MultiSim")
        .navigationSubtitle("\(workspace.members.count) simulators · \(workspace.androidID)")
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

                Button {
                    model.startMultiSim(androidID: workspace.androidID)
                } label: {
                    Label("Start All", systemImage: "play.fill")
                }
                Button {
                    model.stopMultiSim(androidID: workspace.androidID)
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
            }
        }
        .task(id: workspace.androidID) {
            focusedMemberID = workspace.members.first?.id
            model.startMultiSim(androidID: workspace.androidID)
        }
        .task(id: workspace.members) {
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

    private func focus(_ member: MultiSimMember, using proxy: ScrollViewProxy) {
        focusedMemberID = member.id
        withAnimation { proxy.scrollTo(member.id, anchor: .center) }
    }

    private func moveFocus(by offset: Int, using proxy: ScrollViewProxy) {
        let index = focusedIndex + offset
        guard workspace.members.indices.contains(index) else { return }
        focus(workspace.members[index], using: proxy)
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
                IOSSimulatorColumn(kind: kind, runtime: runtime,
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
    let resourceUsage: SimulatorResourceUsage?
    let onRemove: () -> Void
    @State private var screenError: String?
    @State private var iosImageSize: CGSize?

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

    private var screenWidth: CGFloat { displayScreenSize.width * Self.pointsPerNativePixel }
    private var screenHeight: CGFloat { displayScreenSize.height * Self.pointsPerNativePixel }

    // DeviceKit's chrome art is in points at the simulator's 3x pixel scale.
    private var duoChromeScale: CGFloat { 3 * Self.pointsPerNativePixel }

    private var shellWidth: CGFloat {
        guard kind == .iphoneDuo else { return screenWidth + 22 }
        let horizontalPadding: CGFloat = duoDisplay == .outer ? 48 : 34
        let verticalPadding: CGFloat = duoDisplay == .outer ? 28 : 34
        return screenWidth + (isLandscape ? verticalPadding : horizontalPadding) * duoChromeScale
    }

    private var shellHeight: CGFloat {
        guard kind == .iphoneDuo else { return screenHeight + 22 }
        let horizontalPadding: CGFloat = duoDisplay == .outer ? 48 : 34
        let verticalPadding: CGFloat = duoDisplay == .outer ? 28 : 34
        return screenHeight + (isLandscape ? horizontalPadding : verticalPadding) * duoChromeScale
    }

    private var duoUnfoldedShellSize: CGSize {
        let padding = 34 * duoChromeScale
        let portraitOrient = runtime.orientation.clockwiseQuarterTurns.isMultiple(of: 2)
        let w = (portraitOrient ? 2853 : 2007) * Self.pointsPerNativePixel + padding
        let h = (portraitOrient ? 2007 : 2853) * Self.pointsPerNativePixel + padding
        return CGSize(width: w, height: h)
    }

    private var stageHeight: CGFloat {
        if kind == .iphoneDuo {
            return max(720, shellHeight, duoUnfoldedShellSize.height + 28)
        }
        return max(704, shellHeight)
    }
    private var panelWidth: CGFloat {
        if kind == .iphoneDuo {
            return max(shellWidth + 30, duoUnfoldedShellSize.width + 30)
        }
        return screenWidth + 78
    }
    private var panelHeight: CGFloat {
        stageHeight + (kind == .iphoneDuo ? 92 : 56)
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
                .frame(width: panelWidth, height: panelHeight)
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
        VStack(spacing: 0) {
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
                    DuoFlipCanvas(display: duoDisplay, visible: runtime.is3DPoseActive) { runtime.flipRenderer = $0 }
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
            .frame(height: stageHeight)

            if kind == .iphoneDuo {
                Divider()
                duoHingeControlBar
                    .frame(height: 36)
                    .background(.bar)
                    .disabled(runtime.state != .running || runtime.isRotating)
            }

            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 4) {
                if kind == .iphoneDuo {
                    let isFolded = duoDisplay == .outer
                    VerticalToolButton(
                        icon: runtime.isChangingHinge ? "hourglass" : "rectangle.split.2x1",
                        title: runtime.isChangingHinge ? "Moving…" : (isFolded ? "Unfold" : "Fold")
                    ) {
                        runtime.setDuoFolded(!isFolded)
                    }
                    .disabled(runtime.isChangingHinge || runtime.isRotating)
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
              .frame(maxWidth: .infinity)
            }
            .frame(height: 55)
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
                .frame(width: nativeScreenSize.width * Self.pointsPerNativePixel,
                       height: nativeScreenSize.height * Self.pointsPerNativePixel)
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
                        width: screenQuarterTurns.isMultiple(of: 2) ? screenWidth + 22 : screenHeight + 22,
                        height: screenQuarterTurns.isMultiple(of: 2) ? screenHeight + 22 : screenWidth + 22
                    )
                    .rotationEffect(.degrees(Double(screenQuarterTurns * 90)))
                    .frame(width: screenWidth + 22, height: screenHeight + 22)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: 49, style: .continuous)
                    .fill(Color(white: 0.12))
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .allowsHitTesting(false)
            }
            simulatorScreen(udid: udid)
                .clipShape(RoundedRectangle(cornerRadius: 39, style: .continuous))
                .allowsHitTesting(screenQuarterTurns == 0)
            if screenQuarterTurns != 0 {
                DuoPointerSurface(runtime: runtime, screenID: 1,
                                  quarterTurns: screenQuarterTurns)
                    .frame(width: screenWidth, height: screenHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 39, style: .continuous))
            }
        }
        .frame(width: screenWidth + 22, height: screenHeight + 22)
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
private enum DuoChromeAssets {
    private static let root = "/Library/Developer/DeviceKit/Chrome"
    static let iphone16Pro = NSImage(contentsOfFile:
        "\(root)/phone12.devicechrome/Contents/Resources/PhoneComposite.pdf")
    static let outer = NSImage(contentsOfFile:
        "\(root)/phone15.devicechrome/Contents/Resources/PhoneComposite.pdf")
    static let inner = NSImage(contentsOfFile:
        "\(root)/phone14.devicechrome/Contents/Resources/PhoneComposite.pdf")
}
