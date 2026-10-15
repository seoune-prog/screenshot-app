import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private let store = CaptureStore.shared
    private let stack = ThumbnailStack()
    private var capturing = false
    private let popover = NSPopover()
    private lazy var history = HistoryHost(actions: HistoryActions(
        captureRegion: { [weak self] in self?.closePopover(); self?.capture(fullScreen: false) },
        captureScreen: { [weak self] in self?.closePopover(); self?.capture(fullScreen: true) },
        markup: { [weak self] url in self?.closePopover(); EditorWindowController.open(url) },
        clearToday: { [weak self] in self?.clearToday() },
        openFolder: { [weak self] in self?.openFolder() },
        isLoginItem: { SMAppService.mainApp.status == .enabled },
        setLoginItem: { [weak self] on in self?.setLoginItem(on) },
        openSettings: { [weak self] in self?.closePopover(); SettingsWindow.show() },
        pin: { [weak self] url in self?.closePopover(); PinWindow.pin(url) }
    ))
    private var outsideClickMonitor: Any?

    /// 저장하지 않은 편집이 있으면 종료 전에 하나씩 묻는다
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        EditorWindowController.confirmCloseAll() ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        store.start()
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.contentViewController = history
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true

        NotificationCenter.default.addObserver(forName: Clipboard.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.flashMenuBarCheck()
        }

        stack.onOpen = { url in
            if Prefs.clickAction == .copy { Clipboard.copy(url) } else { EditorWindowController.open(url) }
        }
        registerHotKeys()
        NotificationCenter.default.addObserver(forName: Prefs.didChange, object: nil, queue: .main) { [weak self] note in
            // 단축키를 새로 받는 동안에는 기존 단축키가 키를 가로채지 않게 잠시 푼다
            if note.object as? String == "recording" { self?.hotKeys = [] } else { self?.registerHotKeys() }
        }

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        if ProcessInfo.processInfo.environment["SNAPSTACK_DEMO_SETTINGS"] != nil { SettingsWindow.show() }
        QA.run()
        if let demo = ProcessInfo.processInfo.environment["SNAPSTACK_DEMO"] {
            demoPush(demo)
        }
    }

    /// 앱 아이콘과 같은 모양(선택 모서리 + 겹친 카드)의 템플릿 이미지
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let corners = NSBezierPath()
            corners.lineWidth = 1.6
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            let r = NSRect(x: 1.5, y: 2, width: 15, height: 14)
            let arm: CGFloat = 4
            for (p, dx, dy) in [
                (NSPoint(x: r.minX, y: r.minY), 1.0, 1.0), (NSPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                (NSPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (NSPoint(x: r.maxX, y: r.maxY), -1.0, -1.0),
            ] {
                corners.move(to: NSPoint(x: p.x, y: p.y + dy * arm))
                corners.line(to: p)
                corners.line(to: NSPoint(x: p.x + dx * arm, y: p.y))
            }
            corners.stroke()
            let back = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 7.5, width: 7.5, height: 5.5), xRadius: 1.2, yRadius: 1.2)
            back.lineWidth = 1.2
            back.stroke()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 5, width: 7.5, height: 5.5), xRadius: 1.2, yRadius: 1.2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 맥 기본 스크린샷 단축키 자리를 대신한다. 시스템 단축키가 켜져 있으면 시스템이 먼저 가져간다
    private func registerHotKeys() {
        hotKeys = []
        var failed: Set<String> = []
        let wanted: [(String, Shortcut?, UInt32, () -> Void)] = [
            ("screenShortcut", Prefs.screenShortcut, 1, { [weak self] in self?.capture(fullScreen: true) }),
            ("regionShortcut", Prefs.regionShortcut, 2, { [weak self] in self?.capture(fullScreen: false) }),
            ("textShortcut", Prefs.textShortcut, 3, { [weak self] in self?.captureText() }),
        ]
        for (name, shortcut, id, action) in wanted {
            guard let shortcut else { continue }
            if let key = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id, handler: action) {
                hotKeys.append(key)
            } else {
                failed.insert(name)
            }
        }
        HotKeyStatus.failed = failed
    }

    /// 영역을 골라 글자만 클립보드에 넣는다. 이미지는 기록에 남기지 않는다
    func captureText() {
        guard !capturing else { return }
        guard CGPreflightScreenCaptureAccess() else { return askScreenPermission() }
        capturing = true
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("snapstack-ocr-\(UUID().uuidString).png")
        Capture.region(to: temp) { [weak self] url in
            self?.capturing = false
            guard let url else { return }
            TextRecognizer.recognize(url) { text in
                try? FileManager.default.removeItem(at: url)
                TextRecognizer.deliver(text)
            }
        }
    }

    func capture(fullScreen: Bool) {
        guard !capturing else { return }
        guard CGPreflightScreenCaptureAccess() else { return askScreenPermission() }
        capturing = true
        let dest = store.newFileURL()
        var sourceFrame: NSRect?
        let done: (URL?) -> Void = { [weak self] url in
            guard let self else { return }
            self.capturing = false
            guard let url else { return }
            self.store.add(url)
            if Prefs.copyAfterCapture { Clipboard.copy(url) }
            if Prefs.showThumbnail { self.stack.push(url, flyFrom: sourceFrame) }
            if let folder = Prefs.saveCopyFolder { Self.saveCopy(url, to: folder) }
        }
        if fullScreen {
            sourceFrame = Capture.screen(to: dest, completion: done)?.frame
        } else {
            Capture.region(to: dest, completion: done)
        }
    }

    /// 설정한 폴더에 맥 기본 이름으로 사본을 둔다. 같은 이름이 있으면 번호를 붙인다
    private static func saveCopy(_ url: URL, to folder: URL) {
        let base = ExportName.displayName(for: url)
        var dest = folder.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    /// 권한이 없으면 바탕화면만 찍히므로 캡처하기 전에 막고 설정으로 안내한다
    private func askScreenPermission() {
        CGRequestScreenCaptureAccess()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "화면 기록 권한 필요"
        alert.informativeText = "시스템 설정에서 SnapStack을 켠 뒤 앱을 다시 실행해 주세요."
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// 복사될 때마다 메뉴바 아이콘이 잠깐 체크로 바뀐다
    private var menuBarReset: DispatchWorkItem?
    private func flashMenuBarCheck() {
        guard Prefs.menuBarFeedback, let button = statusItem?.button else { return }
        let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "복사됨")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        check?.isTemplate = true
        button.image = check
        menuBarReset?.cancel()
        let work = DispatchWorkItem { button.image = Self.menuBarIcon() }
        menuBarReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// 화면 기록 권한 없이 썸네일·편집 화면을 확인할 때 쓴다. 쉼표로 여러 장을 넘긴다.
    private func demoPush(_ paths: String) {
        for (i, path) in paths.split(separator: ",").enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(i)) { [weak self] in
                guard let self else { return }
                let dest = self.store.newFileURL()
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: String(path)), to: dest)
                self.store.add(dest)
                Clipboard.copy(dest)
                let fly = ProcessInfo.processInfo.environment["SNAPSTACK_DEMO_FLY"] != nil ? NSScreen.main?.frame : nil
                self.stack.push(dest, flyFrom: fly)
                if ProcessInfo.processInfo.environment["SNAPSTACK_DEMO_EDIT"] != nil, i == 0 {
                    EditorWindowController.open(dest)
                    EditorWindowController.demoSave(dest)
                }
                if ProcessInfo.processInfo.environment["SNAPSTACK_DEMO_HISTORY"] != nil, i == paths.split(separator: ",").count - 1 {
                    if ProcessInfo.processInfo.environment["SNAPSTACK_DEMO_REAL_POPOVER"] == nil { self.popover.behavior = .applicationDefined }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.togglePopover() }
                }
            }
        }
    }

    // MARK: 메뉴바

    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        history.didClose()
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePopover()
            return showQuickMenu()
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        // 앱을 통째로 활성화하면 열려 있던 설정·편집 창까지 앞으로 튀어나온다.
        // 팝오버 창만 키 창으로 만들어 키보드 조작을 받는다
        defer { popover.contentViewController?.view.window?.makeKey() }
        history.willShow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 메뉴바 앱은 다른 앱을 클릭해도 팝오버가 안 닫힐 때가 있어 바깥 클릭을 직접 본다
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "영역 캡처") { [weak self] in self?.capture(fullScreen: false) })
        menu.addItem(ClosureMenuItem(title: "전체화면 캡처") { [weak self] in self?.capture(fullScreen: true) })
        menu.addItem(ClosureMenuItem(title: "텍스트 인식") { [weak self] in self?.captureText() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "보관 폴더 열기") { [weak self] in self?.openFolder() })
        menu.addItem(ClosureMenuItem(title: "설정…") { SettingsWindow.show() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "SnapStack 종료") { NSApp.terminate(nil) })
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func clearToday() {
        let alert = NSAlert()
        alert.messageText = "오늘 기록 \(store.todayItems.count)장 비우기"
        alert.addButton(withTitle: "비우기")
        alert.addButton(withTitle: "취소")
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.clearToday() }
    }

    private func openFolder() {
        closePopover()
        try? FileManager.default.createDirectory(at: store.todayDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.todayDir)
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // 편집 창의 ⌘Z·⌘C·⌘S 등 단축키가 동작하려면 메인 메뉴가 있어야 한다
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let settings = ClosureMenuItem(title: "설정…") { SettingsWindow.show() }
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        submenu("SnapStack", [settings, .separator(), item("SnapStack 종료", #selector(NSApplication.terminate(_:)), "q")])
        submenu("파일", [
            item("저장", #selector(EditorWindowController.saveDocument(_:)), "s"),
            item("다른 이름으로 저장", #selector(EditorWindowController.saveDocumentAs(_:)), "s", [.command, .shift]),
            item("완료", #selector(EditorWindowController.finishEditing(_:)), "\r"),
            item("닫기", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("편집", [
            item("실행 취소", Selector(("undo:")), "z"),
            item("다시 실행", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("잘라내기", #selector(NSText.cut(_:)), "x"),
            item("복사", #selector(NSText.copy(_:)), "c"),
            item("텍스트 복사", #selector(EditorWindowController.copyText(_:)), "c", [.command, .shift]),
            item("붙여넣기", #selector(NSText.paste(_:)), "v"),
            item("전체 선택", #selector(NSText.selectAll(_:)), "a"),
        ])
        return main
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        if !key.isEmpty { keyEquivalentModifierMask = [.command, .shift] }
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
