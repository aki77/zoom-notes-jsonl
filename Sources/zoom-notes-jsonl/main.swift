// zoom-notes-jsonl — Zoom「自分用メモ」文字起こしを AX で監視し、
// 会議セッションごとに1ファイルへ cue を JSON Lines で追記する常駐ツール。
//
// 出力ファイル（1行1レコード, UTF-8, ensure_ascii なし）:
//   {"speaker":"山田太郎","text":"今日は。","start":1751.., "end":1751.., "seq":1}
//
// 進捗・状態（waiting_panel/active/panel_closed）は stderr にのみログする。

import AppKit
import ApplicationServices
import CaptionDiffer
import Foundation

func nowEpoch() -> Double { Date().timeIntervalSince1970 }

// stderr のパイプ相手（fish のジョブ / tee 等）が消えたときの SIGPIPE 即死を防ぐ。
// SIG_IGN にすると write が EPIPE を返し、SafeIO 側の do/catch で吸収できる。
signal(SIGPIPE, SIG_IGN)

guard AX.ensureTrusted() else {
    SafeIO.logErr("アクセシビリティ権限が未許可です。システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可してください。\n")
    exit(2)
}

let outputDir = Config.resolveOutputDir()
let writer = JsonlWriter(outputDir: outputDir)

// クラッシュ直前の状態を crash.log に残すためのハンドラを設置する。
CrashLog.setup(outputDir: outputDir)

// シグナルハンドラ内では async-signal-safe な処理しか許されないため、ここでは
// フラグを立てるだけにして、実際の後始末（closeSession）はメインループで行う。
var terminationRequested: sig_atomic_t = 0
signal(SIGINT) { _ in terminationRequested = 1 }
signal(SIGTERM) { _ in terminationRequested = 1 }

// ポーリング間隔（秒）。AX 読み取りは軽いので 0.3s で追記に十分追従する。
let pollInterval = 0.3
let differ = CaptionDiffer()
var lastStatus = ""

func setStatus(_ s: String) {
    guard s != lastStatus else { return }
    lastStatus = s
    SafeIO.logErr("status: \(s)\n")
}

setStatus("waiting_panel")

while true {
    // シグナル（SIGINT/SIGTERM）はフラグ経由でここで処理する（ハンドラ内は安全でない）。
    if terminationRequested != 0 {
        writer.closeSession()
        SafeIO.logErr("terminated by signal\n")
        exit(0)
    }

    let tick = nowEpoch()
    if let window = ZoomNotesReader.findNotesWindow(),
       let contentList = ZoomNotesReader.findContentList(window) {
        if lastStatus != "active" {
            setStatus("active")
            writer.startSession()
        }
        let lines = ZoomNotesReader.extractLines(contentList)
        for cue in differ.step(lines: lines, now: tick) {
            writer.append(cue: cue)
            CrashLog.update(lineCount: lines.count, cue: cue, sessionPath: writer.currentPath)
            let tag = cue.revision > 1 ? "[revision \(cue.revision)]" : "[cue]"
            SafeIO.logErr("\(tag) \(cue.speaker): \(cue.text)\n")
        }
    } else {
        if lastStatus == "active" {
            setStatus("panel_closed")
            writer.closeSession()
        } else {
            setStatus("waiting_panel")
        }
    }
    Thread.sleep(forTimeInterval: pollInterval)
}
