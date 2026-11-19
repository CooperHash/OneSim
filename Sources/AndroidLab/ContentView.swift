import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 246, max: 320)
        } detail: {
            Group {
                if let device = model.selectedDevice, let runtime = model.runtimes[device.id] {
                    if let workspace = model.selectedWorkspace {
                        MultiSimWorkspaceView(workspace: workspace, web: model.web)
                    } else {
                        DeviceManagerView(device: device, runtime: runtime)
                    }
                } else {
                    EmptyStateView()
                }
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    XcodeToolbar(xcode: model.xcode)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $model.showDependencySetup) {
            DependencySetupView().environmentObject(model)
        }
        .sheet(isPresented: $model.showCreate, onDismiss: {
            model.createDeviceForWorkspaceID = nil
        }) {
            CreateDeviceView().environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
        .sheet(isPresented: $model.showImages) {
            ImagesView().environmentObject(model)
        }
        .sheet(isPresented: $model.showApps) {
            AppsView().environmentObject(model)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.82), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .padding(.bottom, 18)
                    .onTapGesture { model.toast = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No device selected")
                .font(.system(size: 17, weight: .semibold))
            Text("Create a MultiSim workspace or pick an emulator from the sidebar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("New Device") { model.showCreate = true }
                    .buttonStyle(.borderedProminent)
                Button("Android SDK…") { model.showSettings = true }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.stage)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    private var visibleDevices: [AvdDevice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.devices }
        return model.devices.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.subtitle.localizedCaseInsensitiveContains(query) ||
            ($0.profile?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        List(selection: $model.selection) {
            if !model.multiSimWorkspaces.isEmpty {
                Section("MultiSim") {
                    ForEach(model.multiSimWorkspaces) { workspace in
                        if let device = model.devices.first(where: { $0.id == workspace.androidID }) {
                            HStack(spacing: 10) {
                                Image(systemName: "rectangle.3.group")
                                    .font(.system(size: 21, weight: .light))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("MultiSim").font(.system(size: 13, weight: .semibold))
                                    Text("\(device.displayName) + \(workspace.members.count - 1) simulators")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 5)
                            .tag("multisim:\(workspace.androidID)")
                            .contextMenu {
                                Button("Start All") { model.startMultiSim(androidID: workspace.androidID) }
                                Button("Stop All") { model.stopMultiSim(androidID: workspace.androidID) }
                                Button("Remove MultiSim") { model.removeMultiSim(androidID: workspace.androidID) }
                            }
                        }
                    }
                }
            }
            if !model.settings.isUsable {
                Section {
                    Button {
                        model.showSettings = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Android SDK not found")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Click to configure paths")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }

            let live = visibleDevices.filter { $0.state.isLive }
            let stopped = visibleDevices.filter { !$0.state.isLive }

            if !live.isEmpty {
                Section("Running") {
                    ForEach(live) { device in
                        if let runtime = model.runtimes[device.id] {
                            DeviceRow(device: device, runtime: runtime)
                                .tag(device.id)
                        }
                    }
                }
            }

            Section(live.isEmpty ? "Android Emulators" : "Available") {
                if stopped.isEmpty && live.isEmpty {
                    Text(searchText.isEmpty ? "No emulators yet" : "No matching devices")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(stopped) { device in
                    if let runtime = model.runtimes[device.id] {
                        DeviceRow(device: device, runtime: runtime)
                            .tag(device.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SimLab")
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search devices", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search devices")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    model.showCreate = true
                } label: {
                    Label("New", systemImage: "plus").fixedSize()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    model.showImages = true
                } label: {
                    Image(systemName: "square.stack.3d.up")
                }
                .help("System images")

                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")

                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

struct DeviceRow: View {
    let device: AvdDevice
    @ObservedObject var runtime: DeviceRuntime
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Theme.deviceIcon(device))
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(device.api.replacingOccurrences(of: "android-", with: "Android "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if runtime.state != .stopped {
                        Circle().fill(Theme.statusColor(runtime.state)).frame(width: 5, height: 5)
                    }
                    Text(runtime.state == .stopped ? "Emulator" : runtime.state.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            if runtime.state == .stopped || runtime.state == .error {
                Button("Start") {
                    model.selection = device.id
                    model.startDevice(device)
                }
            } else {
                Button("Stop") { model.stopDevice(device) }
                Button("Cold Boot") { model.coldBootDevice(device) }
                Button("Wipe Data…") { model.wipeDevice(device) }
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.path)])
            }
            Divider()
            Button("Delete…", role: .destructive) { model.deleteDevice(device) }
        }
    }
}
