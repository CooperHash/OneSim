import Foundation

enum WebResources {
    private static let root: URL = {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("Web"),
           FileManager.default.fileExists(atPath: resource.path) { return resource }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Web")
    }()

    private static let routes: [String: (String, String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/app.js": ("app.js", "application/javascript"),
        "/duo.js": ("duo.js", "application/javascript"),
        "/style.css": ("style.css", "text/css"),
        "/assets/v68.glb": ("assets/v68.glb", "model/gltf-binary"),
        "/assets/chrome/phone12.png": ("assets/chrome/phone12.png", "image/png"),
        "/assets/chrome/phone14.png": ("assets/chrome/phone14.png", "image/png"),
        "/assets/chrome/phone15.png": ("assets/chrome/phone15.png", "image/png"),
        "/vendor/three.module.min.js": ("vendor/three.module.min.js", "application/javascript"),
        "/vendor/three.core.min.js": ("vendor/three.core.min.js", "application/javascript"),
        "/vendor/GLTFLoader.js": ("vendor/GLTFLoader.js", "application/javascript"),
        "/vendor/BufferGeometryUtils.js": ("vendor/BufferGeometryUtils.js", "application/javascript"),
        "/vendor/meshopt_decoder.module.js": ("vendor/meshopt_decoder.module.js", "application/javascript"),
    ]

    static func resource(_ route: String, requiresKey: Bool) -> (Data, String)? {
        let path = String(route.prefix(while: { $0 != "?" }))
        guard let (file, type) = routes[path],
              let content = try? Data(contentsOf: root.appendingPathComponent(file), options: .mappedIfSafe) else { return nil }
        if path == "/", let page = String(data: content, encoding: .utf8) {
            let hasModel = FileManager.default.fileExists(atPath: root.appendingPathComponent("assets/v68.glb").path)
            let html = page.replacingOccurrences(of: "__ACCESS__", with: requiresKey ? "lan" : "local")
                .replacingOccurrences(of: "__DUO_MODEL__", with: hasModel ? "available" : "unavailable")
            return (Data(html.utf8), type)
        }
        return (content, type)
    }
}
