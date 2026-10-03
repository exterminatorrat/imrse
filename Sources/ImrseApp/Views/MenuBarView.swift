#if os(macOS)
import AppKit

@MainActor
enum MenuBarView {
    static func contextMenu(model: AppModel, coordinator: AppCoordinator) -> NSMenu {
        let menu = NSMenu(title: "imrse")
        let transformEnabled = !model.isPreviewMode && model.state != .replacing && model.state != .undoing
        let transformItem = NSMenuItem(
            title: "Transform Selected Text",
            action: #selector(AppCoordinator.invokeFromMenuItem(_:)),
            keyEquivalent: ""
        )
        transformItem.target = coordinator
        transformItem.isEnabled = transformEnabled
        menu.addItem(transformItem)

        if !model.presets.isEmpty {
            let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
            let presetsMenu = NSMenu(title: "Presets")
            for preset in model.presets {
                let item = NSMenuItem(
                    title: MenuTitle.short(preset.name),
                    action: #selector(AppCoordinator.invokeFromMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = coordinator
                item.representedObject = preset.id
                item.isEnabled = transformEnabled
                presetsMenu.addItem(item)
            }
            presetsItem.submenu = presetsMenu
            menu.addItem(presetsItem)
        }

        let undoItem = NSMenuItem(
            title: "Undo Last Change",
            action: #selector(AppCoordinator.undoFromMenuItem(_:)),
            keyEquivalent: ""
        )
        undoItem.target = coordinator
        undoItem.isEnabled = model.canUndo
        menu.addItem(undoItem)

        if let issue = model.shortcutIssue {
            let issueItem = NSMenuItem(title: MenuTitle.short("Shortcut inactive · \(issue)"), action: nil, keyEquivalent: "")
            issueItem.isEnabled = false
            menu.addItem(issueItem)
        }

        menu.addItem(.separator())
        let responseDetailsItem = NSMenuItem(
            title: "Show Response Details",
            action: #selector(AppCoordinator.toggleResponseDetails(_:)),
            keyEquivalent: ""
        )
        responseDetailsItem.target = coordinator
        responseDetailsItem.state = coordinator.showsResponseDetails ? .on : .off
        menu.addItem(responseDetailsItem)

        if coordinator.showsResponseDetails {
            let latestResponseMenu = NSMenu(title: "Latest Response")
            for row in ResponseDetailsFormatter.rows(for: model.latestResponseMetadata) {
                let item = NSMenuItem(title: row.menuTitle, action: nil, keyEquivalent: "")
                item.isEnabled = false
                latestResponseMenu.addItem(item)
            }

            let latestResponseItem = NSMenuItem(title: "Latest Response", action: nil, keyEquivalent: "")
            latestResponseItem.submenu = latestResponseMenu
            menu.addItem(latestResponseItem)
        }

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(AppCoordinator.openSettingsFromMenuItem(_:)),
            keyEquivalent: ""
        )
        settingsItem.target = coordinator
        settingsItem.isEnabled = model.canOpenSettings
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "Quit imrse",
            action: #selector(AppCoordinator.quitFromMenuItem(_:)),
            keyEquivalent: ""
        )
        quitItem.target = coordinator
        menu.addItem(quitItem)
        return menu
    }
}

enum MenuTitle {
    static func short(_ title: String) -> String {
        title.count <= 30 ? title : String(title.prefix(27)) + "…"
    }
}
#endif
