import Foundation
import XCTest
@testable import SimLab

final class PublicSharingTests: XCTestCase {
    func testQuickTunnelReadsOnlyAnExactProviderOrigin() {
        let origin = "https://example-session.trycloudflare.com"
        XCTAssertEqual(CloudflareQuickTunnel.origin(in: "INF |  \(origin)  |")?.absoluteString, origin)
        for value in ["http://example-session.trycloudflare.com", origin + ".example.org",
                      origin + "/path", origin + "@example.org", "https://trycloudflare.com"] {
            XCTAssertNil(CloudflareQuickTunnel.origin(in: value))
        }
    }

    func testPublicSocketRequiresItsOwnHostOriginAndKey() async throws {
        let host = "example-session.trycloudflare.com"
        let origin = URL(string: "https://" + host)!
        let key = UUID().uuidString
        let server = WebMultiSimServer(tunnelKey: key) { _, _ in }
        defer { server.stop() }
        let port = try await server.start()
        server.acceptPublicOrigin(origin)
        XCTAssertEqual(server.shareURL.host, host)
        XCTAssertEqual(server.shareURL.fragment, "key=\(key)")
        let base = ["--silent", "--include", "--noproxy", "*", "--max-time", "1"]
        func request(_ route: String, headers: [String]) async throws -> String {
            let args = base + headers.flatMap { ["-H", $0] } + ["http://127.0.0.1:\(port)" + route]
            return try await Shell.run("/usr/bin/curl", args, timeout: 4).stdout
        }
        let page = try await request("/", headers: ["Host: " + host])
        XCTAssertTrue(page.contains("200 OK"))
        XCTAssertTrue(page.contains("wss://" + host))
        XCTAssertFalse(page.contains(key))
        let wrongHost = try await request("/", headers: ["Host: localhost"])
        XCTAssertTrue(wrongHost.contains("404 Not Found"))
        let upgrade = ["Host: " + host, "Connection: Upgrade", "Upgrade: websocket", "Sec-WebSocket-Version: 13",
                       "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="]
        for (browserOrigin, suppliedKey) in [(origin.absoluteString, "expired"), ("http://" + host, key)] {
            let reply = try await request("/stream", headers: upgrade + ["Origin: " + browserOrigin,
                "Sec-WebSocket-Protocol: simlab, key." + suppliedKey])
            XCTAssertFalse(reply.contains("101 Switching Protocols"))
        }
        let authorized = try await request("/stream", headers: upgrade + ["Origin: " + origin.absoluteString,
            "Sec-WebSocket-Protocol: simlab, key." + key])
        XCTAssertTrue(authorized.contains("101 Switching Protocols"))
    }
}
