import XCTest

final class WorkspaceUITests: XCTestCase {
    private func launch(_ mode: String = "connected", darkAndLarge: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WISP_UI_TESTING"] = mode
        if darkAndLarge {
            app.launchArguments += ["-AppleInterfaceStyle", "Dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }
    private func openConversation(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["RNA-seq 研究"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["RNA-seq 研究"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["样本质控"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["样本质控"].firstMatch.tap()
        XCTAssertTrue(app.buttons["conversation-files"].waitForExistence(timeout: 5))
    }
    func testPhoneAndPadNavigateReadFilesAndDismissWithEscapeImmediately() {
        let app = launch()
        openConversation(app)
        app.buttons["conversation-files"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        // No focus movement inside the sheet before Escape.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["conversation-files"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["完成"].exists)
        app.buttons["conversation-files"].tap()
        XCTAssertTrue(app.staticTexts["report.md"].waitForExistence(timeout: 5))
        app.staticTexts["report.md"].tap()
        XCTAssertTrue(app.staticTexts["质控通过。"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["send-message"].exists)
    }
    func testSuggestionFillsDraftAndSendWaitsForExplicitTap() {
        let app = launch()
        openConversation(app)
        XCTAssertTrue(app.buttons["查看统计结果"].waitForExistence(timeout: 5))
        app.buttons["查看统计结果"].tap()
        let draft = app.textFields["message-draft"].exists ? app.textFields["message-draft"] : app.textViews["message-draft"]
        XCTAssertEqual(draft.value as? String, "查看统计结果")
        XCTAssertFalse(app.staticTexts["已收到离线测试消息。"].exists)
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.staticTexts["已收到离线测试消息。"].waitForExistence(timeout: 5))
    }
    func testApprovalAndStopUseRemoteCapabilities() {
        let app = launch("running")
        openConversation(app)
        XCTAssertTrue(app.buttons["批准一次"].waitForExistence(timeout: 5))
        app.buttons["批准一次"].tap()
        app.buttons["停止"].tap()
        XCTAssertTrue(app.buttons["发送"].waitForExistence(timeout: 5))
    }
    func testRejectsHTTPWithoutOpeningNetworkConnection() {
        let app = launch("connection")
        let field = app.textFields["relay-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("http://example.test/remote#000102030405060708090a0b0c0d0e0f")
        app.buttons["connect"].tap()
        XCTAssertTrue(app.staticTexts["workspace-error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connect"].exists)
    }

    func testRunRowsExposeStatusAndExpandWithoutSending() {
        let app = launch("appearance")
        openConversation(app)
        let transcript = app.scrollViews["conversation-transcript"]
        let failedRun = app.buttons["run-merge"]
        for _ in 0..<6 {
            if failedRun.isHittable { break }
            transcript.swipeDown()
        }
        XCTAssertTrue(failedRun.isHittable)
        XCTAssertTrue(failedRun.label.contains("失败"))
        XCTAssertEqual(failedRun.value as? String, "已折叠")
        XCTAssertGreaterThanOrEqual(failedRun.frame.height, 44)
        failedRun.tap()
        XCTAssertEqual(failedRun.value as? String, "已展开")
        XCTAssertTrue(app.staticTexts["$ samtools merge merged.bam a.bam b.bam"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Input file a.bam was not found."].exists)
        failedRun.tap()
        XCTAssertEqual(failedRun.value as? String, "已折叠")
        XCTAssertFalse(app.staticTexts["Input file a.bam was not found."].exists)
        XCTAssertFalse(app.buttons["send-message"].isEnabled)
    }

    func testLongSuggestionsStayReadableAndOnlyFillDraft() {
        verifyLongSuggestion(darkAndLarge: false)
    }

    func testLongSuggestionsWithDarkAppearanceAndAccessibilityText() {
        verifyLongSuggestion(darkAndLarge: true)
    }

    func testDemoEntryFilesScriptedReplyAndExitWithoutRemoteSetup() {
        let app = launch("connection")
        XCTAssertTrue(app.buttons["enter-demo"].waitForExistence(timeout: 5))
        app.buttons["enter-demo"].tap()
        XCTAssertTrue(app.buttons["exit-demo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["RNA-seq 质控 · 演示"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["RNA-seq 质控 · 演示"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["样本质控与报告"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["样本质控与报告"].firstMatch.tap()
        XCTAssertTrue(app.buttons["conversation-files"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["添加图片"].exists)
        app.buttons["conversation-files"].tap()
        XCTAssertTrue(app.staticTexts["results"].waitForExistence(timeout: 5))
        app.staticTexts["results"].tap()
        app.staticTexts["qc_report.md"].tap()
        XCTAssertTrue(app.staticTexts["RNA-seq 质控报告"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["follow-up-0"].waitForExistence(timeout: 5))
        app.buttons["follow-up-0"].tap()
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "本地预设回复 · 未调用 AI")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["exit-demo"].tap()
        XCTAssertTrue(app.buttons["enter-demo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exit-demo"].exists)
        XCTAssertFalse(app.staticTexts["workspace-error"].exists)
    }

    func testDemoApprovalCanBeReset() {
        let app = launch("connection")
        app.buttons["enter-demo"].tap()
        XCTAssertTrue(app.staticTexts["RNA-seq 质控 · 演示"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["RNA-seq 质控 · 演示"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["分析流程与审批"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["分析流程与审批"].firstMatch.tap()
        XCTAssertTrue(app.buttons["批准一次"].waitForExistence(timeout: 5))
        app.buttons["批准一次"].tap()
        XCTAssertFalse(app.buttons["批准一次"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "演示审批已批准")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["exit-demo"].tap()
        app.buttons["enter-demo"].tap()
        XCTAssertTrue(app.staticTexts["RNA-seq 质控 · 演示"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["RNA-seq 质控 · 演示"].firstMatch.tap()
        app.staticTexts["分析流程与审批"].firstMatch.tap()
        XCTAssertTrue(app.buttons["批准一次"].waitForExistence(timeout: 5))
    }

    func testDemoBannerDoesNotOverlapNavigationAcrossColumns() {
        verifyDemoBannerLayout(darkAndLarge: false)
    }

    func testDemoBannerDoesNotOverlapNavigationWithAccessibilityText() {
        verifyDemoBannerLayout(darkAndLarge: true)
    }

    private func verifyDemoBannerLayout(darkAndLarge: Bool) {
        let app = launch("connection", darkAndLarge: darkAndLarge)
        let entry = app.buttons["enter-demo"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        if !entry.isHittable { app.swipeUp() }
        entry.tap()
        assertDemoBannerAboveNavigation(app)
        XCTAssertTrue(app.buttons["connection-settings"].isHittable)
        XCTAssertTrue(app.buttons["inbox"].isHittable)
        app.buttons["connection-settings"].tap()
        XCTAssertTrue(app.buttons["reset-demo"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        assertDemoBannerAboveNavigation(app)
        let project = app.staticTexts["RNA-seq 质控 · 演示"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        assertDemoBannerAboveNavigation(app)
        let conversation = app.staticTexts["样本质控与报告"].firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.tap()
        XCTAssertTrue(app.buttons["conversation-files"].waitForExistence(timeout: 5))
        assertDemoBannerAboveNavigation(app)
        XCTAssertTrue(app.buttons["conversation-files"].isHittable)
        app.buttons["exit-demo"].tap()
        XCTAssertTrue(app.buttons["enter-demo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["demo-banner"].exists)
    }

    private func assertDemoBannerAboveNavigation(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let banner = app.otherElements["demo-banner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5), file: file, line: line)
        // Check geometry, not just existence: the regression left both sets of
        // controls present in accessibility while drawing them on top of each other.
        let separated = NSPredicate { _, _ in
            let bounds = app.windows.firstMatch.frame
            let bars = app.navigationBars.allElementsBoundByIndex.filter {
                !$0.frame.isEmpty && $0.frame.intersects(bounds)
            }
            return !bars.isEmpty && bars.allSatisfy { banner.frame.maxY <= $0.frame.minY + 1 }
        }
        let expectation = XCTNSPredicateExpectation(predicate: separated, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
        let exit = app.buttons["exit-demo"]
        XCTAssertTrue(exit.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(exit.frame.height, 44, file: file, line: line)
        XCTAssertFalse(app.staticTexts["离线演示 · 合成数据"].frame.intersects(exit.frame), file: file, line: line)
    }

    private func verifyLongSuggestion(darkAndLarge: Bool) {
        let app = launch("appearance", darkAndLarge: darkAndLarge)
        openConversation(app)
        let suggestion = app.buttons["follow-up-2"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        let transcript = app.scrollViews["conversation-transcript"]
        for _ in 0..<6 {
            if suggestion.isHittable { break }
            transcript.swipeUp()
        }
        XCTAssertTrue(suggestion.isHittable)
        XCTAssertGreaterThanOrEqual(suggestion.frame.height, 44)
        XCTAssertGreaterThanOrEqual(suggestion.frame.minX, transcript.frame.minX)
        XCTAssertLessThanOrEqual(suggestion.frame.maxX, transcript.frame.maxX)
        let send = app.buttons["send-message"]
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        XCTAssertGreaterThanOrEqual(send.frame.minX, transcript.frame.minX)
        XCTAssertLessThanOrEqual(send.frame.maxX, transcript.frame.maxX)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = darkAndLarge ? "Conversation — Dark, accessibility text" : "Conversation — Light"
        capture.lifetime = .keepAlways
        add(capture)
        suggestion.tap()
        let draft = app.textFields["message-draft"].exists ? app.textFields["message-draft"] : app.textViews["message-draft"]
        XCTAssertEqual(draft.value as? String, "其余两个 xhc 样品（big14_1/small14_1）是否也需要加入对比图并做同样的 QC 汇总？")
        XCTAssertFalse(app.staticTexts["已收到离线测试消息。"].exists)
        XCTAssertTrue(app.buttons["send-message"].isEnabled)
    }
}
