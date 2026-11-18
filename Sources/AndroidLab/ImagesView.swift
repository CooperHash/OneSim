import SwiftUI

struct ImagesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var recommended: [SystemImage] {
        [
            SystemImage(id: "system-images;android-36;google_apis_playstore;arm64-v8a", api: "android-36", tag: "google_apis_playstore", abi: "arm64-v8a"),
            SystemImage(id: "system-images;android-36;google_apis;arm64-v8a", api: "android-36", tag: "google_apis", abi: "arm64-v8a"),
            SystemImage(id: "system-images;android-35;google_apis_playstore;arm64-v8a", api: "android-35", tag: "google_apis_playstore", abi: "arm64-v8a"),
            SystemImage(id: "system-images;android-35;google_apis;arm64-v8a", api: "android-35", tag: "google_apis", abi: "arm64-v8a"),
            SystemImage(id: "system-images;android-34;google_apis;arm64-v8a", api: "android-34", tag: "google_apis", abi: "arm64-v8a"),
            SystemImage(id: "system-images;android-34;aosp_atd;arm64-v8a", api: "android-34", tag: "aosp_atd", abi: "arm64-v8a"),
        ]
    }

    private var installedIDs: Set<String> {
        Set(model.images.map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Images")
                        .font(.system(size: 18, weight: .semibold))
                    Text(model.settings.isBundledSDK
                         ? "Bundled images are available offline. Choose an external SDK in Settings to install more."
                         : "Android 14–16 arm64 images for Apple Silicon. Downloads are several GB.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("INSTALLED")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if model.images.isEmpty {
                        Text("No system images yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.images) { image in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.system(size: 11))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(image.apiLabel)
                                                .font(.system(size: 12, weight: .medium))
                                            Text("\(image.friendlyTag) · \(image.abi)")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(8)
                                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(width: 300, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("AVAILABLE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(recommended) { image in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(image.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                Text(image.id)
                                    .font(Theme.mono)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if installedIDs.contains(image.id) {
                                Text("Installed")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.green)
                            } else {
                                Button("Install") {
                                    model.install(image: image)
                                }
                                .disabled(model.isDownloading || model.settings.isBundledSDK)
                            }
                        }
                        .padding(10)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    }

                    if model.isDownloading || !model.installLog.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                if model.isDownloading { ProgressView().controlSize(.small) }
                                Text(model.isDownloading ? "Installing…" : "Last install")
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                            }
                            ScrollView {
                                Text(model.installLog)
                                    .font(Theme.mono)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 110)
                        }
                        .padding(10)
                        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Spacer()
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text("Images are downloaded from Google. SimLab does not redistribute them.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 820, height: 620)
    }
}
