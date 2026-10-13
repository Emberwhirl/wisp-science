import XCTest
import UIKit
import WispRemote
@testable import WispScience

@MainActor final class DemoDatasetTests: XCTestCase {
    private func dataset() throws -> DemoDataset { try DemoDataset(bundle: Bundle(for: WispAppDelegate.self)) }

    func testBundledSessionsUseValidSnapshotsAndEveryFileOpensLocally() throws {
        let demo = try dataset()
        let rows = try demo.call("remote_sessions", project: demo.projectID, args: [:]).array
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let route = ConversationRoute(project: demo.projectID, session: row["id"].string)
            let snapshot = try RemoteSnapshot(demo.call("native_conversation_snapshot", project: route.project, args: route.args), route: route)
            XCTAssertFalse(snapshot.items.isEmpty)
            XCTAssertFalse(snapshot.running)
            XCTAssertTrue(snapshot.writable)
        }
        let route = ConversationRoute(project: demo.projectID, session: "demo-qc")
        var directories = ["."]
        var opened: Set<String> = []
        while let directory = directories.popLast() {
            let value = try demo.call("native_conversation_panel_file_directory", project: route.project,
                                      args: route.args.merging(["path": .string(directory)]) { _, v in v })
            for file in value["entries"].array {
                let path = directory == "." ? file["name"].string : directory + "/" + file["name"].string
                if file["is_dir"].bool { directories.append(path); continue }
                opened.insert(path)
                let image = path.hasSuffix(".png")
                let value = try demo.call(image ? "native_conversation_image" : "native_conversation_panel_file_read", project: route.project,
                                          args: route.args.merging(["path": .string(path)]) { _, v in v })
                if image {
                    let bytes = try XCTUnwrap(Data(base64Encoded: value["base64"].string))
                    XCTAssertNotNil(UIImage(data: bytes))
                } else { XCTAssertFalse(value["content"]["text"].string.isEmpty) }
            }
        }
        XCTAssertEqual(opened, ["README.md", "data/samples.csv", "data/qc_metrics.csv", "results/qc_report.md", "results/qc_summary.png", "scripts/qc_demo.py"])
    }

    func testScriptedReplyAndApprovalAreEphemeralAndExplicitlyLabeled() throws {
        let demo = try dataset()
        let route = ConversationRoute(project: demo.projectID, session: "demo-workflow")
        _ = try demo.call("native_conversation_send", project: route.project,
                          args: route.args.merging(["message": .string("查看报告")]) { _, v in v })
        var value = try demo.call("native_conversation_snapshot", project: route.project, args: route.args)
        XCTAssertTrue(value["items"].array.last?["text"].string.contains("本地预设回复") == true)
        _ = try demo.call("native_conversation_approve", project: route.project,
                          args: route.args.merging(["approval_id": .string("demo-approval"), "approved": .bool(true)]) { _, v in v })
        value = try demo.call("native_conversation_snapshot", project: route.project, args: route.args)
        XCTAssertTrue(value["approvals"].array.isEmpty)
        XCTAssertTrue(value["items"].array.last?["text"].string.contains("没有运行命令") == true)
        let reset = try dataset().call("native_conversation_snapshot", project: route.project, args: route.args)
        XCTAssertEqual(reset["approvals"].array.count, 1)
        XCTAssertEqual(reset["items"].array.count, 2)
        XCTAssertNotEqual(value["epoch"], reset["epoch"])
    }

    func testUnknownProjectSessionAndUnbundledPathsAreRejected() throws {
        let demo = try dataset()
        XCTAssertThrowsError(try demo.call("remote_sessions", project: "real-project", args: [:]))
        XCTAssertThrowsError(try demo.call("native_conversation_snapshot", project: demo.projectID, args: ["session_id": .string("real-session")]))
        for path in ["/etc/passwd", "../manifest.json", "data/../../secret", "https://example.com/file", "unlisted.txt"] {
            XCTAssertThrowsError(try demo.call("native_conversation_panel_file_read", project: demo.projectID,
                                               args: ["session_id": .string("demo-qc"), "path": .string(path)]))
        }
        XCTAssertThrowsError(try demo.call("shell", project: demo.projectID, args: [:]))
    }

    func testDemoLifecycleDoesNotTouchSavedCredentialsAndRestoresWithoutRemote() async throws {
        let credentials = CredentialsSpy()
        let suite = "wisp-demo-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = RemoteWorkspace(credentials: credentials, preferences: preferences)
        model.enterDemo()
        await model.refreshSelection()
        XCTAssertTrue(model.isDemo)
        XCTAssertEqual(model.projects.count, 1)
        XCTAssertNil(model.configuration)
        model.setActive(false)
        model.setActive(true)
        XCTAssertEqual(model.connection.state, .online)
        let relaunched = RemoteWorkspace(credentials: credentials, preferences: preferences)
        relaunched.restore()
        XCTAssertTrue(relaunched.isDemo)
        relaunched.exitDemo()
        model.exitDemo()
        await Task.yield()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(model.connection.state, .idle)
        XCTAssertEqual(credentials.accesses, 0)
    }
}

private final class CredentialsSpy: RemoteCredentialStoring {
    var accesses = 0
    func load() throws -> RemoteConfiguration? { accesses += 1; return nil }
    func save(_ configuration: RemoteConfiguration) throws { accesses += 1 }
    func remove() throws { accesses += 1 }
}
