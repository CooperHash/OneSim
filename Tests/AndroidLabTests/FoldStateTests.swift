import XCTest
@testable import SimLab

final class FoldStateTests: XCTestCase {
    private let supported = """
    Supported states: [
      DeviceState{identifier=7, name='CLOSED', app_accessible=true},
      DeviceState{identifier=8, name='HALF_OPENED', app_accessible=true},
      DeviceState{identifier=9, name='OPENED', app_accessible=true},
      DeviceState{identifier=10, name='REAR_DISPLAY_MODE', app_accessible=true},
    ]
    """

    func testParsesNamedStatesWithoutAssumingZeroAndTwo() throws {
        let snapshot = try FoldStateSnapshot.parse(current: "7\n", supported: supported)
        XCTAssertEqual(snapshot.currentID, 7)
        XCTAssertEqual(snapshot.foldedID, 7)
        XCTAssertEqual(snapshot.unfoldedID, 9)
        XCTAssertTrue(snapshot.isFolded)
        XCTAssertFalse(try FoldStateSnapshot.parse(current: "9", supported: supported).isFolded)
        XCTAssertFalse(try FoldStateSnapshot.parse(current: "8", supported: supported).isFolded)
    }

    func testRejectsMalformedUnknownAndUnsupportedStates() {
        for current in ["", "error: service unavailable", "0", "10", "7 9"] {
            XCTAssertThrowsError(try FoldStateSnapshot.parse(current: current, supported: supported))
        }
        XCTAssertThrowsError(try FoldStateSnapshot.parse(current: "7", supported: ""))
        XCTAssertThrowsError(try FoldStateSnapshot.parse(current: "7", supported: supported.replacingOccurrences(of: "'OPENED'", with: "'HALF_OPENED'")))
        XCTAssertThrowsError(try FoldStateSnapshot.parse(current: "7", supported: supported + "DeviceState{identifier=12, name='CLOSED'}"))
    }

    func testEmulatorConsoleRequiresExplicitSuccessfulReply() throws {
        XCTAssertNoThrow(try FoldStateControl.checkEmulatorReply(CommandResult(status: 0, stdout: "OK\r\n", stderr: "")))
        XCTAssertNoThrow(try FoldStateControl.checkEmulatorReply(CommandResult(status: 0, stdout: "some informational output\n OK \n", stderr: "")))
        for result in [
            CommandResult(status: 1, stdout: "OK\n", stderr: "connection failed"),
            CommandResult(status: 0, stdout: "KO: unsupported command\n", stderr: ""),
            CommandResult(status: 0, stdout: "OK\nKO: operation failed\n", stderr: ""),
            CommandResult(status: 0, stdout: "OK\n", stderr: "KO: rejected"),
            CommandResult(status: 0, stdout: "", stderr: ""),
            CommandResult(status: 0, stdout: "NOT OK\n", stderr: ""),
        ] {
            XCTAssertThrowsError(try FoldStateControl.checkEmulatorReply(result)) { error in
                if !result.combined.isEmpty {
                    XCTAssertTrue(error.localizedDescription.contains(result.combined))
                }
            }
        }
    }

    func testCommandFailurePreservesDiagnostic() async {
        do {
            _ = try await FoldStateControl.checked(["state", "7"]) { _, _ in
                CommandResult(status: 1, stdout: "", stderr: "device offline")
            }
            XCTFail("Expected command failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("device offline"))
            XCTAssertTrue(error.localizedDescription.contains("exit 1"))
        }
    }

    func testSetPollsUntilRequestedStateIsConfirmed() async throws {
        var commands: [[String]] = []
        var reads = 0
        let snapshot = try await FoldStateControl.set(folded: true) { args, _ in
            commands.append(args)
            if args == ["print-states"] { return CommandResult(status: 0, stdout: self.supported, stderr: "") }
            if args == ["print-state"] {
                reads += 1
                return CommandResult(status: 0, stdout: reads >= 3 ? "7" : "9", stderr: "")
            }
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertTrue(snapshot.isFolded)
        XCTAssertEqual(commands.filter { $0.first == "state" }, [["state", "7"]])
        XCTAssertEqual(reads, 3)
    }

    func testSetTimeoutDoesNotReportSuccess() async {
        do {
            _ = try await FoldStateControl.set(folded: true, confirmationTimeout: 0.02) { args, _ in
                CommandResult(status: 0, stdout: args == ["print-states"] ? self.supported : "9", stderr: "")
            }
            XCTFail("Expected confirmation timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm folding"))
            XCTAssertTrue(error.localizedDescription.contains("last state: 9"))
        }
    }

    func testRejectedSetDoesNotPollOrClaimSuccess() async {
        var stateReads = 0
        do {
            _ = try await FoldStateControl.set(folded: true) { args, _ in
                if args.first == "state" { return CommandResult(status: 1, stdout: "", stderr: "Request denied") }
                if args == ["print-state"] { stateReads += 1 }
                return CommandResult(status: 0, stdout: args == ["print-states"] ? self.supported : "9", stderr: "")
            }
            XCTFail("Expected command rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Request denied"))
            XCTAssertEqual(stateReads, 1)
        }
    }
}
