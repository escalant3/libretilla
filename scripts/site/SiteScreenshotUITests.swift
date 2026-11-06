import XCTest

/// Not part of the test suite: scripts/site/screenshot.sh copies this into UITests/ for one run.
/// Shoots the sample document's window in Light and Dark Mode for the website.
final class SiteScreenshotUITests: LibretillaUITestCase {
    @MainActor
    func testSiteScreenshots() throws {
        let sample = try XCTUnwrap(ProcessInfo.processInfo.environment["LIBRETILLA_SITE_DOC"])
        for mode in ["Light", "Dark"] {
            let url = work.appendingPathComponent("A small notebook.docx")
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: sample), to: url)
            app.launchArguments += ["-LibretillaUITestAppearance", mode, "-LibretillaZoom", "1"]
            app.launch()
            // Close the untitled window opened at launch, so the document doesn't open as its second tab.
            let untitled = app.windows.firstMatch
            if untitled.waitForExistence(timeout: 5) { untitled.typeKey("w", modifierFlags: .command) }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let window = try open(url)
            window.typeKey(.upArrow, modifierFlags: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "site-\(mode.lowercased())"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
