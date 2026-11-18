import SwiftUI

struct DependencySetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let report = model.dependencyReport {
            let total = report.android.reduce(Int64(0)) { $0 + $1.bytes }
            let received = report.android.reduce(Int64(0)) { sum, package in
                sum + min(package.bytes, model.setupProgress[package.id, default: 0])
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Set up MultiSim").font(.title2.bold())
                let count = report.android.count + report.runtimeVersions.count + report.prerequisites.count
                Text("MultiSim needs \(count) more dependencies.")
                ForEach(report.prerequisites, id: \.self) { Text($0).foregroundStyle(.secondary) }
                ForEach(report.android) { package in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(package.name, value: format(package.bytes))
                        if model.isSettingUp {
                            ProgressView(value: Double(model.setupProgress[package.id, default: 0]),
                                         total: Double(package.bytes))
                        }
                    }
                }
                ForEach(report.runtimeVersions, id: \.self) { version in
                    LabeledContent("iOS \(version) Simulator Runtime", value: "Size reported by Xcode")
                }
                if model.isSettingUp {
                    if total > 0 {
                        ProgressView(value: Double(received), total: Double(total)) {
                            Text("Android downloads")
                        } currentValueLabel: {
                            Text("\(Int(Double(received) / Double(total) * 100))% • \(format(received)) / \(format(total))")
                        }
                    }
                    if !report.runtimeVersions.isEmpty && received >= total { ProgressView() }
                }
                if !model.setupMessage.isEmpty {
                    Text(model.setupMessage)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                if !report.android.isEmpty {
                    Text("Download and Configure accepts the Android SDK license terms.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Android SDK license terms", destination: URL(string: "https://developer.android.com/studio/terms")!)
                }
                HStack {
                    if !report.prerequisites.isEmpty {
                        Link("Get Xcode", destination: URL(string: "https://developer.apple.com/xcode/")!)
                        Button("Check Again") { Task { await model.checkDependencies() } }
                    }
                    Spacer()
                    Button("Later") { model.showDependencySetup = false }
                        .disabled(model.isSettingUp)
                    if report.prerequisites.isEmpty {
                        Button("Download and Configure") { model.installMissingDependencies() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isSettingUp)
                    }
                }
            }
            .padding(24)
            .frame(width: 560)
            .interactiveDismissDisabled(model.isSettingUp)
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
