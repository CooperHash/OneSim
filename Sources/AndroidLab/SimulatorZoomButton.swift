import SwiftUI

struct SimulatorZoomButton: View {
    @Binding var zoom: CGFloat
    private let levels = [50, 75, 100, 125, 150, 175, 200, 225, 250]

    private var percent: Int { Int((zoom * 100).rounded()) }

    var body: some View {
        Menu {
            ForEach(levels, id: \.self) { level in
                Button {
                    zoom = CGFloat(level) / 100
                } label: {
                    if level == percent {
                        Label("\(level)%", systemImage: "checkmark")
                    } else {
                        Text("\(level)%")
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                Text("\(percent)%")
                    .font(.system(size: 9, design: .monospaced))
            }
            .frame(width: 54, height: 40)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Zoom")
        .accessibilityValue("\(percent) percent")
        .help("Zoom")
    }
}
