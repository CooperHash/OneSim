import XCTest
@testable import SimLab

final class MultiSimWorkspaceTests: XCTestCase {
    func testDefaultWorkspaceContainsDuoAndKeepsPrimaryAndroid() {
        let workspace = MultiSimWorkspace.initial(androidID: "phone")
        XCTAssertEqual(workspace.members, [
            .android("phone"), .ios(.iphone16Pro), .ios(.iphoneDuo),
        ])
        XCTAssertEqual(workspace.removing(.android("phone")), workspace)
    }

    func testAddingDevicesIsOrderedAndIdempotent() {
        let original = MultiSimWorkspace.initial(androidID: "phone")
        let expanded = original.adding(.android("fold"))
        XCTAssertEqual(expanded.members.last, .android("fold"))
        XCTAssertEqual(expanded.adding(.android("fold")), expanded)
        XCTAssertEqual(expanded.removing(.android("fold")), original)
        XCTAssertEqual(expanded.removing(.ios(.iphoneDuo)).members, [
            .android("phone"), .ios(.iphone16Pro), .android("fold"),
        ])
    }

    func testWorkspaceRoundTripsThroughSavedFormat() throws {
        let workspace = MultiSimWorkspace.initial(androidID: "phone")
            .adding(.android("fold"))
        let data = try JSONEncoder().encode([workspace])
        XCTAssertEqual(try JSONDecoder().decode([MultiSimWorkspace].self, from: data), [workspace])
    }
}
