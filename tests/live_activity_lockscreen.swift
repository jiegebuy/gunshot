import XCTest

final class LiveActivityLockScreenTests: XCTestCase {
    func testFileProgressVisibleOnSystemSurface() {
        let app = XCUIApplication(bundleIdentifier: "dev.tqmane.gunshot.activitypreview")
        app.launchArguments = ["--lock-screen"]
        app.launch()
        XCTAssertTrue(app.staticTexts["GoToHP · Live Activity preview"].waitForExistence(timeout: 20))
        // Allow the foreground host to request and populate its sample activity.
        Thread.sleep(forTimeInterval: 5)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.002))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        let firstFile = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "IMG_0241.HEIC")).firstMatch
        let visible = firstFile.waitForExistence(timeout: 25)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live Activity on the system notification surface"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(visible, "The activity registered but its file content did not render on the system surface")
        for name in ["夜景_4K_HDR.MOV", "Live_0243.HEIC", "IMG_0244.JPG", "海边慢动作.MOV", "IMG_0246.HEIC", "IMG_0247.PNG", "旅行长视频.MOV"] {
            XCTAssertTrue(springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists, "Missing file tile: \(name)")
        }
    }
}
