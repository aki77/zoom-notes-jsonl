// AX（Accessibility）アクセスの薄いラッパ。
import AppKit
import ApplicationServices
import Darwin

enum AX {
    /// アクセシビリティ権限があるか（なければプロンプトを出す）。
    static func ensureTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
        return err == .success ? value : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        if let s = v as? String { return s }
        return nil
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    static func role(_ el: AXUIElement) -> String {
        string(el, kAXRoleAttribute as String) ?? ""
    }

    static func title(_ el: AXUIElement) -> String? {
        string(el, kAXTitleAttribute as String)
    }

    static func value(_ el: AXUIElement) -> String? {
        string(el, kAXValueAttribute as String)
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        (attr(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    /// libproc で現在の全 pid を毎回フレッシュに列挙する。
    /// NSWorkspace.runningApplications は GUI アプリのスナップショットで、常駐開始後に
    /// 起動した非 GUI ヘルパー（us.zoom.ZoomHybridConf 等）を反映しないため使えない。
    static func allPids() -> [pid_t] {
        let maxCount = proc_listallpids(nil, 0)
        guard maxCount > 0 else { return [] }
        // 1回目の呼び出しから間に新プロセスが増えても収まるよう余裕を持たせる。
        var pids = [pid_t](repeating: 0, count: Int(maxCount) + 64)
        // proc_listallpids の戻り値はバイト数ではなく「格納した pid の個数」
        // （libproc 内部で proc_listpids のバイト数を sizeof(int) で割って返す）。
        // バイト数と解釈して sizeof(pid_t) で再度割ると全体の 1/4 しか走査されず、
        // 配列後方の pid（先に起動していたメイン Zoom アプリ等）を取りこぼす。
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    /// pid の実行可能パス。libproc には bundle id が無いので、パスに "zoom" を含むかで判定する。
    static func procPath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }
}
