import SwiftUI
import UniformTypeIdentifiers

struct XcodeToolbar: View {
    @ObservedObject var xcode: XcodeManager
    @EnvironmentObject private var model: AppModel
    @State private var showingManager = false

    var body: some View {
        Button(xcode.active.map { "Xcode \($0.version)" } ?? "Xcode") { showingManager = true }
            .help(xcode.active?.label ?? "Install or select an Xcode version")
            .disabled(model.isSettingUp)
            .sheet(isPresented: $showingManager) { XcodeManagerView(xcode: xcode) }
    }
}

struct XcodeManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var xcode: XcodeManager
    @State private var filter = ""
    @State private var selection: InstalledXcode?
    @State private var showSwitch = false
    @State private var chooseXcode = false

    private var available: [XcodeRelease] {
        let installed = Set(xcode.installed.map(\.build))
        return xcode.releases.filter {
            !installed.contains($0.id) &&
                (filter.isEmpty || $0.argument.localizedCaseInsensitiveContains(filter) ||
                    $0.id.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Xcode Versions").font(.title2.bold())
            if !xcode.status.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(xcode.status)
                }
            }
            if let error = xcode.error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
            TextField("Filter available versions", text: $filter)
                .textFieldStyle(.roundedBorder)
            List {
                Section("Installed") {
                    ForEach(xcode.installed) { option in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                Text(option.bundle.path).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if option == xcode.active {
                                Label("Current", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                            } else {
                                Button("Use") { selection = option; showSwitch = true }
                            }
                        }
                    }
                    if xcode.installed.isEmpty { Text("No Xcode installation found.").foregroundStyle(.secondary) }
                }
                Section("Downloads") {
                    if xcode.loadingCatalog { ProgressView().controlSize(.small) }
                    ForEach(available) { release in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Xcode \(release.argument)")
                                if let requires = release.requires {
                                    Text("\(release.id) · macOS \(requires) or newer")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Download") { Task { await xcode.install(release) } }
                                .disabled(!release.canInstall)
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .disabled(xcode.busy)
            HStack {
                Button("Refresh") { Task { await xcode.refresh(); await xcode.loadCatalog() } }
                Button("Choose Xcode App…") { chooseXcode = true }
                if UserDefaults.standard.string(forKey: XcodeToolchain.selectionKey) != nil {
                    Button("Use System Xcode") { selection = nil; showSwitch = true }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .disabled(xcode.busy)
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .interactiveDismissDisabled(xcode.busy)
        .task { await xcode.refresh(); await xcode.loadCatalog() }
        .fileImporter(isPresented: $chooseXcode, allowedContentTypes: [.applicationBundle]) { result in
            switch result {
            case .success(let file):
                guard let option = InstalledXcode(bundle: file) else {
                    xcode.error = "Select a complete Xcode.app installation."
                    return
                }
                selection = option
                showSwitch = true
            case .failure(let error): xcode.error = error.localizedDescription
            }
        }
        .confirmationDialog("Restart SimLab to change Xcode?", isPresented: $showSwitch, titleVisibility: .visible) {
            Button("Use Xcode and Restart") { Task { await xcode.use(selection) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selection?.label ?? "Use the Mac’s active Xcode installation.")
        }
    }
}
