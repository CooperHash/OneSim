import SwiftUI

struct AppsView: View {
    var deviceID: String? = nil
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [String] {
        guard !query.isEmpty else { return model.apps }
        return model.apps.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installed Apps")
                        .font(.system(size: 17, weight: .semibold))
                    Text(model.appsDeviceName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let deviceID {
                        Task { await model.reloadApps(deviceID: deviceID) }
                    } else {
                        model.loadApps()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 30, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text("No third-party apps found.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Install an APK…") {
                        dismiss()
                        if let deviceID {
                            model.installAPK(deviceID: deviceID)
                        } else {
                            model.installAPK()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, id: \.self) { package in
                    Button {
                        if let deviceID {
                            model.launchApp(deviceID: deviceID, package: package)
                        } else {
                            model.launchApp(package)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "app.dashed")
                                .foregroundStyle(Theme.accent)
                            Text(package)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "play.circle")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                Text("\(filtered.count) apps")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 460, height: 540)
    }
}
