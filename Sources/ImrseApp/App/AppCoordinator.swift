#if os(macOS)
import AppKit
import Combine
import ImrseCore
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, NSMenuItemValidation {
    let model: AppModel
    private let panelController: PillPanelController
    private let settingsWindowController = SettingsWindowController()
    private var statusItem: NSStatusItem?
    private var configurationObserver: AnyCancellable?
    private var settingsAppearanceObserver: AnyCancellable?
    private(set) var showsResponseDetails = false

    override init() {
        #if DEBUG
        let model = AppModel(previewState: AppPreviewState.from(arguments: ProcessInfo.processInfo.arguments))
        #else
        let model = AppModel()
        #endif
        self.model = model
        self.panelController = PillPanelController(model: model)
        super.init()
        connectModel()
        #if DEBUG
        model.presentPreviewState()
        #endif
    }

#if DEBUG
    init(model: AppModel) {
        self.model = model
        self.panelController = PillPanelController(model: model)
        super.init()
        connectModel()
    }
#endif

    private func connectModel() {
        let panelController = self.panelController
        model.onPresentPill = { [weak panelController] screen in
            panelController?.present(afterCapturingTargetOn: screen)
        }
        guard !model.isPreviewMode else { return }
        settingsAppearanceObserver = model.$configuration
            .map(\.appearance)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] appearance in
                Task { @MainActor [weak self] in
                    self?.settingsWindowController.apply(appearance: appearance)
                }
            }
    }

    var contextMenu: NSMenu {
        MenuBarView.contextMenu(model: model, coordinator: self)
    }

    func start() {
        installApplicationMenu()
        guard !model.isPreviewMode else { return }
        applyMenuBarVisibility(showInMenuBar: model.configuration.showInMenuBar)
        configurationObserver = model.$configuration
            .map(\.showInMenuBar)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] showInMenuBar in
                Task { @MainActor [weak self] in
                    self?.applyMenuBarVisibility(showInMenuBar: showInMenuBar)
                }
            }
    }

    func openSettings() {
        guard model.canOpenSettings else { return }
        model.prepareForSettings()
        let shouldCenterWindow = settingsWindowController.window == nil
        let window = settingsWindow()
        if shouldCenterWindow { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    func presentSettingsPreviewIfNeeded() {
        guard model.isPreviewMode, model.previewState == .settings, settingsWindowController.window == nil else { return }
        openSettings()
    }
    #endif

    @objc func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            openSettings()
            return
        }
        switch MenuBarClickRoute.resolve(eventType: event.type, modifierFlags: event.modifierFlags) {
        case .openSettings:
            openSettings()
        case .showContextMenu:
            NSMenu.popUpContextMenu(contextMenu, with: event, for: sender)
        case nil:
            break
        }
    }

    @objc func invokeFromMenuItem(_ sender: NSMenuItem) {
        if let presetID = sender.representedObject as? String {
            model.invoke(presetID: presetID)
        } else {
            model.invoke()
        }
    }

    @objc func undoFromMenuItem(_ sender: NSMenuItem) {
        model.undo()
    }

    @objc func openSettingsFromMenuItem(_ sender: NSMenuItem) {
        openSettings()
    }

    @objc func toggleResponseDetails(_ sender: NSMenuItem) {
        showsResponseDetails.toggle()
        sender.state = showsResponseDetails ? .on : .off
    }

    @objc func quitFromMenuItem(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoFromMenuItem(_:)) { return model.canUndo }
        if menuItem.action == #selector(openSettingsFromMenuItem(_:)) { return model.canOpenSettings }
        if menuItem.action == #selector(invokeFromMenuItem(_:)) {
            return !model.isPreviewMode && model.state != .replacing && model.state != .undoing
        }
        return true
    }

    private func settingsWindow() -> NSWindow {
        if let window = settingsWindowController.window { return window }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let initialTab = AppPreviewState.settingsTab(
            from: arguments,
            previewState: model.previewState,
            isPreviewMode: model.isPreviewMode
        )
        let initialModelProvider = AppPreviewState.modelProviderSection(
            from: arguments,
            previewState: model.previewState,
            isPreviewMode: model.isPreviewMode
        )
        let previewColorScheme = AppPreviewState.colorScheme(
            from: arguments,
            previewState: model.previewState,
            isPreviewMode: model.isPreviewMode
        )
        #else
        let initialTab = SettingsTab.general
        let initialModelProvider: ModelProviderSection? = nil
        let previewColorScheme: ColorScheme? = nil
        #endif
        let view = SettingsView(
            model: model,
            initialTab: initialTab,
            initialModelProvider: initialModelProvider
        )
            .frame(width: 900, height: 570)
            .preferredColorScheme(previewColorScheme)
        let window = settingsWindowController.makeWindow(rootView: view)
        #if DEBUG
        if previewColorScheme == .light {
            window.appearance = NSAppearance(named: .aqua)
        } else if previewColorScheme == .dark {
            window.appearance = NSAppearance(named: .darkAqua)
        } else if !model.isPreviewMode {
            settingsWindowController.apply(appearance: model.configuration.appearance)
        }
        #else
        settingsWindowController.apply(appearance: model.configuration.appearance)
        #endif
        return window
    }

    private func applyMenuBarVisibility(showInMenuBar: Bool) {
        let shouldShow = MenuBarStatusItemPolicy.shouldShow(
            showInMenuBar: showInMenuBar,
            isPreviewMode: model.isPreviewMode
        )
        if shouldShow {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                if let button = item.button {
                    button.image = MenuBarAssets.templateImage()
                    button.imagePosition = .imageOnly
                    button.toolTip = "Open imrse Settings"
                    button.setAccessibilityLabel("Open imrse Settings")
                    button.target = self
                    button.action = #selector(handleStatusItemClick(_:))
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }
                statusItem = item
            }
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
        }
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem(title: "imrse", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "imrse")
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromMenuItem(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit imrse",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

}

@MainActor
enum MenuBarAssets {
    static func templateImage(bundle: Bundle? = nil, applicationBundle: Bundle = .main) -> NSImage? {
        let resourceBundle: Bundle
        if let bundle {
            resourceBundle = bundle
        } else if applicationBundle.bundleURL.pathExtension == "app" {
            guard let url = applicationBundle.resourceURL?.appendingPathComponent("imrse_ImrseApp.bundle"),
                  let packagedBundle = Bundle(url: url)
            else { return nil }
            resourceBundle = packagedBundle
        } else {
            resourceBundle = .module
        }
        guard let url = resourceBundle.url(
            forResource: "imrse-menubar-template",
            withExtension: "pdf",
            subdirectory: "Brand"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

@MainActor
final class SettingsWindowController {
    static let windowSize = NSSize(width: 900, height: 570)
    private(set) var window: NSWindow?

    func apply(appearance preference: AppearancePreference) {
        window?.appearance = preference.settingsNSAppearance
    }

    func makeWindow<Content: View>(rootView: Content) -> NSWindow {
        if let window { return window }
        let contentView = NSHostingView(rootView: rootView)
        contentView.sizingOptions = []
        contentView.safeAreaRegions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = contentView
        window.setFrame(NSRect(origin: .zero, size: Self.windowSize), display: false)
        window.minSize = Self.windowSize
        window.maxSize = Self.windowSize
        self.window = window
        return window
    }
}

enum MenuBarStatusItemPolicy {
    static func shouldShow(showInMenuBar: Bool, isPreviewMode: Bool) -> Bool {
        showInMenuBar && !isPreviewMode
    }
}

enum MenuBarClickRoute: Equatable {
    case openSettings
    case showContextMenu

    static func resolve(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags
    ) -> MenuBarClickRoute? {
        if eventType == .rightMouseUp || (eventType == .leftMouseUp && modifierFlags.contains(.control)) {
            return .showContextMenu
        }
        if eventType == .leftMouseUp { return .openSettings }
        return nil
    }
}
#endif
