import XCTest

/// 시연 영상용 연속 흐름(iPad 가로). 평소 시험에서는 건너뛰고, 녹화할 때만 돈다.
///
/// 실행(시뮬레이터 화면은 `xcrun simctl io <기기> recordVideo` 로 따로 녹화):
///   TEST_RUNNER_SAFECERT_DEMO=1 xcodebuild test -scheme SafeCert -destination 'id=<기기>' \
///     -only-testing:SafeCertUITests/DemoWalkthroughUITests/test2_Walkthrough
/// 보고서에 AI 문장을 넣으려면 먼저 `test1_SetupGeminiKey` 를 TEST_RUNNER_SAFECERT_DEMO_GEMINI_KEY 와 함께 돌린다
/// (키는 설정 화면의 보안 입력란을 거쳐 시뮬레이터 앱의 키체인에만 들어간다).
final class DemoWalkthroughUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(env["SAFECERT_DEMO"] == "1", "시연 녹화 때만 실행")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
    }

    /// 녹화 전 준비: 설정 화면에 Gemini 키 저장. 첫 실행 안내는 띄우지 않는다(저장하지 않는 실행 인자).
    func test1_SetupGeminiKey() throws {
        let key = try XCTUnwrap(env["SAFECERT_DEMO_GEMINI_KEY"], "키가 없으면 AI 없이 녹화한다")
        app.launchArguments += ["-guideSeen", "YES"]
        app.launch()
        tap(sidebarItem("설정"))
        let field = wait(app.secureTextFields["Gemini API 키"])
        field.tap()
        field.typeText(key)
        app.buttons.matching(identifier: "저장").element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '키 저장됨'")).firstMatch.waitForExistence(timeout: 5))
        app.terminate()
    }

    /// 녹화 본편: 첫 실행 안내 → 샘플 도면 → 확인 → 판정 → 항목별 확인 체크 → 보고서 PDF → 법령 현황 → 법령 변경 시연.
    func test2_Walkthrough() throws {
        app.launch()

        // 1. 첫 실행 안내
        let start = wait(app.buttons["시작하기"], 30)
        pause(3)
        scrollUntilHittable(start)
        pause(1.5)
        start.tap()
        pause(1.5)

        // 2. 새 검토 — 시연용 샘플 도면
        tap(app.buttons["새 검토"].firstMatch)
        pause(1.5)
        tap(app.buttons.containing(NSPredicate(format: "label BEGINSWITH '샘플 B'")).firstMatch)
        pause(2)
        tap(app.buttons["검토 만들기"])

        // 3. 확인 화면 — 앱이 읽은 값을 보고 축척을 확인
        let judge = wait(app.buttons["판정 실행"], 60)
        pause(3)
        let scale = app.switches["확인"].firstMatch
        if scale.exists { turnOn(scale) }
        pause(2.5)
        waitEnabled(judge, 90)
        judge.tap()

        // 4. 결과 — 도면 위 색 표시와 판정 설명
        let firstCheck = wait(app.buttons["1번 판정 확인 체크"], 60)
        pause(3)
        openCard(firstCheck)
        pause(4)
        swipePanel(up: true)
        pause(3.5)
        scrollPanelToTop()
        pause(1)
        openCard(app.buttons["1번 판정 확인 체크"])
        pause(1.5)

        // 5. 사람 확인 — 판정 항목마다 체크
        var n = 1
        while true {
            let check = app.buttons["\(n)번 판정 확인 체크"]
            guard check.waitForExistence(timeout: 2) else { break }
            scrollIntoView(check)
            check.tap()
            pause(1.2)
            n += 1
        }
        scrollPanelToTop()
        pause(3)

        // 6. 보고서 PDF — 외부 전송 확인 → AI 문장 작성 → 미리보기
        tap(app.buttons.containing(NSPredicate(format: "label BEGINSWITH '보고서 PDF'")).firstMatch)
        let send = app.buttons["보내고 작성"]
        if send.waitForExistence(timeout: 5) {
            pause(4)
            send.tap()
        }
        wait(app.buttons["공유"], 150)
        pause(3)
        for _ in 0..<9 {
            drag(from: 0.78, to: 0.30)
            pause(1.8)
        }
        pause(1.5)
        tap(app.buttons["닫기"])
        pause(1.5)

        // 7. 법령 현황 — 매일 자동 수집·검증
        tap(sidebarItem("법령 현황"))
        pause(4)
        drag(from: 0.75, to: 0.40)
        pause(3)

        // 8. 법령 변경 시연(가상) — 설정에서 켜고 다시 판정 → 노랑
        tap(sidebarItem("설정"))
        pause(1.5)
        let demo = app.switches["법령 변경 시연(가상)"].firstMatch
        scrollUntilHittable(demo)
        pause(1.5)
        turnOn(demo)
        pause(3)
        tap(sidebarItem("샘플 B · 노래연습장 영업장"))
        pause(2.5)
        tap(app.buttons["최신 법령으로 다시 판정"])
        let changed = wait(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '기준 변경 감지'")).firstMatch, 60)
        pause(2.5)
        if let check = checkButton(near: changed) { openCard(check) } else { changed.tap() }
        pause(6)
    }

    // MARK: - 도움

    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    @discardableResult
    private func wait(_ e: XCUIElement, _ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "보이지 않음: \(e)", file: file, line: line)
        return e
    }

    private func waitEnabled(_ e: XCUIElement, _ timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !e.isEnabled, Date() < deadline { pause(0.5) }
    }

    private func tap(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        wait(e, 20, file: file, line: line)
        if !e.isHittable { scrollUntilHittable(e) }
        e.tap()
    }

    /// 왼쪽 목록 항목. 검토를 열면 목록이 접히므로 필요하면 다시 펼친다.
    private func sidebarItem(_ title: String) -> XCUIElement {
        let item = app.staticTexts[title].firstMatch
        if !(item.exists && item.isHittable) { showSidebar() }
        return item
    }

    private func showSidebar() {
        for id in ["ToggleSidebar", "Show Sidebar", "사이드바 보기", "사이드바 표시", "사이드바"] {
            let b = app.buttons[id].firstMatch
            if b.exists && b.isHittable {
                b.tap()
                pause(1)
                return
            }
        }
        // 버튼을 못 찾으면 왼쪽 가장자리에서 끌어낸다.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)))
        pause(1)
    }

    /// 판정 카드 열기: 확인 체크 버튼 왼쪽(카드 본문)을 누른다.
    private func openCard(_ check: XCUIElement) {
        check.coordinate(withNormalizedOffset: CGVector(dx: -2.5, dy: 0.5)).tap()
    }

    private func checkButton(near text: XCUIElement) -> XCUIElement? {
        let buttons = app.buttons.matching(NSPredicate(format: "label ENDSWITH '번 판정 확인 체크' OR label ENDSWITH '번 판정 확인 해제'"))
        let y = text.frame.midY
        return buttons.allElementsBoundByIndex
            .filter { $0.frame.minY - 80 < y && y < $0.frame.maxY + 80 }
            .min { abs($0.frame.midY - y) < abs($1.frame.midY - y) }
    }

    /// 오른쪽 설명 패널(화면 오른쪽 1/3)에서 천천히 끈다.
    private func swipePanel(up: Bool) {
        let x = 0.82
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: up ? 0.75 : 0.35))
        a.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: up ? 0.40 : 0.80)))
    }

    private func scrollPanelToTop() {
        for _ in 0..<4 { swipePanel(up: false); pause(0.4) }
    }

    private func drag(from: Double, to: Double) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        a.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
    }

    /// 스위치 켜기 — 목록 행 가운데가 아니라 오른쪽 끝의 스위치를 누른다.
    private func turnOn(_ toggle: XCUIElement) {
        guard (toggle.value as? String) != "1" else { return }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        pause(0.5)
        if (toggle.value as? String) != "1" { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, "1", "스위치가 켜지지 않음: \(toggle)")
    }

    /// 설명 패널 안에서 위·아래를 가려 보이게 한다.
    private func scrollIntoView(_ e: XCUIElement) {
        var tries = 0
        while !e.isHittable, tries < 8 {
            swipePanel(up: e.frame.midY > app.frame.midY)
            pause(0.4)
            tries += 1
        }
    }

    private func scrollUntilHittable(_ e: XCUIElement, panel: Bool = false) {
        var tries = 0
        while !e.isHittable, tries < 8 {
            if panel { swipePanel(up: true) } else { app.swipeUp() }
            pause(0.4)
            tries += 1
        }
    }
}
