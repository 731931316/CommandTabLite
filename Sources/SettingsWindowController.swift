import AppKit

/// Configures the shortcut and persistent rules for currently running applications.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// Catalog supplying applications and their saved rules.
    private let catalog: ApplicationCatalog
    /// Controller that applies shortcut changes and restores native shortcuts.
    private let hotkeys: HotkeyController
    /// Refreshes the menu bar shortcut description after a successful change.
    var onShortcutChanged: (() -> Void)?
    /// Running applications represented by table rows.
    private var applications: [NSRunningApplication] = []
    /// Available modifier combinations; Shift is reserved for reverse navigation.
    private let modifierChoice = NSPopUpButton()
    /// Available primary shortcut keys.
    private let keyChoice = NSPopUpButton()
    /// Shows the outcome of applying a shortcut.
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    /// Explains how to hold and release the selected shortcut.
    private let shortcutHint = NSTextField(wrappingLabelWithString: "")
    /// Table listing the running applications and their rules.
    private let table = NSTableView()
    /// Reads and changes the system's main-app login item registration.
    private let launchAtLogin = LaunchAtLoginController()
    /// Controls the user's request to launch after login.
    private let loginToggle = NSButton(checkboxWithTitle: "登录时自动启动", target: nil, action: nil)
    /// Displays the actual system login-item status or registration error.
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    /// Opens macOS approval controls when the registration needs approval.
    private let loginSettingsButton = NSButton(title: "打开系统登录项设置", target: nil, action: nil)
    /// Refreshes system approval changes when returning from System Settings.
    private var activationObserver: NSObjectProtocol?
    /// Workspace notifications keeping the running list current.
    private var observers: [NSObjectProtocol] = []

    /// Builds the settings window and observes application launch and termination.
    init(catalog: ApplicationCatalog, hotkeys: HotkeyController) {
        self.catalog = catalog
        self.hotkeys = hotkeys
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "程序切换设置"
        window.minSize = NSSize(width: 660, height: 540)
        window.center()
        super.init(window: window)
        buildInterface()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.refreshLoginStatus()
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard self?.window?.isVisible == true else { return }
                self?.reloadApplications()
            })
        }
    }

    /// This window is created in code instead of a storyboard.
    required init?(coder: NSCoder) { nil }

    /// Removes workspace observers when the settings controller is released.
    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// Refreshes the current shortcut and running applications before showing settings.
    func present() {
        synchronizeShortcutControls()
        refreshLoginStatus()
        reloadApplications()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Builds the shortcut editor above the application rules table.
    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        let shortcutTitle = NSTextField(labelWithString: "切换快捷键")
        shortcutTitle.font = .boldSystemFont(ofSize: 14)
        root.addArrangedSubview(shortcutTitle)
        modifierChoice.addItems(withTitles: ShortcutConfiguration.modifierOptions.map { $0.0 })
        keyChoice.addItems(withTitles: ShortcutConfiguration.keyOptions.map { $0.0 })
        let apply = NSButton(title: "应用快捷键", target: self, action: #selector(applyShortcut))
        let reset = NSButton(title: "恢复 Control + Tab", target: self, action: #selector(resetShortcut))
        let shortcutRow = NSStackView(views: [modifierChoice, NSTextField(labelWithString: "+"), keyChoice, apply, reset])
        shortcutRow.spacing = 8
        root.addArrangedSubview(shortcutRow)
        modifierChoice.widthAnchor.constraint(equalToConstant: 160).isActive = true
        keyChoice.widthAnchor.constraint(equalToConstant: 90).isActive = true
        shortcutHint.font = .systemFont(ofSize: 12)
        shortcutHint.textColor = .secondaryLabelColor
        root.addArrangedSubview(shortcutHint)
        shortcutHint.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        shortcutStatus.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(shortcutStatus)
        shortcutStatus.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        loginToggle.target = self
        loginToggle.action = #selector(loginPreferenceChanged(_:))
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginSettings)
        let loginRow = NSStackView(views: [loginToggle, loginSettingsButton])
        loginRow.spacing = 12
        root.addArrangedSubview(loginRow)
        loginStatus.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(loginStatus)
        loginStatus.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        refreshLoginStatus()

        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let rulesTitle = NSTextField(labelWithString: "正在运行的程序")
        rulesTitle.font = .boldSystemFont(ofSize: 14)
        let refresh = NSButton(title: "刷新列表", target: self, action: #selector(refreshApplications))
        let heading = NSStackView(views: [rulesTitle, refresh])
        heading.spacing = 12
        root.addArrangedSubview(heading)
        let explanation = NSTextField(wrappingLabelWithString: "默认“始终显示”；“仅有窗口时显示”包含最小化窗口。修改立即保存，重启后仍有效；关闭程序不会删除规则。开启“按窗口拆分”后，每个独立窗口各占一项。本程序不参与切换。")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        root.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        for (identifier, title, width) in [("application", "程序", 265.0), ("visibility", "显示策略", 220.0), ("split", "按窗口拆分", 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 44
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.selectionHighlightStyle = .none
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        synchronizeShortcutControls()
    }

    /// Displays system registration rather than assuming a saved checkbox is effective.
    private func refreshLoginStatus(clearError: Bool = true) {
        if clearError { launchAtLogin.refresh() }
        loginToggle.allowsMixedState = launchAtLogin.isStatusUnknown
        loginToggle.state = launchAtLogin.isStatusUnknown ? .mixed
            : (launchAtLogin.isEnabled || launchAtLogin.requiresApproval ? .on : .off)
        loginStatus.stringValue = launchAtLogin.errorDescription ?? launchAtLogin.statusText
        loginStatus.textColor = launchAtLogin.errorDescription == nil ? .secondaryLabelColor : .systemRed
        loginSettingsButton.isHidden = !launchAtLogin.requiresApproval && !launchAtLogin.isStatusUnknown
    }

    /// Registers or unregisters only in response to the user's checkbox change.
    @objc private func loginPreferenceChanged(_ sender: NSButton) {
        _ = launchAtLogin.setEnabled(sender.state == .on)
        refreshLoginStatus(clearError: false)
    }

    /// Opens the system approval page for a pending login item.
    @objc private func openLoginSettings() { launchAtLogin.openSystemSettings() }

    /// Selects controls matching the saved shortcut and explains Command-Tab takeover.
    private func synchronizeShortcutControls() {
        let current = hotkeys.currentShortcut
        if let index = ShortcutConfiguration.modifierOptions.firstIndex(where: { $0.1 == current.modifiers }) { modifierChoice.selectItem(at: index) }
        if let index = ShortcutConfiguration.keyOptions.firstIndex(where: { $0.1 == current.keyCode }) { keyChoice.selectItem(at: index) }
        shortcutHint.stringValue = "当前：\(current.displayName)。保持修饰键并重复按主键切换，Shift 选上一个，松开保持键确认。Command + Tab 会接管系统切换；改用其他快捷键或退出时恢复。"
    }

    /// Attempts to apply a new combination; the controller keeps the previous binding on failure.
    @objc private func applyShortcut() {
        let modifiers = ShortcutConfiguration.modifierOptions[modifierChoice.indexOfSelectedItem].1
        let keyCode = ShortcutConfiguration.keyOptions[keyChoice.indexOfSelectedItem].1
        apply(ShortcutConfiguration(keyCode: keyCode, modifiers: modifiers))
    }

    /// Restores and saves the requested Control-Tab default.
    @objc private func resetShortcut() { apply(.default) }

    /// Reports the shortcut result and refreshes the effective configuration.
    private func apply(_ shortcut: ShortcutConfiguration) {
        if hotkeys.apply(shortcut) {
            shortcutStatus.stringValue = "已保存：\(hotkeys.currentShortcut.displayName)，下次启动继续使用。"
            shortcutStatus.textColor = .systemGreen
            onShortcutChanged?()
        } else {
            shortcutStatus.stringValue = hotkeys.errorDescription ?? "无法应用快捷键。"
            shortcutStatus.textColor = .systemRed
        }
        synchronizeShortcutControls()
    }

    /// Rebuilds the visible list without discarding saved rules for closed applications.
    private func reloadApplications() {
        // Settings share one saved rule per bundle, even when automation starts another process.
        applications = ApplicationCatalog.uniqueApplications(catalog.runningApplications()).sorted {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
        }
        table.reloadData()
    }

    /// Refreshes the running list on request.
    @objc private func refreshApplications() { reloadApplications() }

    /// Returns the count of running applications represented in the table.
    func numberOfRows(in tableView: NSTableView) -> Int { applications.count }

    /// Creates an application name, visibility choice, or window-splitting checkbox.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = applications[row]
        guard let id = app.bundleIdentifier else { return nil }
        switch tableColumn?.identifier.rawValue {
        case "visibility":
            let choice = NSPopUpButton()
            // Saved identifiers are stable and may have gaps, so menu positions must not be used as rule values.
            for rule in VisibilityRule.allCases {
                choice.addItem(withTitle: rule.title)
                choice.lastItem?.tag = rule.rawValue
            }
            choice.selectItem(withTag: catalog.ruleStore.rule(for: id).rawValue)
            choice.identifier = NSUserInterfaceItemIdentifier(id)
            choice.target = self
            choice.action = #selector(ruleChanged(_:))
            return choice
        case "split":
            let toggle = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(splitChanged(_:)))
            toggle.identifier = NSUserInterfaceItemIdentifier(id)
            toggle.state = catalog.ruleStore.splitWindows(for: id) ? .on : .off
            return toggle
        default:
            let icon = NSImageView(image: app.icon ?? NSImage())
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
            let title = NSTextField(labelWithString: app.localizedName ?? id)
            title.lineBreakMode = .byTruncatingTail
            let cell = NSStackView(views: [icon, title])
            cell.spacing = 8
            cell.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
            cell.toolTip = id
            return cell
        }
    }

    /// Saves one application's display policy immediately.
    @objc private func ruleChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue, let item = sender.selectedItem,
              let rule = VisibilityRule(rawValue: item.tag) else {
            log.warning("Ignored a visibility selection without a valid saved rule identifier")
            return
        }
        catalog.ruleStore.set(rule, for: id)
        log.info("Saved application visibility rule")
    }

    /// Saves whether an application's windows appear as separate candidates.
    @objc private func splitChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        catalog.ruleStore.setSplitWindows(sender.state == .on, for: id)
        log.info("Saved application window-splitting rule")
    }
}
