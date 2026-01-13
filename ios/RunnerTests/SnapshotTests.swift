import XCTest

class SnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()
    }

    override func tearDownWithError() throws {
        // Clean up after each test
    }

    func testTakeScreenshots() throws {
        let app = XCUIApplication()

        // Wait for app to fully load
        sleep(2)

        // Screenshot 1: Main screen / Home
        snapshot("01-main-screen")

        // Wait a bit for any animations
        sleep(1)

        // Screenshot 2: Add a webview or interact with UI
        // Adjust these interactions based on your app's actual UI
        // Example: Tap a button if your app has one
        // let addButton = app.buttons["Add"]
        // if addButton.exists {
        //     addButton.tap()
        //     sleep(1)
        //     snapshot("02-add-webview")
        // }

        // Screenshot 3: Settings or menu (if applicable)
        // let settingsButton = app.buttons["Settings"]
        // if settingsButton.exists {
        //     settingsButton.tap()
        //     sleep(1)
        //     snapshot("03-settings")
        // }

        // Add more screenshots as needed for your app's key features
        // Each snapshot() call should have a unique name
    }
}
