import SwiftUI

struct AndroidSlimMenu: View {
    let device: AvdDevice
    let paths: ToolPaths
    @ObservedObject var runtime: DeviceRuntime

    var body: some View {
        Menu {
            Text("\(runtime.slimmedPackages) optional packages disabled")
            if runtime.slimMode == .balanced && device.ramMB > AndroidSlimClient.memoryLimitMB {
                Text("Balanced RAM: \(AndroidSlimClient.memoryLimitMB / 1024) GB (configured \(device.ramMB / 1024) GB)")
            }
            Divider()
            Button("Use Balanced Profile") {
                runtime.setSlimMode(.balanced, device: device, paths: paths)
            }
            .disabled(runtime.slimMode == .balanced)
            Button("Restore Standard Profile") {
                runtime.setSlimMode(.standard, device: device, paths: paths)
            }
            .disabled(runtime.slimMode == .standard)
            Divider()
            Text("Changing profiles restarts this emulator.")
        } label: {
            Label(runtime.isChangingSlim ? "Working…" : runtime.slimMode.title,
                  systemImage: "memorychip")
                .font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(runtime.state != .running || runtime.isChangingSlim)
        .help("Android resource profile")
        .alert("Could not change Android profile", isPresented: Binding(
            get: { runtime.slimError != nil },
            set: { if !$0 { runtime.slimError = nil } }
        )) {
            Button("OK") { runtime.slimError = nil }
        } message: {
            Text(runtime.slimError ?? "")
        }
    }
}
