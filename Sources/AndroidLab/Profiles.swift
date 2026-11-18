import Foundation
import CoreGraphics

enum Profiles {
    static let all: [DeviceProfile] = [
        DeviceProfile(id: "pixel-10-pro", name: "Pixel 10 Pro", category: "phone",
                      width: 1280, height: 2856, density: 480, ramMB: 16384, cornerRadius: 42),
        DeviceProfile(id: "pixel-10-pro-xl", name: "Pixel 10 Pro XL", category: "phone",
                      width: 1344, height: 2992, density: 480, ramMB: 16384, cornerRadius: 42),
        DeviceProfile(id: "pixel-10", name: "Pixel 10", category: "phone",
                      width: 1080, height: 2400, density: 420, ramMB: 8192, cornerRadius: 36),
        DeviceProfile(id: "pixel-10a", name: "Pixel 10a", category: "phone",
                      width: 1080, height: 2400, density: 420, ramMB: 8192, cornerRadius: 36),
        DeviceProfile(id: "pixel-9-pro", name: "Pixel 9 Pro", category: "phone",
                      width: 1280, height: 2856, density: 480, ramMB: 12288, cornerRadius: 42),
        DeviceProfile(id: "pixel-9", name: "Pixel 9", category: "phone",
                      width: 1080, height: 2424, density: 420, ramMB: 8192, cornerRadius: 36),
        DeviceProfile(id: "pixel-fold", name: "Pixel 10 Pro Fold", category: "foldable",
                      width: 2076, height: 2152, density: 390, ramMB: 16384, cornerRadius: 32),
        DeviceProfile(id: "pixel-tablet", name: "Pixel Tablet", category: "tablet",
                      width: 2560, height: 1600, density: 320, ramMB: 8192, cornerRadius: 28),
        DeviceProfile(id: "pixel-watch", name: "Pixel Watch 4", category: "watch",
                      width: 480, height: 480, density: 320, ramMB: 2048, cornerRadius: 240),
        DeviceProfile(id: "tv-1080p", name: "Android TV 1080p", category: "tv",
                      width: 1920, height: 1080, density: 320, ramMB: 2048, cornerRadius: 8),
        DeviceProfile(id: "galaxy-s24-ultra", name: "Galaxy S24 Ultra", category: "phone",
                      width: 1440, height: 3120, density: 500, ramMB: 12288, cornerRadius: 34),
        DeviceProfile(id: "oneplus-12", name: "OnePlus 12", category: "phone",
                      width: 1440, height: 3168, density: 510, ramMB: 12288, cornerRadius: 36),
        DeviceProfile(id: "xiaomi-14", name: "Xiaomi 14", category: "phone",
                      width: 1200, height: 2670, density: 460, ramMB: 12288, cornerRadius: 38),
        DeviceProfile(id: "compact", name: "Compact Phone", category: "phone",
                      width: 1080, height: 2340, density: 440, ramMB: 4096, cornerRadius: 38),
    ]

    static let categories: [(String, String)] = [
        ("phone", "Phones"),
        ("foldable", "Foldables"),
        ("tablet", "Tablets"),
        ("watch", "Watches"),
        ("tv", "TV"),
    ]

    static func profile(id: String?) -> DeviceProfile? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func match(width: Int, height: Int) -> DeviceProfile? {
        all.first { $0.width == width && $0.height == height }
    }
}
