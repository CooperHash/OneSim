import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AvdDevice] = []
    @Published var images: [SystemImage] = []
    @Published var runtimes: [String: DeviceRuntime] = [:]
    @Published var settings: ToolPaths
    @Published var selection: String? {
        didSet { UserDefaults.standard.set(selection, forKey: "SimLab.selection") }
    }
    @Published var toast: String?
    @Published var isRefreshing = false
    @Published var isCreating = false
    @Published var isInstalling = false
    @Published var creationError: String?
    @Published var showCreate = false
    @Published var showSettings = false
    @Published var showImages = false
    @Published var showApps = false
    @Published var apps: [String] = []
    @Published var appsDeviceName = ""
    @Published var installLog = ""
    @Published var isDownloading = false
    @Published private(set) var multiSimWorkspaces: [MultiSimWorkspace] = []
    let iosRuntimes = Dictionary(uniqueKeysWithValues: IOSSimulatorKind.allCases.map {
        ($0, IOSSimulatorRuntime(kind: $0))
    })
    @Published var createDeviceForWorkspaceID: String?
    @Published var showDependencySetup = false
    @Published private(set) var dependencyReport: DependencySetup.Report?
    @Published private(set) var setupProgress: [String: Int64] = [:]
    @Published private(set) var setupMessage = ""
    @Published private(set) var isSettingUp = false
    let web = WebMultiSimController()

    private var monitorTask: Task<Void, Never>?
    private var hasStarted = false
    private var isCreatingDefaultWorkspace = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "SimLab.multiSimWorkspaces"),
           let saved = try? JSONDecoder().decode([MultiSimWorkspace].self, from: data) {
            multiSimWorkspaces = saved
        } else {
            // Existing TwoSim workspaces gain Duo once, then use the new list format.
            let oldIDs = UserDefaults.standard.stringArray(forKey: "SimLab.twoSimAndroidIDs") ?? []
            let migrated = oldIDs.map(MultiSimWorkspace.initial)
            multiSimWorkspaces = migrated
            if let data = try? JSONEncoder().encode(migrated) {
                UserDefaults.standard.set(data, forKey: "SimLab.multiSimWorkspaces")
            }
        }
        let savedSelection = UserDefaults.standard.string(forKey: "SimLab.selection")
        selection = savedSelection?.hasPrefix("twosim:") == true
            ? "multisim:" + savedSelection!.dropFirst("twosim:".count)
            : savedSelection
        let saved = UserDefaults.standard.data(forKey: "AndroidLab.toolPaths")
            .flatMap { try? JSONDecoder().decode(ToolPaths.self, from: $0) }
        if ToolPaths.bundledSDKRoot != nil,
           !UserDefaults.standard.bool(forKey: "AndroidLab.externalSDKOverride") {
            settings = ToolPaths.detect()
        } else if let saved, saved.isUsable {
            settings = saved
        } else {
            settings = ToolPaths.detect()
        }
    }

    func boot() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            await refresh()
            await checkDependencies()
            startMonitoring()
        }
    }

    func checkDependencies(showIOSNotes: Bool = false) async {
        let report = await DependencySetup.scan(paths: settings)
        dependencyReport = report
        showDependencySetup = !report.isReady || (showIOSNotes && !report.iosNotes.isEmpty)
        if report.isReady {
            do {
                try await createDefaultWorkspaceIfNeeded()
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    func installMissingDependencies() {
        guard !isSettingUp, let report = dependencyReport, report.platformError == nil,
              !report.android.isEmpty else { return }
        isSettingUp = true
        setupProgress = [:]
        setupMessage = "Preparing downloads…"
        Task { [self] in
            defer { isSettingUp = false }
            do {
                try await installMissingAndroidPackages()
                await refresh()
                await checkDependencies()
            } catch {
                setupMessage = error.localizedDescription
            }
        }
    }

    private func installMissingAndroidPackages() async throws {
        let current = settings
        guard !DependencySetup.missingAndroidPackages(paths: current).isEmpty else { return }
        let fm = FileManager.default
        let sdk = URL(fileURLWithPath: current.sdk)
        let reuseSDK = !current.sdk.isEmpty && !current.isBundledSDK && fm.isWritableFile(atPath: sdk.path)
        let root = reuseSDK ? sdk : ToolPaths.managedSDKRoot
        let standardPaths = ToolPaths.atSDK(root.path, avdHome: current.avdHome)
        var installed = reuseSDK ? current : standardPaths
        if reuseSDK {
            if !fm.isExecutableFile(atPath: installed.adb) { installed.adb = standardPaths.adb }
            if !fm.isExecutableFile(atPath: installed.emulator) { installed.emulator = standardPaths.emulator }
        }
        let pending = DependencySetup.missingAndroidPackages(paths: installed)
        dependencyReport?.android = pending
        try await withThrowingTaskGroup(of: Void.self) { group in
            for package in pending {
                group.addTask { [weak self] in
                    try await DependencySetup.download(package, to: root) { [weak self] bytes, phase in
                        Task { @MainActor [weak self] in
                            guard let self, isSettingUp else { return }
                            setupProgress[package.id] = max(setupProgress[package.id, default: 0], bytes)
                            setupMessage = phase
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        settings = installed
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "AndroidLab.toolPaths")
        }
    }

    private func createDefaultWorkspaceIfNeeded() async throws {
        guard multiSimWorkspaces.isEmpty, !isCreatingDefaultWorkspace else { return }
        isCreatingDefaultWorkspace = true
        defer { isCreatingDefaultWorkspace = false }
        while isRefreshing { try await Task.sleep(for: .milliseconds(100)) }

        let name: String
        if let existing = AndroidRepository.preferredWorkspaceDevice(devices, paths: settings) {
            name = existing.id
        } else {
            let installedImages = AndroidRepository.listImages(paths: settings)
            guard let image = DependencySetup.defaultAndroidImage(from: installedImages) else {
                throw SetupError("No installed Android ARM64 system image is available to create the default device.")
            }
            guard let profile = Profiles.all.first(where: { $0.id == "pixel-10" }) else { return }
            let avdFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: settings.avdHome)) ?? [])
            let base = AndroidSlimClient.defaultAVD
            var candidate = base
            var suffix = 2
            while avdFiles.contains(candidate + ".ini") || avdFiles.contains(candidate + ".avd") {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            name = candidate
            _ = try await AndroidRepository.create(
                name: name, profile: profile, image: image,
                ramMB: 3_072, storageGB: 4, paths: settings
            )
            while isRefreshing { try await Task.sleep(for: .milliseconds(100)) }
            await refresh()
        }
        guard multiSimWorkspaces.isEmpty else { return }
        multiSimWorkspaces = [.initial(androidID: name)]
        saveMultiSimWorkspaces()
        selection = "multisim:\(name)"
    }

    deinit {
        monitorTask?.cancel()
    }

    var selectedDevice: AvdDevice? {
        guard let selection else { return nil }
        let id = selection.hasPrefix("multisim:")
            ? String(selection.dropFirst("multisim:".count)) : selection
        return devices.first { $0.id == id }
    }

    var selectedWorkspace: MultiSimWorkspace? {
        guard let id = selectedDevice?.id, isMultiSimSelection(selection) else { return nil }
        return multiSimWorkspaces.first { $0.androidID == id }
    }

    var selectedRuntime: DeviceRuntime? {
        guard let id = selectedDevice?.id else { return nil }
        return runtimes[id]
    }

    func isMultiSimSelection(_ selection: String?) -> Bool {
        selection?.hasPrefix("multisim:") == true
    }

    func createMultiSim(androidID: String) {
        guard let device = devices.first(where: { $0.id == androidID }) else {
            creationError = "Choose an Android emulator first."
            return
        }
        if !multiSimWorkspaces.contains(where: { $0.androidID == androidID }) {
            multiSimWorkspaces.append(.initial(androidID: androidID))
            saveMultiSimWorkspaces()
        }
        selection = "multisim:\(androidID)"
        showCreate = false
        startMultiSim(androidID: device.id)
    }

    func removeMultiSim(androidID: String) {
        multiSimWorkspaces.removeAll { $0.androidID == androidID }
        saveMultiSimWorkspaces()
        if selection == "multisim:\(androidID)" { selection = androidID }
    }

    func addToMultiSim(_ member: MultiSimMember, androidID: String) {
        guard let index = multiSimWorkspaces.firstIndex(where: { $0.androidID == androidID }) else { return }
        let updated = multiSimWorkspaces[index].adding(member)
        guard updated != multiSimWorkspaces[index] else { return }
        multiSimWorkspaces[index] = updated
        saveMultiSimWorkspaces()
        startMultiSimMember(member)
    }

    func removeFromMultiSim(_ member: MultiSimMember, androidID: String) {
        guard let index = multiSimWorkspaces.firstIndex(where: { $0.androidID == androidID }) else { return }
        multiSimWorkspaces[index] = multiSimWorkspaces[index].removing(member)
        saveMultiSimWorkspaces()
    }

    func startMultiSim(androidID: String) {
        guard let workspace = multiSimWorkspaces.first(where: { $0.androidID == androidID }) else { return }
        for member in workspace.members { startMultiSimMember(member) }
    }

    func stopMultiSim(androidID: String) {
        guard let workspace = multiSimWorkspaces.first(where: { $0.androidID == androidID }) else { return }
        for member in workspace.members {
            switch member {
            case .android(let id):
                if let device = devices.first(where: { $0.id == id }) { stopDevice(device) }
            case .ios(let kind): iosRuntimes[kind]?.stop()
            }
        }
    }

    private func startMultiSimMember(_ member: MultiSimMember) {
        switch member {
        case .android(let id):
            if let device = devices.first(where: { $0.id == id }),
               let runtime = runtimes[id], !runtime.state.isLive && !runtime.state.isBusy {
                startDevice(device)
            }
        case .ios(let kind): iosRuntimes[kind]?.start()
        }
    }

    private func saveMultiSimWorkspaces() {
        guard let data = try? JSONEncoder().encode(multiSimWorkspaces) else { return }
        UserDefaults.standard.set(data, forKey: "SimLab.multiSimWorkspaces")
    }

    func runtime(for id: String) -> DeviceRuntime? {
        runtimes[id]
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "AndroidLab.toolPaths")
        }
        UserDefaults.standard.set(!settings.isBundledSDK, forKey: "AndroidLab.externalSDKOverride")
        Task { await refresh() }
        toast = "Settings saved."
    }

    func detectSettings() {
        settings = ToolPaths.detect()
        saveSettings()
    }

    func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // SDK scans and synchronous adb discovery must never block UI/input.
        let paths = settings
        let snapshot = await Task.detached(priority: .utility) {
            (AndroidRepository.listImages(paths: paths),
             AndroidRepository.runningEndpoints(),
             Set(AndroidRepository.adbDevices(paths: paths)),
             AndroidRepository.listDevices(paths: paths))
        }.value
        let (newImages, endpoints, adbSerials, devicesSnapshot) = snapshot
        var updated = devicesSnapshot
        let validIDs = Set(updated.map(\.id))

        let staleIDs = runtimes.keys.filter { !validIDs.contains($0) }
        for id in staleIDs {
            runtimes[id]?.stop(paths: settings)
            runtimes[id] = nil
        }

        for index in updated.indices {
            let id = updated[index].id
            let runtime: DeviceRuntime
            if let existing = runtimes[id] {
                runtime = existing
            } else {
                let created = DeviceRuntime(avdName: id)
                runtimes[id] = created
                runtime = created
            }

            if let endpoint = endpoints[id] {
                runtime.attach(endpoint: endpoint, booted: adbSerials.contains(endpoint.serial), paths: settings)
                updated[index].state = runtime.state
                updated[index].serial = endpoint.serial
                updated[index].grpcPort = endpoint.grpcPort
                updated[index].grpcToken = endpoint.token
            } else {
                if runtime.state == .starting || runtime.state == .booting || runtime.state == .stopping {
                    // The app owns this emulator and it is still coming up or shutting down.
                } else if runtime.state == .running {
                    runtime.markStopped()
                }
                updated[index].state = runtime.state
                updated[index].serial = runtime.serial
            }
        }

        images = newImages
        devices = updated

        let oldSelection = selection
        let selectedID = oldSelection?.hasPrefix("multisim:") == true
            ? String(oldSelection!.dropFirst("multisim:".count)) : oldSelection
        if selectedID == nil || !updated.contains(where: { $0.id == selectedID }) {
            selection = updated.first(where: { $0.state.isLive })?.id ?? updated.first?.id
        }
        let existingIDs = Set(updated.map(\.id))
        let retainedWorkspaces = multiSimWorkspaces.compactMap { workspace -> MultiSimWorkspace? in
            guard existingIDs.contains(workspace.androidID) else { return nil }
            var copy = workspace
            copy.members.removeAll { member in
                if case .android(let id) = member { return !existingIDs.contains(id) }
                return false
            }
            return copy
        }
        if retainedWorkspaces != multiSimWorkspaces {
            multiSimWorkspaces = retainedWorkspaces
            saveMultiSimWorkspaces()
        }

        for device in updated where endpoints[device.id] != nil {
            runtimes[device.id]?.refreshBootState(paths: settings, isFoldable: device.isFoldable)
        }
        for runtime in iosRuntimes.values { await runtime.refreshBootState() }
    }

    // MARK: - Devices

    func createDevice(name: String, profile: DeviceProfile, image: SystemImage, ramMB: Int, storageGB: Int) {
        guard !isCreating else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            creationError = "Please enter a name."
            return
        }
        guard trimmed.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
            creationError = "Use letters, numbers, dots, dashes or underscores only."
            return
        }
        let freeGB = AndroidRepository.freeDiskGB()
        let neededGB = Double(storageGB) + 3.5
        guard freeGB >= neededGB else {
            creationError = String(format: "Not enough free disk space. About %.1f GB is needed, but only %.1f GB is available. Delete an old emulator or free up space first.", neededGB, freeGB)
            return
        }
        isCreating = true
        creationError = nil
        Task {
            do {
                let device = try await AndroidRepository.create(
                    name: trimmed, profile: profile, image: image,
                    ramMB: ramMB, storageGB: storageGB, paths: settings
                )
                await refresh()
                if let workspaceID = createDeviceForWorkspaceID,
                   multiSimWorkspaces.contains(where: { $0.androidID == workspaceID }) {
                    addToMultiSim(.android(device.id), androidID: workspaceID)
                    selection = "multisim:\(workspaceID)"
                } else {
                    selection = device.id
                }
                createDeviceForWorkspaceID = nil
                showCreate = false
                toast = "Created \(trimmed)."
            } catch {
                creationError = error.localizedDescription
            }
            isCreating = false
        }
    }

    func startDevice(_ device: AvdDevice, coldBoot: Bool = false, wipe: Bool = false) {
        guard let runtime = runtimes[device.id] else { return }
        runtime.start(device: device, paths: settings, coldBoot: coldBoot, wipeData: wipe)
    }

    func stopDevice(_ device: AvdDevice) {
        runtimes[device.id]?.stop(paths: settings)
    }

    func shutdown() {
        web.stop()
        for runtime in runtimes.values {
            runtime.closeStreamForShutdown()
        }
    }

    func toggleSelectedDevice() {
        guard let device = selectedDevice else { return }
        if isMultiSimSelection(selection) {
            let members = selectedWorkspace?.members ?? []
            let anyLive = members.contains { member in
                switch member {
                case .android(let id): return runtimes[id]?.state.isLive == true
                case .ios(let kind): return iosRuntimes[kind]?.state == .running
                }
            }
            if anyLive {
                stopMultiSim(androidID: device.id)
            } else {
                startMultiSim(androidID: device.id)
            }
            return
        }
        if device.state.isLive {
            stopDevice(device)
        } else {
            startDevice(device)
        }
    }

    func coldBootDevice(_ device: AvdDevice) {
        runtimes[device.id]?.coldBoot(device: device, paths: settings)
    }

    func wipeDevice(_ device: AvdDevice) {
        runtimes[device.id]?.wipe(device: device, paths: settings)
    }

    func deleteDevice(_ device: AvdDevice) {
        Task {
            runtimes[device.id]?.stop(paths: settings)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            do {
                try await AndroidRepository.delete(name: device.id, paths: settings)
                runtimes[device.id] = nil
                if selection == device.id { selection = nil }
                await refresh()
                toast = "Deleted \(device.displayName)."
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    // MARK: - Input

    func touch(deviceID: String, x: Int, y: Int, phase: TouchPhase) -> Bool {
        runtimes[deviceID]?.touch(x: x, y: y, phase: phase) ?? false
    }

    func tap(_ x: Int, _ y: Int) {
        guard let id = selectedDevice?.id else { return }
        tap(deviceID: id, x: x, y: y)
    }

    func tap(deviceID: String, x: Int, y: Int) {
        guard let serial = runtimes[deviceID]?.serial else { return }
        Task { await AndroidRepository.tap(serial: serial, x: x, y: y, paths: settings) }
    }

    func swipe(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ duration: Int) {
        guard let id = selectedDevice?.id else { return }
        swipe(deviceID: id, x1: x1, y1: y1, x2: x2, y2: y2, duration: duration)
    }

    func swipe(deviceID: String, x1: Int, y1: Int, x2: Int, y2: Int, duration: Int) {
        guard let serial = runtimes[deviceID]?.serial else { return }
        Task { await AndroidRepository.swipe(serial: serial, x1: x1, y1: y1, x2: x2, y2: y2, duration: duration, paths: settings) }
    }

    func key(_ code: Int) {
        guard let id = selectedDevice?.id else { return }
        key(deviceID: id, code: code)
    }

    func key(deviceID: String, code: Int) {
        guard let serial = runtimes[deviceID]?.serial else { return }
        Task { await AndroidRepository.key(serial: serial, code: code, paths: settings) }
    }

    func typeText(_ text: String) {
        guard let id = selectedDevice?.id else { return }
        typeText(deviceID: id, text: text)
    }

    func typeText(deviceID: String, text: String) {
        guard let serial = runtimes[deviceID]?.serial else { return }
        Task {
            do {
                try await AndroidRepository.text(serial: serial, text: text, paths: settings)
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    func rotate() {
        guard let id = selectedDevice?.id else { return }
        rotate(deviceID: id)
    }

    func rotate(deviceID: String) {
        guard let runtime = runtimes[deviceID], let serial = runtime.serial else { return }
        let next = (runtime.rotationQuarter + 1) % 4
        runtime.setRotation(quarter: next)
        Task { await AndroidRepository.rotate(serial: serial, quarter: next, paths: settings) }
    }

    func toggleFold(_ device: AvdDevice) {
        guard device.isFoldable else {
            toast = "This emulator is not foldable."
            return
        }
        runtimes[device.id]?.toggleFold(paths: settings)
    }

    func screenshot() {
        guard let id = selectedDevice?.id else { return }
        screenshot(deviceID: id)
    }

    func screenshot(deviceID: String) {
        guard let runtime = runtimes[deviceID], let serial = runtime.serial,
              let device = devices.first(where: { $0.id == deviceID }) else { return }
        Task {
            do {
                let data = try await AndroidRepository.screenshot(serial: serial, paths: settings)
                let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let url = desktop.appendingPathComponent("SimLab-\(device.id)-\(formatter.string(from: Date())).png")
                try data.write(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                toast = "Saved \(url.lastPathComponent)"
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    func installAPK() {
        guard let id = selectedDevice?.id else { return }
        installAPK(deviceID: id)
    }

    func installAPK(deviceID: String) {
        guard let runtime = runtimes[deviceID], let serial = runtime.serial else {
            toast = "Start the emulator first."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an APK to install"
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isInstalling = true
        Task {
            let beforeList = await AndroidRepository.packages(serial: serial, paths: settings)
            let before = Set(beforeList)
            do {
                let output = try await AndroidRepository.installAPK(url: url, serial: serial, paths: settings)
                let after = await AndroidRepository.packages(serial: serial, paths: settings)
                let newPackages = after.filter { !before.contains($0) }
                isInstalling = false
                if let package = newPackages.first {
                    toast = "Installed \(package). Launching…"
                    await AndroidRepository.launch(package: package, serial: serial, paths: settings)
                } else {
                    toast = output.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? "Installed."
                }
            } catch {
                isInstalling = false
                toast = error.localizedDescription
            }
        }
    }

    func loadApps() {
        guard let id = selectedDevice?.id else { return }
        Task {
            await reloadApps(deviceID: id)
            showApps = true
        }
    }

    func reloadApps(deviceID: String) async {
        guard let runtime = runtimes[deviceID], let serial = runtime.serial,
              let device = devices.first(where: { $0.id == deviceID }) else { return }
        appsDeviceName = device.displayName
        apps = await AndroidRepository.packages(serial: serial, paths: settings)
    }

    func launchApp(_ package: String) {
        guard let id = selectedDevice?.id else { return }
        launchApp(deviceID: id, package: package)
    }

    func launchApp(deviceID: String, package: String) {
        guard let serial = runtimes[deviceID]?.serial else { return }
        showApps = false
        Task {
            await AndroidRepository.launch(package: package, serial: serial, paths: settings)
        }
    }

    // MARK: - Images

    func install(image: SystemImage) {
        guard !isDownloading else { return }
        isDownloading = true
        installLog = "Preparing \(image.displayName)…\n"
        Task {
            do {
                try await AndroidRepository.acceptLicenses(paths: settings)
                installLog += "Downloading and installing…\n"
                let output = try await AndroidRepository.installImage(image, paths: settings)
                installLog += output.suffix(4000)
                installLog += "\nInstalled \(image.displayName)."
                await refresh()
                toast = "Installed \(image.displayName)."
            } catch {
                installLog += "\nError: \(error.localizedDescription)"
                toast = error.localizedDescription
            }
            isDownloading = false
        }
    }
}
