import SwiftUI
import AppKit

@main
struct SimLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("SimLab", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 640)
                .onAppear { model.boot() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.shutdown()
                }
        }
        .defaultSize(width: 1380, height: 880)

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Device…") { model.showCreate = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Set Up MultiSim…") { Task { await model.checkDependencies() } }
                Button("Refresh Devices") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Device") {
                Button("Start / Stop Selected") { model.toggleSelectedDevice() }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button("Cold Boot Selected") {
                    if let device = model.selectedDevice { model.coldBootDevice(device) }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Wipe Selected…") {
                    if let device = model.selectedDevice { model.wipeDevice(device) }
                }
                Button("Install APK…") { model.installAPK() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appSettings) {
                Button("Android SDK…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        sender.windows.filter { $0.isVisible }.isEmpty
    }
}
