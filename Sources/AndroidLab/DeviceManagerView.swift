import SwiftUI
import AppKit

struct DeviceManagerView: View {
    let device: AvdDevice
    @ObservedObject var runtime: DeviceRuntime
    @EnvironmentObject private var model: AppModel
    @State private var showDelete = false
    @State private var showInspector = false
    @State private var windowVisible = true
    @State private var inspectorTab: InspectorTab = .info

    private enum InspectorTab: String, CaseIterable {
        case info = "Info"
        case log = "Session Log"
    }

    private var isLive: Bool { runtime.state.isLive }
    private var androidVersion: String {
        device.api.replacingOccurrences(of: "android-", with: "Android ")
    }

    var body: some View {
        workspace
            .environment(\.simulatorPreviewPaused, !windowVisible)
            .background(WindowPreviewVisibility(visible: $windowVisible))
            .navigationTitle(device.displayName)
            .navigationSubtitle("\(androidVersion) Emulator")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if isLive {
                        Button { model.stopDevice(device) } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .help("Stop emulator")
                    } else {
                        Button(action: start) {
                            Label("Start", systemImage: "play.fill")
                        }
                        .disabled(runtime.state.isBusy || !model.settings.isUsable)
                        .help("Start emulator")
                    }

                    actionsMenu

                    Button { toggleInspector(.log) } label: {
                        Label("Session Log", systemImage: "doc.text")
                    }
                    .help("Show session log")
                    .tint(showInspector && inspectorTab == .log ? Theme.accent : nil)

                    Button { toggleInspector(.info) } label: {
                        Label("Device Info", systemImage: "info.circle")
                    }
                    .help("Show device information")
                    .tint(showInspector && inspectorTab == .info ? Theme.accent : nil)
                }
            }
            .inspector(isPresented: $showInspector) {
                inspector
                    .inspectorColumnWidth(min: 260, ideal: 296, max: 380)
            }
            .alert("Delete \(device.displayName)?", isPresented: $showDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { model.deleteDevice(device) }
            } message: {
                Text("The AVD and its user data will be removed from disk.")
            }
    }

    private var workspace: some View {
        ZStack {
            Theme.stage
            DeviceWorkspaceView(deviceID: device.id, runtime: runtime)
                .environmentObject(model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Theme.statusColor(runtime.state)).frame(width: 6, height: 6)
                Text(runtime.state.label)
                Spacer()
                Text("\(device.width) × \(device.height)")
                Text("·")
                Text(device.profile?.name ?? "Android Emulator")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.background.opacity(0.7))
        }
    }

    private var actionsMenu: some View {
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
                    "\(model.settings.adb) -s \(runtime.serial ?? "emulator-5554") shell", forType: .string
                )
                model.toast = "ADB command copied."
            }
            Divider()
            Button("Delete…", role: .destructive) { showDelete = true }
        } label: {
            Label("More Actions", systemImage: "ellipsis")
        }
        .help("More device actions")
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Inspector", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button { showInspector = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close inspector")
                .accessibilityLabel("Close inspector")
            }
            .padding(14)
            Divider()
            if inspectorTab == .info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.displayName).font(.system(size: 16, weight: .semibold))
                            Text("\(androidVersion) Emulator")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        informationGroup("Device") {
                            infoRow("Model", device.profile?.name ?? device.displayName)
                            infoRow("Display", "\(device.width) × \(device.height)")
                            infoRow("Density", "\(device.density) dpi")
                            infoRow("Memory", "\(max(1, device.ramMB / 1024)) GB")
                            infoRow("Storage", "\(max(1, device.storageGB)) GB")
                        }
                        informationGroup("System") {
                            infoRow("Android", device.api.replacingOccurrences(of: "android-", with: "API "))
                            infoRow("Image", device.tag.isEmpty ? device.imagePath : device.tag)
                            infoRow("Status", runtime.state.label)
                        }
                        informationGroup("Connection") {
                            infoRow("Serial", runtime.serial ?? "Not connected", monospaced: true)
                            infoRow("gRPC port", runtime.grpcPort.map(String.init) ?? "—", monospaced: true)
                        }
                        Button("Show AVD in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.path)])
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                logInspector
            }
        }
        .background(Theme.background)
    }

    private func informationGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    private func infoRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value)
                .font(monospaced ? Theme.mono : .system(size: 11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
    }

    private var logInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session log").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show log in Finder")
                .accessibilityLabel("Show log in Finder")
            }
            ScrollView([.horizontal, .vertical]) {
                Text(runtime.bootLog.isEmpty ? "No log output yet.\nStart the emulator to view its session log." : runtime.bootLog)
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
    }

    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AndroidLab/\(device.id).log")
    }

    private func toggleInspector(_ tab: InspectorTab) {
        if showInspector && inspectorTab == tab {
            showInspector = false
        } else {
            inspectorTab = tab
            showInspector = true
        }
    }

    private func start() {
        model.startDevice(device)
    }
}
