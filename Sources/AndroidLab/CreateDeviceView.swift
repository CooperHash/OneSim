import SwiftUI

struct CreateDeviceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Pixel_10_Pro"
    @State private var profileID = "multisim"
    @State private var selectedAndroidID = ""
    @State private var imageID = ""
    @State private var ramGB = 8
    @State private var storageGB = 4
    @State private var hasEditedName = false

    private var selectedProfile: DeviceProfile {
        Profiles.all.first { $0.id == profileID } ?? Profiles.all[0]
    }

    private var availableImages: [SystemImage] {
        model.images.filter { $0.abi == "arm64-v8a" }
    }

    private var selectedImage: SystemImage? {
        availableImages.first { $0.id == imageID }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        selectedImage != nil &&
        !model.isCreating &&
        model.settings.isUsable
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profileID == "multisim" ? "New MultiSim" : "New Android Device")
                        .font(.system(size: 18, weight: .semibold))
                    Text(profileID == "multisim"
                         ? "Run Android, iPhone 16 Pro and iPhone Duo in one workspace."
                         : "Pick a hardware profile and an installed system image.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                profileList
                    .frame(width: 280)
                Divider()
                form
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 760, height: 560)
        .onAppear {
            if model.createDeviceForWorkspaceID != nil { profileID = "pixel-10-pro" }
            selectedAndroidID = model.selectedDevice?.id ?? model.devices.first?.id ?? ""
            if imageID.isEmpty { imageID = availableImages.first?.id ?? "" }
            if !hasEditedName { name = selectedProfile.name.replacingOccurrences(of: " ", with: "_") }
            if availableImages.isEmpty { ramGB = 8 }
        }
    }

    private var profileList: some View {
        List(selection: $profileID) {
            Section("Combined") {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MultiSim").font(.system(size: 12, weight: .semibold))
                        Text("Android + iPhone 16 Pro + iPhone Duo")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                .tag("multisim")
            }
            ForEach(Profiles.categories, id: \.0) { category in
                let items = Profiles.all.filter { $0.category == category.0 }
                if !items.isEmpty {
                    Section(category.1) {
                        ForEach(items) { profile in
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: profile))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(profile.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            .tag(profile.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: profileID) { _, newValue in
            if !hasEditedName, let profile = Profiles.all.first(where: { $0.id == newValue }) {
                name = profile.name.replacingOccurrences(of: " ", with: "_")
            }
        }
    }

    private var form: some View {
        Group {
            if profileID == "multisim" {
                multiSimForm
            } else {
                androidForm
            }
        }
    }

    private var multiSimForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Add simulators whenever you need", systemImage: "rectangle.3.group")
                .font(.system(size: 15, weight: .semibold))
            Text("Start with Android, iPhone 16 Pro and iPhone Duo. Use ＋ in the workspace to add more Android devices later. Window resizing never changes the device zoom.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Android emulator")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if model.devices.isEmpty {
                    Text("Create an Android emulator first.")
                        .font(.system(size: 12))
                    Button("Choose Android Profile") { profileID = "pixel-10-pro" }
                } else {
                    Picker("", selection: $selectedAndroidID) {
                        ForEach(model.devices) { device in
                            Text(device.displayName).tag(device.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("iOS simulator")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Label("iPhone 16 Pro + iPhone Duo · compatible installed iOS runtimes",
                      systemImage: "iphone.gen3")
                    .font(.system(size: 12))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))

            if let error = model.creationError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create MultiSim") { model.createMultiSim(androidID: selectedAndroidID) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedAndroidID.isEmpty)
            }
        }
        .padding(22)
    }

    private var androidForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("Pixel 10 Pro", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, _ in hasEditedName = true }
                Text("Letters, numbers, dots, dashes and underscores. Used as the AVD name.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("System image").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if availableImages.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("No arm64 system images installed.")
                            .font(.system(size: 12))
                        Spacer()
                        Button("Manage Images…") {
                            dismiss()
                            model.showImages = true
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Picker("", selection: $imageID) {
                        ForEach(availableImages) { image in
                            Text(image.displayName).tag(image.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RAM").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Stepper(value: $ramGB, in: 2...16, step: 2) {
                        Text("\(ramGB) GB").font(.system(size: 12, design: .monospaced))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Storage").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Stepper(value: $storageGB, in: 4...64, step: 4) {
                        Text("\(storageGB) GB").font(.system(size: 12, design: .monospaced))
                    }
                }
            }

            summary

            if let error = model.creationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.isCreating {
                    ProgressView().controlSize(.small)
                    Text("Creating…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("Create") {
                    if let image = selectedImage {
                        model.createDevice(
                            name: name, profile: selectedProfile, image: image,
                            ramMB: ramGB * 1024, storageGB: storageGB
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(22)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedProfile.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(selectedProfile.category.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                GridRow {
                    Text("Display").foregroundStyle(.secondary)
                    Text("\(selectedProfile.width) × \(selectedProfile.height)")
                }
                GridRow {
                    Text("Density").foregroundStyle(.secondary)
                    Text("\(selectedProfile.density) dpi")
                }
                GridRow {
                    Text("Android").foregroundStyle(.secondary)
                    Text(selectedImage?.apiLabel ?? "—")
                }
                GridRow {
                    Text("Image").foregroundStyle(.secondary)
                    Text(selectedImage?.friendlyTag ?? "—")
                }
                GridRow {
                    Text("ABI").foregroundStyle(.secondary)
                    Text(selectedImage?.abi ?? "—")
                }
                GridRow {
                    Text("Free disk").foregroundStyle(.secondary)
                    Text(String(format: "%.1f GB", AndroidRepository.freeDiskGB()))
                }
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.06)))
    }

    private func icon(for profile: DeviceProfile) -> String {
        switch profile.category {
        case "tablet": return "ipad.gen2"
        case "watch": return "applewatch"
        case "tv": return "tv"
        case "foldable": return "iphone.gen3.radiowaves.left.and.right"
        default: return "iphone.gen3"
        }
    }
}
