import XCTest
@testable import SimLab

final class ForesightDevLauncherTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/tmp/FN Project/apps/mobile")
    private let running = Data("packager-status:running".utf8)

    func testLocalMetroRequestsBypassTheMacProxyWithoutChangingHeadersOrQuery() {
        let request = Data("GET http://localhost:8081/index.bundle?platform=android&dev=true HTTP/1.1\r\nHost: localhost:8081\r\n\r\n".utf8)
        let expected = Data("GET /index.bundle?platform=android&dev=true HTTP/1.1\r\nHost: localhost:8081\r\n\r\n".utf8)
        XCTAssertEqual(ForesightMetroProxy.metroRequest(request), expected)
        XCTAssertNil(ForesightMetroProxy.metroRequest(Data("CONNECT api.foresightnews.pro:443 HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(ForesightMetroProxy.metroRequest(Data("GET http://example.com:8081/status HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(ForesightMetroProxy.metroRequest(Data("GET http://localhost:8080/ HTTP/1.1\r\n\r\n".utf8)))
    }

    func testMirrorsOnlyAnEnabledLocalMacHTTPProxy() {
        XCTAssertEqual(ForesightDevConfiguration.localHTTPProxyPort(in:
            ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 6152]), 6152)
        XCTAssertNil(ForesightDevConfiguration.localHTTPProxyPort(in:
            ["HTTPEnable": 0, "HTTPProxy": "127.0.0.1", "HTTPPort": 6152]))
        XCTAssertNil(ForesightDevConfiguration.localHTTPProxyPort(in:
            ["HTTPEnable": 1, "HTTPProxy": "proxy.example.com", "HTTPPort": 8080]))
        XCTAssertNil(ForesightDevConfiguration.localHTTPProxyPort(in:
            ["HTTPEnable": 1, "HTTPProxy": "localhost", "HTTPPort": 0]))
    }

    private func response(root: String? = nil, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://127.0.0.1:8081/status")!, statusCode: status,
                        httpVersion: nil, headerFields: root.map { ["X-React-Native-Project-Root": $0] })!
    }

    func testReusesMetroOnlyForTheFNProjectIncludingEncodedPaths() throws {
        let configuration = ForesightDevConfiguration(projectDirectory: project)
        try configuration.validateMetro(body: running, response: response(root: "/tmp/FN%20Project/apps/mobile"))
    }

    func testRejectsAnotherProjectsMetroInsteadOfLaunchingAgainstIt() {
        let configuration = ForesightDevConfiguration(projectDirectory: project)
        XCTAssertThrowsError(try configuration.validateMetro(body: running,
            response: response(root: "/tmp/another-app/apps/mobile")))
    }

    func testRejectsUnidentifiedOrUnhealthyServersOnTheMetroPort() {
        let configuration = ForesightDevConfiguration(projectDirectory: project)
        XCTAssertThrowsError(try configuration.validateMetro(body: running, response: response()))
        XCTAssertThrowsError(try configuration.validateMetro(body: running,
            response: response(root: project.path, status: 503)))
        XCTAssertThrowsError(try configuration.validateMetro(body: Data("OK".utf8),
            response: response(root: project.path)))
    }
}
