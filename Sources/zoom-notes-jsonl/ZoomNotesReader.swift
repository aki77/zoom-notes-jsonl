// Zoom「自分用メモ」文字起こしを AX から読み取る。
//
// 構造（実機確認済み / kuroko-zoom-notes-ax-structure）:
//   AXWindow title="自分用メモ"（プロセス ZoomHybridConf / bundle us.zoom.ZoomHybridConf）
//     └ … AXGroup subrole=AXContentList desc="文字起こし"
//          ├ AXButton title="山田太郎"      ← 話者名（話者交代時のみ）
//          ├ AXStaticText value="07:00:05"  ← 時刻（話者ブロックに1つ・使わない）
//          ├ AXGroup > AXStaticText value="今日は。"   ← 発話行
//          └ …
import AppKit
import ApplicationServices
import CaptionDiffer

enum ZoomNotesReader {
    /// 実行パスに "zoom" を含む全プロセスから「自分用メモ」ウィンドウを探す。
    /// プロセス列挙は libproc（AX.allPids）で毎回フレッシュに行う。NSWorkspace では
    /// 常駐開始後に起動する非 GUI ヘルパー ZoomHybridConf を拾えず、後から会議に入ると
    /// 永久に検出できなかった（実機で確認済み）。
    static func findNotesWindow() -> AXUIElement? {
        for pid in AX.allPids()
        where AX.procPath(pid).lowercased().contains("zoom") {
            let appEl = AXUIElementCreateApplication(pid)
            for w in AX.windows(appEl) {
                let title = AX.title(w) ?? ""
                if title.contains("自分用メモ") || title.contains("Notes") {
                    return w
                }
            }
        }
        return nil
    }

    /// ウィンドウ配下から文字起こしコンテナ（AXContentList desc="文字起こし"）を DFS で探す。
    static func findContentList(_ el: AXUIElement) -> AXUIElement? {
        let sub = AX.string(el, kAXSubroleAttribute as String)
        let desc = AX.string(el, kAXDescriptionAttribute as String)
        if sub == "AXContentList" || (AX.role(el) == "AXGroup" && desc == "文字起こし") {
            // desc="文字起こし" のグループが複数あり得るので、AXButton/発話を子に持つものを優先。
            if el.hasCaptionChildren { return el }
        }
        for child in AX.children(el) {
            if let found = findContentList(child) { return found }
        }
        return nil
    }

    /// コンテナ直下を順に走査し、順序付きの発話行に変換する。
    /// - 話者名 = 直近に現れた AXButton の title。
    /// - 時刻/経過時間の裸 AXStaticText（`07:00:05` `00:14:58` 等）とヘッダ/空要素は除外。
    /// - 発話行 = AXGroup 直下の AXStaticText value（または AXGroup desc）。
    static func extractLines(_ contentList: AXUIElement) -> [CaptionLine] {
        var lines: [CaptionLine] = []
        var currentSpeaker = ""
        for child in AX.children(contentList) {
            let role = AX.role(child)
            if role == "AXButton", let t = AX.title(child), !t.isEmpty {
                currentSpeaker = t
                continue
            }
            if role == "AXStaticText" {
                // コンテナ直下の裸 AXStaticText は時刻ラベル → 無視。
                continue
            }
            if role == "AXGroup" {
                // 発話行: 子 AXStaticText の value を採用（なければ desc）。
                if let text = firstStaticText(child) ?? AX.string(child, kAXDescriptionAttribute as String) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // ゼロ幅スペース・空・"editor" などのノイズを除外。
                    if trimmed.isEmpty || trimmed == "\u{200B}" || trimmed == "editor" {
                        continue
                    }
                    lines.append(CaptionLine(speaker: currentSpeaker, text: trimmed))
                }
            }
        }
        return lines
    }

    /// 子孫の最初の AXStaticText value を返す。
    private static func firstStaticText(_ el: AXUIElement) -> String? {
        for child in AX.children(el) {
            if AX.role(child) == "AXStaticText", let v = AX.value(child), !v.isEmpty {
                return v
            }
            if let nested = firstStaticText(child) { return nested }
        }
        return nil
    }
}

private extension AXUIElement {
    /// このグループが「話者ボタン or 発話グループ」を子に持つか（本物の文字起こしコンテナ判定）。
    var hasCaptionChildren: Bool {
        for child in AX.children(self) {
            let r = AX.role(child)
            if r == "AXButton" || r == "AXGroup" { return true }
        }
        return false
    }
}
