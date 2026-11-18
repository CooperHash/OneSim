import Foundation
import CoreGraphics

struct DeviceProfile: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let category: String
    let width: Int
    let height: Int
    let density: Int
    let ramMB: Int
    let cornerRadius: CGFloat

    var isCircular: Bool { category == "watch" }
    var isTablet: Bool { category == "tablet" || category == "tv" }
    var isFoldable: Bool { category == "foldable" }
    var subtitle: String { "\(width) × \(height) · \(density) dpi" }
    var aspect: CGFloat { CGFloat(width) / CGFloat(height) }
}

struct SystemImage: Identifiable, Hashable {
    let id: String
    let api: String
    let tag: String
    let abi: String

    var apiLabel: String { api.replacingOccurrences(of: "android-", with: "Android ") }
    var friendlyTag: String {
        switch tag {
        case "google_apis_playstore": return "Google Play"
        case "google_apis": return "Google APIs"
        case "aosp_atd": return "AOSP ATD"
        case "default": return "AOSP"
        default: return tag
        }
    }
    var displayName: String { "\(apiLabel) · \(friendlyTag) · \(abi)" }
}

enum DeviceState: String {
    case stopped
    case starting
    case booting
    case running
    case stopping
    case error

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .booting: return "Booting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .error: return "Error"
        }
    }

    var isBusy: Bool { self == .starting || self == .booting || self == .stopping }
    var isLive: Bool { self == .running || self == .booting }
}

struct AvdDevice: Identifiable, Hashable {
    let id: String
    var displayName: String
    var width: Int
    var height: Int
    var density: Int
    var api: String
    var tag: String
    var imagePath: String
    var path: String
    var state: DeviceState = .stopped
    var serial: String?
    var grpcPort: Int?
    var grpcToken: String?
    var lastError: String?
    var ramMB: Int = 0
    var storageGB: Int = 0
    var isFoldable: Bool = false

    var profile: DeviceProfile? {
        Profiles.all.first { $0.width == width && $0.height == height }
    }
    var subtitle: String {
        let apiLabel = api.replacingOccurrences(of: "android-", with: "Android ")
        return "\(apiLabel) · \(width)×\(height)"
    }
}

enum IOSSimulatorKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case iphone16Pro
    case iphoneDuo

    var id: String { rawValue }

    var name: String {
        switch self {
        case .iphone16Pro: "iPhone 16 Pro"
        case .iphoneDuo: "iPhone Duo"
        }
    }

    var deviceTypeIdentifier: String {
        switch self {
        case .iphone16Pro: "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
        case .iphoneDuo: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
        }
    }

    var savedDeviceKey: String {
        switch self {
        case .iphone16Pro: "SimLab.iPhone16ProUDID"
        case .iphoneDuo: "SimLab.iPhoneDuoUDID"
        }
    }

    var defaultScreenAspect: CGFloat {
        switch self {
        case .iphone16Pro: 312.0 / 678.0
        case .iphoneDuo: 1398.0 / 2034.0
        }
    }
}

enum MultiSimMember: Codable, Hashable, Identifiable {
    case android(String)
    case ios(IOSSimulatorKind)

    var id: String {
        switch self {
        case .android(let id): "android:\(id)"
        case .ios(let kind): "ios:\(kind.rawValue)"
        }
    }
}

struct MultiSimWorkspace: Codable, Equatable, Identifiable {
    let androidID: String
    var members: [MultiSimMember]

    var id: String { androidID }

    static func initial(androidID: String) -> Self {
        Self(androidID: androidID, members: [
            .android(androidID), .ios(.iphone16Pro), .ios(.iphoneDuo),
        ])
    }

    func adding(_ member: MultiSimMember) -> Self {
        guard !members.contains(member) else { return self }
        var copy = self
        copy.members.append(member)
        return copy
    }

    func removing(_ member: MultiSimMember) -> Self {
        guard member != .android(androidID) else { return self }
        var copy = self
        copy.members.removeAll { $0 == member }
        return copy
    }
}

struct EmulatorEndpoint {
    let serial: String
    let consolePort: Int
    let adbPort: Int
    let grpcPort: Int
    let token: String
    let avdName: String
    let pid: Int
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    var ok: Bool { status == 0 }
}
