import XCTest
final class SmokeTests:XCTestCase {
    func testLaunchAndImportValidation() {
        let app=XCUIApplication();app.launch()
        XCTAssertTrue(app.buttons["nav-0"].waitForExistence(timeout:10));app.buttons["nav-0"].tap()
        XCTAssertTrue(app.staticTexts["漫剧 Duo"].waitForExistence(timeout:10))
        app.buttons["导入作品链接"].tap()
        XCTAssertTrue(app.staticTexts["把故事带进来"].waitForExistence(timeout:3))
        let input=app.textViews["importText"];input.tap();input.typeText("https://example.com/untrusted")
        app.buttons["打开作品"].tap()
        XCTAssertTrue(app.staticTexts["请粘贴红果官网作品链接或红果漫剧分享链接。"].waitForExistence(timeout:3))
    }
}
