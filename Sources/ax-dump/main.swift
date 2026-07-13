// ゲート0 PoC — Zoom の AX ツリーをダンプし、「自分用メモ」文字起こしが
// Accessibility 経由で読めるかを実機で確認するための単体ツール。
//
// 使い方:
//   1. Zoom 会議に入り「自分用メモ」ウィンドウ内の「文字起こし」を開いておく。
//   2. 初回は システム設定 > プライバシーとセキュリティ > アクセシビリティ で
//      このバイナリ（またはそれを起動したターミナル）に許可を与える。
//   3. `swift run ax-dump`            → Zoom の全ウィンドウ AX ツリーを一度だけダンプ。
//      `swift run ax-dump --watch`    → 1 秒ごとに AXStaticText の値だけを差分表示（追記検出の検証）。
//      `swift run ax-dump --text-only` → 一度だけ、値を持つテキスト要素のみ列挙。
//
// 判定: 話者名/時刻/本文が AXStaticText 等として取れれば AX 方式、取れなければ OCR フォールバック。

import AppKit
import ApplicationServices
import Darwin

// MARK: - 権限

func ensureTrusted() -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

// MARK: - Zoom プロセス探索

func findZoom() -> NSRunningApplication? {
    let apps = NSWorkspace.shared.runningApplications
    // バンドルID (us.zoom.xos) 優先、なければ名前一致。
    if let z = apps.first(where: { $0.bundleIdentifier == "us.zoom.xos" }) {
        return z
    }
    return apps.first(where: { ($0.localizedName ?? "").lowercased().contains("zoom") })
}

// MARK: - AX ヘルパ

func copyAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
    return err == .success ? value : nil
}

func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
    guard let v = copyAttr(el, attr) else { return nil }
    if let s = v as? String { return s }
    if CFGetTypeID(v) == AXValueGetTypeID() { return nil }
    return "\(v)"
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    guard let v = copyAttr(el, kAXChildrenAttribute as String) as? [AXUIElement] else {
        return []
    }
    return v
}

func role(_ el: AXUIElement) -> String { stringAttr(el, kAXRoleAttribute as String) ?? "?" }

func describe(_ el: AXUIElement) -> String {
    var parts: [String] = [role(el)]
    if let sub = stringAttr(el, kAXSubroleAttribute as String) { parts.append("subrole=\(sub)") }
    if let title = stringAttr(el, kAXTitleAttribute as String), !title.isEmpty {
        parts.append("title=\(quote(title))")
    }
    if let value = stringAttr(el, kAXValueAttribute as String), !value.isEmpty {
        parts.append("value=\(quote(value))")
    }
    if let desc = stringAttr(el, kAXDescriptionAttribute as String), !desc.isEmpty {
        parts.append("desc=\(quote(desc))")
    }
    if let ident = stringAttr(el, kAXIdentifierAttribute as String), !ident.isEmpty {
        parts.append("id=\(ident)")
    }
    return parts.joined(separator: " ")
}

func quote(_ s: String) -> String {
    let clipped = s.count > 120 ? String(s.prefix(120)) + "…" : s
    return "\"\(clipped.replacingOccurrences(of: "\n", with: "\\n"))\""
}

// MARK: - ダンプ

func dumpTree(_ el: AXUIElement, depth: Int, maxDepth: Int) {
    let indent = String(repeating: "  ", count: depth)
    print("\(indent)\(describe(el))")
    if depth >= maxDepth { return }
    for child in children(el) {
        dumpTree(child, depth: depth + 1, maxDepth: maxDepth)
    }
}

/// 値を持つテキスト系要素の値だけを収集（AXStaticText / AXTextArea / value 付き要素）。
func collectTexts(_ el: AXUIElement, into acc: inout [String]) {
    let r = role(el)
    if r == "AXStaticText" || r == "AXTextArea" || r == "AXTextField" {
        if let v = stringAttr(el, kAXValueAttribute as String), !v.isEmpty {
            acc.append("[\(r)] \(v)")
        } else if let t = stringAttr(el, kAXTitleAttribute as String), !t.isEmpty {
            acc.append("[\(r)] \(t)")
        }
    }
    for child in children(el) {
        collectTexts(child, into: &acc)
    }
}

/// libproc で現在の全 pid を毎回フレッシュに列挙する。
/// NSWorkspace.runningApplications は GUI アプリのスナップショットで、常駐後に起動した
/// 非 GUI ヘルパー（us.zoom.ZoomHybridConf 等）を反映しないため、これを使う。
func allPids() -> [pid_t] {
    let maxCount = proc_listallpids(nil, 0)
    guard maxCount > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(maxCount))
    let byteCount = proc_listallpids(&pids, maxCount * Int32(MemoryLayout<pid_t>.size))
    guard byteCount > 0 else { return [] }
    let count = Int(byteCount) / MemoryLayout<pid_t>.size
    return Array(pids.prefix(count)).filter { $0 > 0 }
}

/// pid の実行可能パス（bundle 判定の代替。libproc には bundle id が無いためパスで zoom を判定）。
func procPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : ""
}

/// 本体 findContentList の候補（subrole=AXContentList か desc="文字起こし" の AXGroup）を
/// 子の有無に関わらず全て集める。診断用に各候補の状態を並べて出すのに使う。
func collectTranscriptGroups(_ el: AXUIElement, into acc: inout [AXUIElement]) {
    let sub = stringAttr(el, kAXSubroleAttribute as String)
    let desc = stringAttr(el, kAXDescriptionAttribute as String)
    if sub == "AXContentList" || (role(el) == "AXGroup" && desc == "文字起こし") {
        acc.append(el)
    }
    for child in children(el) { collectTranscriptGroups(child, into: &acc) }
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
let watch = args.contains("--watch")
let textOnly = args.contains("--text-only")
let findNotes = args.contains("--find-notes")
let dumpNotes = args.contains("--dump-notes")
let watchNotes = args.contains("--watch-notes")

guard ensureTrusted() else {
    FileHandle.standardError.write(Data(
        "アクセシビリティ権限が未許可です。システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可し、再実行してください。\n".utf8
    ))
    exit(2)
}

// --find-notes: 全実行プロセスを横断して「自分用メモ」らしきウィンドウを探し、
// どのプロセスに属するか・AX でテキストが取れるかを診断する。
// 「自分用メモ」は Zoom 本体とは別プロセス/別バンドルの可能性があるため。
if findNotes {
    print("=== 全プロセスの全ウィンドウを列挙（フィルタなし） ===")
    // 「自分用メモ」ウィンドウの所在が不明なため、全プロセスの全ウィンドウの
    // proc/bundle/title を無条件にダンプする。VSCode 等ノイズは自分で読み飛ばす。
    let noteKeywords = ["自分用メモ", "文字起こし", "Notes", "Transcript", "Meeting"]
    for app in NSWorkspace.shared.runningApplications {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"
        let bundle = app.bundleIdentifier ?? "?"
        let el = AXUIElementCreateApplication(pid)
        guard let ws = copyAttr(el, kAXWindowsAttribute as String) as? [AXUIElement], !ws.isEmpty else { continue }
        for (i, w) in ws.enumerated() {
            let title = stringAttr(w, kAXTitleAttribute as String) ?? "(no title)"
            var texts: [String] = []
            collectTexts(w, into: &texts)
            // Zoom / メモ系キーワードにヒットするものは中身も出す。
            let interesting = bundle.lowercased().contains("zoom")
                || noteKeywords.contains { title.contains($0) }
            let marker = interesting ? ">>> " : "    "
            print("\(marker)proc=\(name) bundle=\(bundle) pid=\(pid) window[\(i)] title=\(quote(title)) texts=\(texts.count)")
            if interesting && !texts.isEmpty {
                for t in texts.prefix(80) { print("        \(t)") }
            }
        }
    }
    print("\n=== 探索終了 ===")
    print("ヒント: 「自分用メモ」がどこにも出ない場合、そのウィンドウは AX の kAXWindows に")
    print("露出しない特殊レイヤー（Zoom のオーバーレイ描画）であり、OCR フォールバックが必要。")
    exit(0)
}

// --watch-notes: 本体の常駐ループと同じ検出パス（findNotesWindow → findContentList）を
// 1 秒ごとに回し、各ステップの結果を出力する。発話ゼロ→発話ありの瞬間に
// contentList が復帰するか（stale ハンドル疑い）を観測する診断モード。
if watchNotes {
    // libproc の全 pid 列挙から、実行パスに "zoom" を含むプロセスの「自分用メモ」を探す。
    // NSWorkspace に載らない ZoomHybridConf を拾うのが狙い。
    func findNotesWindow() -> (win: AXUIElement?, diag: String) {
        var zoomProcs: [String] = []
        var found: AXUIElement?
        for pid in allPids() {
            let path = procPath(pid)
            guard path.lowercased().contains("zoom") else { continue }
            let appEl = AXUIElementCreateApplication(pid)
            let ws = (copyAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
            let name = (path as NSString).lastPathComponent
            zoomProcs.append("\(name)#\(pid)(w=\(ws.count))")
            for w in ws {
                let t = stringAttr(w, kAXTitleAttribute as String) ?? ""
                if t.contains("自分用メモ") || t.contains("Notes") { found = found ?? w }
            }
        }
        return (found, "zoomProcs=[\(zoomProcs.joined(separator: " "))]")
    }

    print("--- watch-notes (Ctrl-C で終了) 本体と同じ検出パスを 1 秒ごとに評価 ---")
    var tick = 0
    while true {
        tick += 1
        let (windowOpt, procDiag) = findNotesWindow()
        guard let window = windowOpt else {
            print("[\(tick)] window=なし \(procDiag)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.0)
            continue
        }
        // desc="文字起こし" 系グループ（本体の contentList 候補）を全て列挙し、
        // 各グループの subrole と子要素数を出す。本体は「子を持つ候補」を1つでも掴めれば active。
        var groups: [AXUIElement] = []
        collectTranscriptGroups(window, into: &groups)
        let detected = groups.contains { !children($0).isEmpty }
        var detail = "window=あり transcriptGroups=\(groups.count)"
        for (i, g) in groups.enumerated() {
            let sub = stringAttr(g, kAXSubroleAttribute as String) ?? "-"
            let kids = children(g)
            let kidRoles = kids.map { role($0) }.joined(separator: ",")
            detail += " | g[\(i)] sub=\(sub) kids=\(kids.count)[\(kidRoles)]"
        }
        detail += detected ? " => contentList=検出" : " => contentList=なし"
        print("[\(tick)] \(detail)")
        fflush(stdout)
        // Thread.sleep ではなく RunLoop を回す。NSWorkspace は新規プロセス起動を
        // RunLoop 経由の通知で受けて runningApplications を更新するため、寝ていると
        // 後から起動した ZoomHybridConf が一覧に反映されない。
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
    }
}

// --dump-notes: ZoomHybridConf の「自分用メモ」ウィンドウを構造付きでダンプする。
// 話者名がどの要素（AXImage の desc / 時刻の兄弟テキスト等）に入っているかを特定する目的。
if dumpNotes {
    var found = false
    for app in NSWorkspace.shared.runningApplications
    where (app.bundleIdentifier ?? "").lowercased().contains("zoom") {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        guard let ws = copyAttr(el, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
        for w in ws {
            let title = stringAttr(w, kAXTitleAttribute as String) ?? ""
            guard title.contains("自分用メモ") || title.contains("Notes") else { continue }
            found = true
            print("=== dump: proc=\(app.localizedName ?? "?") bundle=\(app.bundleIdentifier ?? "?") title=\(quote(title)) ===")
            print("（各行 role と全テキスト系属性。話者名がどこに入るかを確認する）\n")
            dumpTree(w, depth: 0, maxDepth: 60)
        }
    }
    if !found {
        print("「自分用メモ」ウィンドウが見つかりません。Zoom で開いてから再実行してください。")
    }
    exit(0)
}

guard let zoom = findZoom(), let pid = zoom.processIdentifier as pid_t? else {
    FileHandle.standardError.write(Data("Zoom プロセスが見つかりません。Zoom 会議に入ってから実行してください。\n".utf8))
    exit(1)
}

print("Zoom found: \(zoom.localizedName ?? "?") pid=\(pid) bundle=\(zoom.bundleIdentifier ?? "?")")
let appEl = AXUIElementCreateApplication(pid)

guard let windows = copyAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement] else {
    print("ウィンドウを取得できませんでした（AX 非露出の可能性）。")
    exit(0)
}
print("windows: \(windows.count)")

if watch {
    // 差分ウォッチ: 全ウィンドウのテキストを 1 秒ごとに収集し、新規行だけ表示。
    print("--- watch mode (Ctrl-C で終了) ---")
    var seen = Set<String>()
    while true {
        var texts: [String] = []
        // ウィンドウ集合は会議中に増減するので都度取り直す。
        if let ws = copyAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement] {
            for w in ws { collectTexts(w, into: &texts) }
        }
        for t in texts where !seen.contains(t) {
            seen.insert(t)
            print("+ \(t)")
        }
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1.0)
    }
} else {
    for (i, w) in windows.enumerated() {
        let title = stringAttr(w, kAXTitleAttribute as String) ?? "(no title)"
        print("\n===== window[\(i)] title=\(quote(title)) =====")
        if textOnly {
            var texts: [String] = []
            collectTexts(w, into: &texts)
            if texts.isEmpty {
                print("  (テキスト要素なし — AX 非露出の可能性)")
            }
            for t in texts { print("  \(t)") }
        } else {
            dumpTree(w, depth: 1, maxDepth: 40)
        }
    }
}
