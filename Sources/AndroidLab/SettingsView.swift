import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ToolPaths.empty
    @State private var versions = "Checking…"
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Android SDK")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Use the setup assistant or choose an existing Android SDK. Command-line tools are optional.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Auto-detect") {
                    draft = ToolPaths.detect()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    group("SDK") {
                        pathRow("SDK root", text: $draft.sdk, directory: true)
                        pathRow("AVD home", text: $draft.avdHome, directory: true)
                    }
                    group("Tools") {
                        pathRow("adb", text: $draft.adb, directory: false)
                        pathRow("emulator", text: $draft.emulator, directory: false)
                        pathRow("avdmanager", text: $draft.avdmanager, directory: false)
                        pathRow("sdkmanager", text: $draft.sdkmanager, directory: false)
                    }
                    group("Status") {
                        VStack(alignment: .leading, spacing: 8) {
                            if draft.isBundledSDK {
                                Label("Using the bundled SDK", systemImage: "shippingbox.fill")
                                    .font(.system(size: 12))
                            }
                            if draft.missing.isEmpty {
                                Label("All required tools found", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 12))
                            } else {
                                Label("Missing: \(draft.missing.joined(separator: ", "))",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 12))
                            }
                            Text(versions)
                                .font(Theme.mono)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                if !model.settings.isUsable {
                    Text("SimLab needs adb and emulator to run Android devices.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.settings = draft
                    model.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 780, height: 580)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = model.settings
            Task {
                versions = await draft.versionSummary()
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.06)))
    }

    private func pathRow(_ title: String, text: Binding<String>, directory: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = !directory
                panel.canChooseDirectories = directory
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = directory
                if panel.runModal() == .OK, let url = panel.url {
                    text.wrappedValue = url.path
                }
            }
        }
    }
}
