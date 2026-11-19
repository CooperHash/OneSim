import SwiftUI
import UniformTypeIdentifiers

struct DependencySetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let report = model.dependencyReport {
            DependencySetupSheet(report: report, xcode: model.xcode)
        } else {
            ProgressView("Checking installed simulators…").padding(32)
        }
    }
}

private struct DependencySetupSheet: View {
    let report: DependencySetup.Report
    @ObservedObject var xcode: XcodeManager
    @EnvironmentObject private var model: AppModel
    @State private var showXcodeVersions = false
    @State private var chooseRuntime = false
    @State private var importError: String?

    private var busy: Bool { model.isSettingUp || model.isCheckingDependencies || xcode.busy }

    var body: some View {
        let total = report.android.reduce(Int64(0)) { $0 + $1.bytes }
        let received = report.android.reduce(Int64(0)) { sum, package in
            sum + min(package.bytes, model.setupProgress[package.id, default: 0])
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up MultiSim").font(.title2.bold())
            if let error = report.platformError { Text(error).foregroundStyle(.secondary) }
            if !report.android.isEmpty {
                Text("Android needs \(report.android.count) more dependencies.")
            }
            ForEach(report.android) { package in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(package.name, value: format(package.bytes))
                    if model.isSettingUp {
                        ProgressView(value: Double(model.setupProgress[package.id, default: 0]),
                                     total: Double(package.bytes))
                    }
                }
            }
            Divider()
            if let installed = report.xcode {
                LabeledContent("Xcode", value: installed.label)
                Text(installed.bundle.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let inventory = report.ios {
                ForEach(IOSSimulatorKind.allCases) { kind in
                    LabeledContent(kind.name, value: runtimeStatus(kind, inventory: inventory))
                }
                if inventory.plan != nil, !inventory.reportedIOS.isEmpty {
                    DisclosureGroup("Runtimes reported by Xcode") {
                        Text(inventory.reportedIOS.joined(separator: "\n"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            if let issue = report.iosIssue { Text(issue).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("Xcode Versions…") { showXcodeVersions = true }.disabled(busy)
                if report.xcode != nil, !report.xcodeNeedsSetup {
                    Button("Import iOS Runtime…") { chooseRuntime = true }.disabled(busy)
                }
            }
            if model.isSettingUp && total > 0 {
                ProgressView(value: Double(received), total: Double(total)) {
                    Text("Android downloads")
                } currentValueLabel: {
                    Text("\(Int(Double(received) / Double(total) * 100))% • \(format(received)) / \(format(total))")
                }
            }
            if !model.setupMessage.isEmpty {
                ScrollView {
                    Text(model.setupMessage).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).foregroundStyle(.secondary)
                }
                .frame(maxHeight: 115)
                .fixedSize(horizontal: false, vertical: true)
            }
            if model.isSettingUp || model.isCheckingDependencies { ProgressView().controlSize(.small) }
            if !xcode.status.isEmpty { Text(xcode.status).foregroundStyle(.secondary) }
            if let error = xcode.error { Text(error).foregroundStyle(.secondary) }
            if let importError { Text(importError).foregroundStyle(.secondary).textSelection(.enabled) }
            if !report.android.isEmpty {
                Text("Download and Configure accepts the Android SDK license terms.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Android SDK license terms", destination: URL(string: "https://developer.android.com/studio/terms")!)
            }
            HStack {
                Button("Check Again") {
                    importError = nil
                    Task { await model.checkDependencies(showSheet: true) }
                }
                .disabled(busy)
                Spacer()
                Button(model.isSettingUp ? "Continue in Background" : report.android.isEmpty ? "Done" : "Later") {
                    model.showDependencySetup = false
                }
                if report.xcodeNeedsSetup {
                    Button("Finish Xcode Setup") {
                        Task {
                            if await xcode.prepareActiveXcode() {
                                await model.checkDependencies(showSheet: true, autoInstallIOS: true)
                            }
                        }
                    }
                    .disabled(busy)
                }
                if (!report.android.isEmpty || report.iosPlan != nil) && report.platformError == nil {
                    Button("Download and Configure") { model.installMissingDependencies() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(model.isSettingUp)
        .sheet(isPresented: $showXcodeVersions) { XcodeManagerView(xcode: xcode) }
        .fileImporter(isPresented: $chooseRuntime, allowedContentTypes: [.diskImage]) { result in
            switch result {
            case .success(let file):
                importError = nil
                model.importIOSRuntime(file)
            case .failure(let error): importError = error.localizedDescription
            }
        }
    }

    private func runtimeStatus(_ kind: IOSSimulatorKind, inventory: XcodeRuntimeSetup.Inventory) -> String {
        if let id = inventory.installed[kind] {
            let version = XcodeRuntimeSetup.runtimeVersion(["identifier": id]) ?? inventory.sdk
            return "Ready · iOS \(version)"
        }
        return inventory.supported.contains(kind) ? "Runtime needed" : "Requires a different Xcode version"
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
