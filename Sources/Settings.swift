import AppKit
import Carbon
import ServiceManagement
import SwiftUI

/// 전역 단축키 하나. 키 코드와 Carbon 수식키, 화면에 보일 글자를 함께 둔다.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var key: String

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    static let region = Shortcut(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey, key: "4")
    static let screen = Shortcut(keyCode: kVK_ANSI_3, modifiers: cmdKey | shiftKey, key: "3")
    static let text = Shortcut(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey, key: "2")
}

enum ThumbnailCorner: String, CaseIterable { case bottomLeft, bottomRight }
enum ClickAction: String, CaseIterable { case edit, copy }

/// 사용자가 바꿀 수 있는 값. 기본값은 처음 만들 때 정한 동작 그대로다.
enum Prefs {
    static let didChange = Notification.Name("SnapStackPrefsDidChange")
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "copyAfterCapture": true,
            "windowShadow": true,
            "saveCopy": false,
            "showThumbnail": true,
            "thumbnailCorner": ThumbnailCorner.bottomLeft.rawValue,
            "thumbnailSeconds": 10,
            "maxThumbnails": 6,
            "clickAction": ClickAction.edit.rawValue,
            "retentionDays": 1,
            "dailyLimit": 10_000,
            "defaultColor": 0,
            "haptics": true,
            "menuBarFeedback": true,
        ])
    }

    static var regionShortcut: Shortcut? { shortcut("regionShortcut") ?? .region }
    static var screenShortcut: Shortcut? { shortcut("screenShortcut") ?? .screen }
    static var textShortcut: Shortcut? { shortcut("textShortcut") ?? .text }
    static var copyAfterCapture: Bool { d.bool(forKey: "copyAfterCapture") }
    static var windowShadow: Bool { d.bool(forKey: "windowShadow") }
    static var saveCopyFolder: URL? {
        guard d.bool(forKey: "saveCopy"), let path = d.string(forKey: "saveCopyFolder") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static var showThumbnail: Bool { d.bool(forKey: "showThumbnail") }
    static var thumbnailCorner: ThumbnailCorner {
        ThumbnailCorner(rawValue: d.string(forKey: "thumbnailCorner") ?? "") ?? .bottomLeft
    }
    static var thumbnailSeconds: TimeInterval { TimeInterval(max(d.integer(forKey: "thumbnailSeconds"), 2)) }
    static var maxThumbnails: Int { max(d.integer(forKey: "maxThumbnails"), 1) }
    static var clickAction: ClickAction { ClickAction(rawValue: d.string(forKey: "clickAction") ?? "") ?? .edit }
    static var retentionDays: Int { max(d.integer(forKey: "retentionDays"), 1) }
    static var dailyLimit: Int { max(d.integer(forKey: "dailyLimit"), 1) }
    static var defaultColor: Int { d.integer(forKey: "defaultColor") }
    static var haptics: Bool { d.bool(forKey: "haptics") }
    static var menuBarFeedback: Bool { d.bool(forKey: "menuBarFeedback") }

    /// 단축키를 지우면 빈 값으로 저장해 기본값으로 되돌아가지 않게 한다
    private static func shortcut(_ key: String) -> Shortcut?? {
        guard let data = d.data(forKey: key) else { return nil }
        if data.isEmpty { return .some(nil) }
        return .some(try? JSONDecoder().decode(Shortcut.self, from: data))
    }

    static func setShortcut(_ value: Shortcut?, for key: String) {
        d.set(value.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
        NotificationCenter.default.post(name: didChange, object: key)
    }
}

// MARK: 설정 창

final class SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.title = "SnapStack 설정"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            // 단축키를 받는 도중에 창을 닫아도 입력 대기가 남지 않게 한다
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                ShortcutRecorder.shared.stop()
            }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @AppStorage("copyAfterCapture") private var copyAfterCapture = true
    @AppStorage("windowShadow") private var windowShadow = true
    @AppStorage("saveCopy") private var saveCopy = false
    @AppStorage("saveCopyFolder") private var saveCopyFolder = ""
    @AppStorage("showThumbnail") private var showThumbnail = true
    @AppStorage("thumbnailCorner") private var thumbnailCorner = ThumbnailCorner.bottomLeft.rawValue
    @AppStorage("thumbnailSeconds") private var thumbnailSeconds = 10
    @AppStorage("maxThumbnails") private var maxThumbnails = 6
    @AppStorage("clickAction") private var clickAction = ClickAction.edit.rawValue
    @AppStorage("retentionDays") private var retentionDays = 1
    @AppStorage("dailyLimit") private var dailyLimit = 10_000
    @AppStorage("defaultColor") private var defaultColor = 0
    @AppStorage("haptics") private var haptics = true
    @AppStorage("menuBarFeedback") private var menuBarFeedback = true
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("단축키") {
                LabeledContent("영역 캡처") { ShortcutField(key: "regionShortcut", fallback: .region) }
                LabeledContent("전체화면 캡처") { ShortcutField(key: "screenShortcut", fallback: .screen) }
                LabeledContent("텍스트 인식") { ShortcutField(key: "textShortcut", fallback: .text) }
                Text("맥 기본 스크린샷 단축키와 겹치면 시스템 설정 → 키보드 → 키보드 단축키 → 스크린샷에서 꺼야 합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("캡처") {
                Toggle("캡처 후 클립보드에 복사", isOn: $copyAfterCapture)
                Toggle("창 캡처에 그림자 포함", isOn: $windowShadow)
                Toggle("폴더에 사본 저장", isOn: $saveCopy)
                if saveCopy {
                    LabeledContent("저장 폴더") {
                        HStack {
                            Text(saveCopyFolder.isEmpty ? "선택 안 됨" : (saveCopyFolder as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("선택…", action: chooseFolder)
                        }
                    }
                }
            }

            Section("썸네일") {
                Toggle("캡처 후 썸네일 표시", isOn: $showThumbnail)
                Group {
                    Picker("위치", selection: $thumbnailCorner) {
                        Text("왼쪽 아래").tag(ThumbnailCorner.bottomLeft.rawValue)
                        Text("오른쪽 아래").tag(ThumbnailCorner.bottomRight.rawValue)
                    }
                    Stepper("표시 시간  \(thumbnailSeconds)초", value: $thumbnailSeconds, in: 3...60)
                    Stepper("최대 표시 개수  \(maxThumbnails)장", value: $maxThumbnails, in: 1...10)
                    Picker("클릭하면", selection: $clickAction) {
                        Text("편집기 열기").tag(ClickAction.edit.rawValue)
                        Text("복사만").tag(ClickAction.copy.rawValue)
                    }
                }
                .disabled(!showThumbnail)
            }

            Section("보관") {
                Picker("보관 기간", selection: $retentionDays) {
                    Text("오늘만").tag(1)
                    Text("7일").tag(7)
                    Text("30일").tag(30)
                }
                Picker("하루 최대", selection: $dailyLimit) {
                    Text("100장").tag(100)
                    Text("1,000장").tag(1_000)
                    Text("10,000장").tag(10_000)
                }
                LabeledContent("보관 위치") {
                    Button("Finder에서 열기") { NSWorkspace.shared.open(CaptureStore.shared.root) }
                }
            }

            Section("편집") {
                Picker("기본 색", selection: $defaultColor) {
                    ForEach(Array(EditorWindowController.palette.enumerated()), id: \.offset) { i, item in
                        Text(item.0).tag(i)
                    }
                }
            }

            Section("일반") {
                Toggle("로그인 시 실행", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            loginItem = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("복사할 때 햅틱", isOn: $haptics)
                Toggle("복사할 때 메뉴바 체크 표시", isOn: $menuBarFeedback)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .onChange(of: retentionDays) { _, _ in CaptureStore.shared.reloadForPrefs() }
        .onChange(of: thumbnailCorner) { _, _ in NotificationCenter.default.post(name: Prefs.didChange, object: "thumbnails") }
        .onChange(of: maxThumbnails) { _, _ in NotificationCenter.default.post(name: Prefs.didChange, object: "thumbnails") }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        if panel.runModal() == .OK, let url = panel.url { saveCopyFolder = url.path }
    }
}

/// 단축키 입력은 앱 전체에서 한 번에 하나만 받는다
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()
    @Published private(set) var activeKey: String?
    @Published var message: [String: String] = [:]
    private var monitor: Any?

    static let names: [String: String] = [
        "regionShortcut": "영역 캡처", "screenShortcut": "전체화면 캡처", "textShortcut": "텍스트 인식",
    ]

    func start(_ key: String) {
        stop()
        activeKey = key
        message[key] = nil
        NotificationCenter.default.post(name: Prefs.didChange, object: "recording")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event, for: key)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if activeKey != nil {
            activeKey = nil
            NotificationCenter.default.post(name: Prefs.didChange, object: "recordingEnded")
        }
    }

    private func handle(_ event: NSEvent, for key: String) {
        if event.keyCode == UInt16(kVK_Escape) { return stop() }
        if event.keyCode == UInt16(kVK_Delete) {
            Prefs.setShortcut(nil, for: key)
            return stop()
        }
        let flags = event.modifierFlags
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        // 수식키 없는 단축키는 평소 타이핑을 가로채므로 받지 않는다
        guard mods & (cmdKey | optionKey | controlKey) != 0 else { return }
        let shortcut = Shortcut(keyCode: Int(event.keyCode), modifiers: mods, key: Shortcut.keyName(Int(event.keyCode)))
        if let other = Self.names.keys.first(where: { $0 != key && Prefs.value(for: $0) == shortcut }) {
            message[key] = "\(Self.names[other] ?? "")에서 쓰는 단축키입니다"
            return stop()
        }
        Prefs.setShortcut(shortcut, for: key)
        stop()
    }
}

/// 누르면 다음에 누른 키 조합을 단축키로 받는다. Esc 는 취소, ⌫ 는 지우기.
struct ShortcutField: View {
    let key: String
    let fallback: Shortcut
    @ObservedObject private var recorder = ShortcutRecorder.shared
    @State private var current: Shortcut?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Button(recorder.activeKey == key ? "키 입력…" : (current?.display ?? "없음")) {
                    recorder.activeKey == key ? recorder.stop() : recorder.start(key)
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 90)
                if current != fallback {
                    Button("기본값") {
                        if let other = ShortcutRecorder.names.keys.first(where: { $0 != key && Prefs.value(for: $0) == fallback }) {
                            recorder.message[key] = "\(ShortcutRecorder.names[other] ?? "")에서 쓰는 단축키입니다"
                        } else {
                            Prefs.setShortcut(fallback, for: key)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let text = recorder.message[key] ?? (failed ? "다른 앱이 쓰고 있어 등록하지 못했습니다" : nil) {
                Text(text).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: Prefs.didChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: HotKeyStatus.didRegister)) { _ in refresh() }
    }

    private func refresh() {
        current = Prefs.value(for: key)
        failed = HotKeyStatus.failed.contains(key)
    }
}

/// 등록에 실패한 단축키(다른 앱이 이미 쓰는 조합)를 설정 화면에 알린다
enum HotKeyStatus {
    static let didRegister = Notification.Name("SnapStackHotKeysRegistered")
    static var failed: Set<String> = [] {
        didSet { NotificationCenter.default.post(name: didRegister, object: nil) }
    }
}

extension Prefs {
    static func value(for key: String) -> Shortcut? {
        switch key {
        case "regionShortcut": return regionShortcut
        case "screenShortcut": return screenShortcut
        default: return textShortcut
        }
    }
}

extension Shortcut {
    /// 입력 언어(한글 등)나 Shift 와 상관없이 키 위치로 이름을 정한다
    static func keyName(_ code: Int) -> String {
        let table: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return table[code] ?? "#\(code)"
    }
}
