#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import ImrseApp

@MainActor
final class AppMenuWindowTests: XCTestCase {
    func testSingleStatusItemClickOpensSettingsAndContextClickShowsMenu() {
        XCTAssertEqual(
            MenuBarClickRoute.resolve(eventType: .leftMouseUp, modifierFlags: []),
            .openSettings
        )
        XCTAssertEqual(
            MenuBarClickRoute.resolve(eventType: .rightMouseUp, modifierFlags: []),
            .showContextMenu
        )
        XCTAssertEqual(
            MenuBarClickRoute.resolve(eventType: .leftMouseUp, modifierFlags: .control),
            .showContextMenu
        )
        XCTAssertNil(MenuBarClickRoute.resolve(eventType: .otherMouseUp, modifierFlags: []))
    }

    func testPreviewConfigurationNeverShowsStatusItem() {
        XCTAssertTrue(MenuBarStatusItemPolicy.shouldShow(showInMenuBar: true, isPreviewMode: false))
        XCTAssertFalse(MenuBarStatusItemPolicy.shouldShow(showInMenuBar: false, isPreviewMode: false))
        XCTAssertFalse(MenuBarStatusItemPolicy.shouldShow(showInMenuBar: true, isPreviewMode: true))
    }

    func testMenuBarBrandAssetIsAResizableTemplateImage() {
        let image = MenuBarAssets.templateImage()

        XCTAssertNotNil(image)
        XCTAssertTrue(image?.isTemplate == true)
        XCTAssertEqual(image?.size, NSSize(width: 18, height: 18))
    }

    func testSettingsWindowControllerReusesNativeFullSizeWindow() {
        let controller = SettingsWindowController()
        let window = controller.makeWindow(rootView: Color.clear)
        let secondWindow = controller.makeWindow(rootView: Color.clear)

        XCTAssertTrue(window === secondWindow)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 570))
        XCTAssertEqual(window.minSize, NSSize(width: 900, height: 570))
        XCTAssertEqual(window.maxSize, NSSize(width: 900, height: 570))
        let hostingView = window.contentView as? NSHostingView<Color>
        XCTAssertNotNil(hostingView)
        XCTAssertTrue(hostingView?.sizingOptions.isEmpty == true)
        XCTAssertTrue(hostingView?.safeAreaRegions.isEmpty == true)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
    }

    func testPackagedLogoResolvesWithoutFallingBackToDeveloperResources() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "imrse-logo-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Fixture.app")
        let resources = app.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "org.imrse.asset-fixture", "CFBundleName": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let applicationBundle = try XCTUnwrap(Bundle(url: app))

        XCTAssertNil(MenuBarAssets.templateImage(applicationBundle: applicationBundle))
        let packagedResources = resources.appending(path: "imrse_ImrseApp.bundle")
        try FileManager.default.copyItem(at: Bundle.module.bundleURL, to: packagedResources)
        let image = MenuBarAssets.templateImage(applicationBundle: applicationBundle)
        XCTAssertNotNil(image)
        XCTAssertTrue(image?.isTemplate == true)
        XCTAssertEqual(image?.size, NSSize(width: 18, height: 18))
    }
}
#endif
