import SwiftUI

enum Theme {
    static let accent = Color.accentColor
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let separator = Color.primary.opacity(0.08)
    // Use semantic colors so the workspace follows the Mac's appearance.
    static let stage = LinearGradient(
        colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let bezel = LinearGradient(
        colors: [Color(white: 0.26), Color(white: 0.10), Color(white: 0.06)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let bezelHighlight = LinearGradient(
        colors: [Color.white.opacity(0.28), .clear, Color.white.opacity(0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func statusColor(_ state: DeviceState) -> Color {
        switch state {
        case .running: return .green
        case .booting, .starting: return .orange
        case .stopping: return .orange
        case .error: return .red
        case .stopped: return .secondary
        }
    }

    static func deviceIcon(_ device: AvdDevice) -> String {
        if device.isFoldable { return "rectangle.split.2x1" }
        switch device.profile?.category {
        case "tablet": return "ipad.gen2"
        case "watch": return "applewatch"
        case "tv": return "tv"
        case "foldable": return "rectangle.split.2x1"
        default: return "iphone.gen3"
        }
    }

    static let mono = Font.system(size: 11, design: .monospaced)
}

/// An original, lightweight device illustration for stopped and empty states.
/// It follows the AVD's proportions rather than implying a live screenshot.
struct DeviceArtwork: View {
    let device: AvdDevice
    var height: CGFloat = 188

    private var aspect: CGFloat {
        min(1.7, max(0.42, CGFloat(device.width) / CGFloat(max(1, device.height))))
    }

    var body: some View {
        let isRound = device.profile?.isCircular == true
        let radius: CGFloat = isRound ? height / 2 : min(23, height * 0.10)
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.bezel)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
            RoundedRectangle(cornerRadius: max(4, radius - 4), style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.34, green: 0.65, blue: 0.91), Color(red: 0.18, green: 0.38, blue: 0.69)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: max(4, radius - 4), style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.17), .clear], startPoint: .top, endPoint: .center))
                }
                .padding(4)
            if !isRound && aspect < 0.8 {
                Circle()
                    .fill(Color(white: 0.08))
                    .frame(width: 5, height: 5)
                    .padding(.top, 8)
            }
            if device.isFoldable && aspect >= 0.8 {
                Rectangle()
                    .fill(LinearGradient(colors: [.black.opacity(0.22), .white.opacity(0.12), .black.opacity(0.22)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 5, height: height - 8)
                    .padding(.top, 4)
            }
        }
        .frame(width: height * (isRound ? 1 : aspect), height: height)
        .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
        .accessibilityHidden(true)
    }
}
