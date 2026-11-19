import AppKit
import SwiftUI

private struct SimulatorPreviewPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var simulatorPreviewPaused: Bool {
        get { self[SimulatorPreviewPausedKey.self] }
        set { self[SimulatorPreviewPausedKey.self] = newValue }
    }
}

/// The window may stay mounted in SwiftUI while minimized or covered.
struct WindowPreviewVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Observer {
        let view = Observer()
        view.changed = updateVisibility
        return view
    }

    func updateNSView(_ view: Observer, context: Context) {
        view.changed = updateVisibility
    }

    private func updateVisibility(_ value: Bool) {
        if visible != value { visible = value }
    }

    final class Observer: NSView {
        var changed: ((Bool) -> Void)?
        private var observations: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observations.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                })
            }
            Task { @MainActor [weak self] in self?.refresh() }
        }

        private func refresh() {
            changed?(window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false)
        }

        deinit {
            observations.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
