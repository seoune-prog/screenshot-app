import AppKit

/// 날짜별 폴더에 캡처를 보관한다. 보관 기간이 지난 날짜 폴더는 통째로 지운다.
final class CaptureStore {
    static let shared = CaptureStore()
    static let didChange = Notification.Name("SnapStackStoreDidChange")

    let root: URL
    private(set) var items: [URL] = []
    private var day = CaptureStore.dayString(Date())
    private var midnightTimer: Timer?

    private init() {
        // 테스트할 때 실제 기록을 건드리지 않도록 보관 위치를 바꿀 수 있다
        if let override = ProcessInfo.processInfo.environment["SNAPSTACK_ROOT"] {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SnapStack", isDirectory: true)
        }
    }

    var todayDir: URL { root.appendingPathComponent(day, isDirectory: true) }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func start() {
        purgeOldDays()
        load()
        scheduleMidnightReset()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rollIfNeeded() }
    }

    func rollIfNeeded() {
        let today = CaptureStore.dayString(Date())
        guard today != day else { return }
        day = today
        purgeOldDays()
        load()
    }

    func newFileURL() -> URL {
        rollIfNeeded()
        try? FileManager.default.createDirectory(at: todayDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "HHmmss-SSS"
        return todayDir.appendingPathComponent("\(f.string(from: Date())).png")
    }

    func add(_ url: URL) {
        items.append(url)
        let today = items.filter { $0.deletingLastPathComponent().lastPathComponent == day }
        let overflow = today.count - Prefs.dailyLimit
        if overflow > 0 {
            let doomed = Set(today.prefix(overflow))
            doomed.forEach { try? FileManager.default.removeItem(at: $0) }
            items.removeAll { doomed.contains($0) }
        }
        notify(url)
    }

    var todayItems: [URL] { items.filter { $0.deletingLastPathComponent().lastPathComponent == day } }

    func reloadForPrefs() {
        purgeOldDays()
        load()
    }

    func delete(_ urls: [URL]) {
        let doomed = Set(urls)
        doomed.forEach { try? FileManager.default.removeItem(at: $0) }
        items.removeAll { doomed.contains($0) }
        notify(nil)
    }

    func didEdit(_ url: URL) { notify(url) }

    func clearToday() {
        try? FileManager.default.removeItem(at: todayDir)
        items.removeAll { $0.deletingLastPathComponent().lastPathComponent == day }
        notify(nil)
    }

    private func load() {
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.count == 10 }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        items = days.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        notify(nil)
    }

    private func purgeOldDays() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        let oldest = Calendar.current.date(byAdding: .day, value: -(Prefs.retentionDays - 1), to: Date()) ?? Date()
        let cutoff = CaptureStore.dayString(oldest)
        for dir in dirs where dir.lastPathComponent < cutoff {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func scheduleMidnightReset() {
        midnightTimer?.invalidate()
        let cal = Calendar.current
        guard let next = cal.nextDate(
            after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 1),
            matchingPolicy: .nextTime
        ) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.rollIfNeeded()
            self?.scheduleMidnightReset()
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    private func notify(_ url: URL?) {
        NotificationCenter.default.post(name: CaptureStore.didChange, object: url)
    }
}

enum Clipboard {
    static let didChange = Notification.Name("SnapStackClipboardDidChange")
    private static var current: URL?
    private static var changeCount = -1

    static func copy(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(data, forType: .png)
        if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        current = url
        changeCount = pb.changeCount
        if Prefs.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        NotificationCenter.default.post(name: didChange, object: url)
    }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        current = nil
        changeCount = pb.changeCount
        if Prefs.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func isCurrent(_ url: URL) -> Bool {
        current == url && NSPasteboard.general.changeCount == changeCount
    }
}

enum Capture {
    static func region(to url: URL, completion: @escaping (URL?) -> Void) {
        // -i 영역 선택(스페이스로 창 선택), -x 소리 끔, -o 창 그림자 제외
        run(["-i", "-x"] + (Prefs.windowShadow ? [] : ["-o"]) + [url.path], url: url, completion: completion)
    }

    /// 마우스가 있는 화면 하나를 통째로 찍는다
    @discardableResult
    static func screen(to url: URL, completion: @escaping (URL?) -> Void) -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        let index = NSScreen.screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        run(["-x", "-D", "\(index + 1)", url.path], url: url, completion: completion)
        return NSScreen.screens.indices.contains(index) ? NSScreen.screens[index] : nil
    }

    private static func run(_ arguments: [String], url: URL, completion: @escaping (URL?) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = arguments
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                completion(FileManager.default.fileExists(atPath: url.path) ? url : nil)
            }
        }
        do { try p.run() } catch { completion(nil) }
    }
}

/// 문제가 생겼을 때 원인을 볼 수 있게 남기는 기록 (~/Library/Logs/SnapStack.log)
enum Log {
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/SnapStack.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
