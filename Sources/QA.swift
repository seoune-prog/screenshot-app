import AppKit

/// 개발용 자동 점검. SNAPSTACK_QA 환경변수가 있을 때만 돈다.
enum QA {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["SNAPSTACK_QA"] else { return }
        let file = env["SNAPSTACK_QA_FILE"].map { URL(fileURLWithPath: $0) }
        switch mode {
        case "ocr":
            guard let file else { return }
            TextRecognizer.recognize(file) { text in
                Log.write("QA ocr: " + text.replacingOccurrences(of: "\n", with: " | "))
            }
        case "editor":
            guard let file, let out = env["SNAPSTACK_QA_OUT"] else { return }
            let dest = CaptureStore.shared.newFileURL()
            try? FileManager.default.copyItem(at: file, to: dest)
            CaptureStore.shared.add(dest)
            EditorWindowController.qaAnnotate(dest, out: URL(fileURLWithPath: out))
        case "ocrcrop":
            guard let file else { return }
            EditorWindowController.open(file)
            if let key = env["SNAPSTACK_QA_TOOL"] {
                EditorWindowController.qaSetTool(file, key: key)
            } else {
                EditorWindowController.qaCropOCR(file)
            }
        case "pin":
            guard let file else { return }
            PinWindow.pin(file)
            Toast.show("텍스트 복사됨 · 안녕하세요 SnapStack", symbol: "text.viewfinder")
        case "store":
            let days = Set(CaptureStore.shared.items.map { $0.deletingLastPathComponent().lastPathComponent })
            Log.write("QA store: items=\(CaptureStore.shared.items.count) days=\(days.sorted())")
            if let file {
                for _ in 0..<3 {
                    let dest = CaptureStore.shared.newFileURL()
                    try? FileManager.default.copyItem(at: file, to: dest)
                    CaptureStore.shared.add(dest)
                    usleep(2000)
                }
                let today = CaptureStore.shared.items.filter { $0.deletingLastPathComponent() == CaptureStore.shared.todayDir }
                Log.write("QA store after add: today=\(today.count) total=\(CaptureStore.shared.items.count)")
            }
        default:
            break
        }
    }
}
