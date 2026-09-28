import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import OSLog

/// 保存用户选择的 Carbon 快捷键；Shift 专用于反向选择。
struct ShortcutConfiguration: Codable, Equatable {
    /// Carbon 虚拟按键码。
    var keyCode: UInt32
    /// Carbon 修饰键掩码。
    var modifiers: UInt32
    /// 首次启动使用的快捷键。
    static let `default` = ShortcutConfiguration(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey))

    /// 设置界面支持的修饰键组合，Shift 留给反向选择。
    static let modifierOptions: [(String, UInt32)] = [
        ("Control", UInt32(controlKey)), ("Option", UInt32(optionKey)), ("Command", UInt32(cmdKey)),
        ("Control + Option", UInt32(controlKey | optionKey)), ("Control + Command", UInt32(controlKey | cmdKey)),
        ("Option + Command", UInt32(optionKey | cmdKey)), ("Control + Option + Command", UInt32(controlKey | optionKey | cmdKey))
    ]
    /// 设置界面支持的普通按键，使用系统虚拟按键码保存。
    static let keyOptions: [(String, UInt32)] = [
        ("Tab", 48), ("Space", 49), ("`", 50),
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5),
        ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45),
        ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32),
        ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
        ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
        ("6", 22), ("7", 26), ("8", 28), ("9", 25),
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97),
        ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111)
    ]

    /// 仅完全匹配 Command+Tab 时接管系统程序切换。
    var isCommandTab: Bool { keyCode == UInt32(kVK_Tab) && modifiers == UInt32(cmdKey) }

    /// 排除保留的 Shift、单独修饰键和没有保持修饰键的组合。
    var isValid: Bool {
        let allowed = UInt32(cmdKey | controlKey | optionKey)
        let modifierCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        return modifiers != 0 && modifiers & ~allowed == 0 && keyCode <= 126 && !modifierCodes.contains(keyCode)
    }

    /// 配置界面与菜单显示的快捷键名称。
    var displayName: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
            22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K",
            41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
            50: "`", 51: "Delete", 53: "Esc", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 109: "F10", 111: "F12", 115: "Home", 116: "Page Up", 117: "⌦",
            118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return text + (names[keyCode] ?? "键 \(keyCode)")
    }

    /// 判断组合要求的保持修饰键是否全部仍然按下。
    func isHeld(in flags: CGEventFlags) -> Bool {
        if modifiers & UInt32(cmdKey) != 0 && !flags.contains(.maskCommand) { return false }
        if modifiers & UInt32(controlKey) != 0 && !flags.contains(.maskControl) { return false }
        if modifiers & UInt32(optionKey) != 0 && !flags.contains(.maskAlternate) { return false }
        return true
    }
}

/// 按原始启用状态接管和恢复系统 Command+Tab 的两个方向。
final class NativeShortcutControl {
    /// SkyLight 修改系统快捷键的函数签名。
    private typealias SetHotkey = @convention(c) (Int32, Bool) -> Int32
    /// SkyLight 查询系统快捷键的函数签名。
    private typealias ReadHotkey = @convention(c) (Int32) -> Bool
    /// 保持动态库加载，确保函数指针有效。
    private let framework: UnsafeMutableRawPointer?
    /// 动态解析的设置函数。
    private let setHotkey: SetHotkey?
    /// 动态解析的查询函数。
    private let readHotkey: ReadHotkey?
    /// 接管前的状态；恢复失败的项目会保留以便重试。
    private var originalStates: [Int32: Bool] = [:]

    /// 动态读取私有 API；缺少查询能力时拒绝接管以保护原配置。
    init() {
        framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        if let framework, let symbol = dlsym(framework, "CGSSetSymbolicHotKeyEnabled") {
            setHotkey = unsafeBitCast(symbol, to: SetHotkey.self)
        } else { setHotkey = nil }
        if let framework, let symbol = dlsym(framework, "CGSIsSymbolicHotKeyEnabled") {
            readHotkey = unsafeBitCast(symbol, to: ReadHotkey.self)
        } else { readHotkey = nil }
    }

    /// 记录两个方向的原值后禁用；部分失败立即恢复。
    func takeOver() -> Bool {
        guard let setHotkey, let readHotkey else {
            log.error("System shortcut APIs unavailable")
            return false
        }
        guard restore() else { return false }
        for id: Int32 in [1, 2] { originalStates[id] = readHotkey(id) }
        for id: Int32 in [1, 2] {
            let status = setHotkey(id, false)
            guard status == 0, !readHotkey(id) else {
                log.error("System shortcut takeover failed: id=\(id), status=\(status)")
                _ = restore()
                return false
            }
        }
        log.info("System Command-Tab takeover enabled")
        return true
    }

    /// 仅供显式命令行紧急恢复使用；正常退出通过 restore 恢复原始状态。
    @discardableResult
    func setSystemSwitcherEnabled(_ enabled: Bool) -> Bool {
        guard let setHotkey, let readHotkey else { return false }
        let forward = setHotkey(1, enabled)
        let backward = setHotkey(2, enabled)
        let succeeded = forward == 0 && backward == 0 && readHotkey(1) == enabled && readHotkey(2) == enabled
        if !succeeded { log.error("Explicit system shortcut recovery failed") }
        return succeeded
    }

    /// 逐项恢复实际接管前的状态，不修改原本禁用的系统快捷键。
    @discardableResult
    func restore() -> Bool {
        guard !originalStates.isEmpty else { return true }
        guard let setHotkey, let readHotkey else { return false }
        for (id, enabled) in originalStates {
            let status = setHotkey(id, enabled)
            if status == 0 && readHotkey(id) == enabled {
                originalStates.removeValue(forKey: id)
            } else {
                log.error("System shortcut restoration failed: id=\(id), status=\(status)")
            }
        }
        return originalStates.isEmpty
    }
}

/// 注册用户快捷键，并处理反向选择、修饰键释放及系统快捷键恢复。
final class HotkeyController {
    /// 持久化快捷键的偏好设置键。
    private static let storageKey = "SwitcherShortcutConfiguration"
    /// 保存配置的偏好域，允许验证时使用独立域而不改动用户设置。
    private let defaults: UserDefaults
    /// Carbon 回调使用的程序标识。
    private let signature: OSType = 0x43544C54
    /// 系统快捷键接管管理器。
    private let native = NativeShortcutControl()
    /// 候选浮层。
    private let panel: SwitcherPanel
    /// 候选数据源。
    private let catalog: ApplicationCatalog
    /// 已注册的正反向快捷键。
    private var hotkeys: [EventHotKeyRef] = []
    /// Carbon 事件处理器。
    private var eventHandler: EventHandlerRef?
    /// 监听修饰键变化的事件端口。
    private var eventTap: CFMachPort?
    /// 主线程事件端口来源。
    private var eventSource: CFRunLoopSource?
    /// 正常终止信号的清理来源。
    private var signalSources: [DispatchSourceSignal] = []
    /// 当前生效或待启用的快捷键。
    private(set) var currentShortcut: ShortcutConfiguration
    /// 可供设置界面显示的中文错误。
    private(set) var errorDescription: String?
    /// 当前是否已经注册快捷键。
    private(set) var isEnabled = false
    /// 避免 Shift 长按重复后退。
    private var shiftWasDown = false
    /// 防止清理后的异步事件提交旧选择。
    private var generation = 0

    /// 加载永久设置，并准备正常终止时的恢复处理。
    init(panel: SwitcherPanel, catalog: ApplicationCatalog, defaults: UserDefaults = .standard) {
        self.panel = panel
        self.catalog = catalog
        self.defaults = defaults
        if let saved = defaults.data(forKey: Self.storageKey),
           let config = try? JSONDecoder().decode(ShortcutConfiguration.self, from: saved), config.isValid {
            currentShortcut = config
        } else { currentShortcut = .default }
        installSignalCleanup()
    }

    /// 启用快捷键；任意步骤失败都会释放注册并恢复系统快捷键。
    func start() -> Bool {
        guard !isEnabled else { return true }
        errorDescription = nil
        guard currentShortcut.isValid else { return fail("快捷键须包含 Control、Option 或 Command，Shift 保留用于反向选择。") }
        guard AXIsProcessTrusted() else { return fail("请先在系统设置中允许本程序使用“辅助功能”。") }
        // 在接管系统快捷键前，先验证修饰键监听可用。
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let tapCallback: CGEventTapCallBack = { _, type, event, userData in
            guard let userData else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.errorDescription = "按键监听已中断，已停用切换并恢复系统快捷键，请重新启用。"
                log.error("Modifier event tap disabled; restoring system shortcuts")
                owner.stop()
                return Unmanaged.passUnretained(event)
            }
            owner.handleFlags(event.flags)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                         eventsOfInterest: mask, callback: tapCallback, userInfo: pointer) else {
            return fail("无法监听修饰键，请检查辅助功能权限后重新启用。")
        }
        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return fail("无法启动按键监听。")
        }
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { return fail("按键监听未能启用。") }
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let owner = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            guard id.signature == owner.signature, owner.isEnabled else { return noErr }
            let generation = owner.generation
            // 排队处理 UI，丢弃换键或停用之前尚未执行的回调。
            DispatchQueue.main.async { [weak owner] in
                guard let owner, owner.isEnabled, owner.generation == generation else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                owner.shiftWasDown = flags.contains(.maskShift)
                owner.panel.advance(id.id == 2 ? -1 : 1, using: owner.catalog)
                // 快速按下再松开时，松键事件可能早于 UI 回调，需立即确认。
                if !owner.currentShortcut.isHeld(in: flags) { owner.panel.commit() }
            }
            return noErr
        }
        let handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), callback, eventTypes.count, &eventTypes, pointer, &eventHandler)
        guard handlerStatus == noErr else { return fail("无法创建快捷键处理器（\(handlerStatus)）。") }
        // 精确选择 Command+Tab 才修改系统快捷键；注册失败仍能回滚。
        if currentShortcut.isCommandTab && !native.takeOver() { return fail("无法接管系统 Command+Tab，已尝试恢复原设置。") }
        for (id, modifiers) in [(UInt32(1), currentShortcut.modifiers), (UInt32(2), currentShortcut.modifiers | UInt32(shiftKey))] {
            var hotkey: EventHotKeyRef?
            // Dock keeps its registration even when its symbolic keys are disabled; Command-Tab must use AltTab's nonexclusive registration.
            let options: OptionBits = currentShortcut.isCommandTab ? 0 : OptionBits(kEventHotKeyExclusive)
            let status = RegisterEventHotKey(currentShortcut.keyCode, modifiers, EventHotKeyID(signature: signature, id: id),
                                             GetEventDispatcherTarget(), options, &hotkey)
            guard status == noErr, let hotkey else { return fail("快捷键注册失败，可能已被系统或其他程序占用（\(status)）。") }
            hotkeys.append(hotkey)
        }
        shiftWasDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        isEnabled = true
        log.info("Switcher shortcut enabled: \(self.currentShortcut.displayName, privacy: .public)")
        return true
    }

    /// 原子地尝试新快捷键，注册成功才保存；失败恢复旧注册及偏好设置。
    func apply(_ shortcut: ShortcutConfiguration) -> Bool {
        guard shortcut.isValid else {
            errorDescription = "快捷键须包含 Control、Option 或 Command，Shift 保留用于反向选择。"
            return false
        }
        let oldShortcut = currentShortcut
        let wasEnabled = isEnabled
        stop()
        currentShortcut = shortcut
        if start() {
            if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: Self.storageKey) }
            log.info("Shortcut preference saved")
            return true
        }
        let failure = errorDescription ?? "无法应用快捷键。"
        currentShortcut = oldShortcut
        if wasEnabled && !start() {
            errorDescription = failure + " 原快捷键也未能恢复，请检查权限或快捷键冲突后重新启用。"
            log.error("Previous shortcut registration could not be restored")
        } else { errorDescription = failure }
        return false
    }

    /// 先恢复系统快捷键，再释放所有事件来源并取消浮层。
    func stop() {
        generation += 1
        if !native.restore() {
            errorDescription = "系统快捷键恢复失败，请退出后重新启动本程序；若仍不可用，请注销并重新登录。"
            log.error("Unable to restore original system shortcuts")
        }
        isEnabled = false
        panel.dismiss()
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        eventSource = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        eventTap = nil
        for hotkey in hotkeys { UnregisterEventHotKey(hotkey) }
        hotkeys.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        shiftWasDown = false
    }

    /// 统一记录失败并回收部分初始化的资源。
    private func fail(_ message: String) -> Bool {
        errorDescription = message
        log.error("Shortcut setup failed: \(message, privacy: .public)")
        stop()
        return false
    }

    /// 保持键释放即确认，单独按 Shift 时选择上一个候选。
    private func handleFlags(_ flags: CGEventFlags) {
        let shiftDown = flags.contains(.maskShift)
        defer { shiftWasDown = shiftDown }
        guard isEnabled, panel.isShowingCandidates else { return }
        if !currentShortcut.isHeld(in: flags) {
            panel.commit()
        } else if shiftDown && !shiftWasDown {
            panel.advance(-1, using: catalog)
        }
    }

    /// 将可捕获的终止信号送到主线程，完成系统设置恢复后再退出。
    private func installSignalCleanup() {
        for code in [SIGTERM, SIGINT, SIGHUP] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { [weak self] in
                log.info("Termination signal received: \(code)")
                self?.stop()
                exit(128 + code)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
