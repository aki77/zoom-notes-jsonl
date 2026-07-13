// セッション単位（自分用メモパネルの検出〜closed）で1ファイルへ cue を JSONL 追記するライタ。
import CaptionDiffer
import Foundation

final class JsonlWriter {
    private let outputDir: URL
    private var fileHandle: FileHandle?

    /// 現在オープン中のセッションファイルパス（未オープン時は nil）。crash.log 用。
    private(set) var currentPath: String?

    init(outputDir: URL) {
        self.outputDir = outputDir
    }

    var isSessionOpen: Bool { fileHandle != nil }

    /// 新規セッションファイルを作成してオープンする。ファイル名はセッション開始時刻ベース。
    func startSession(now: Date = Date()) {
        guard fileHandle == nil else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        formatter.timeZone = TimeZone.current
        let name = "\(formatter.string(from: now))-transcript.jsonl"
        let fileURL = outputDir.appendingPathComponent(name)

        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            SafeIO.logErr("ファイル作成に失敗しました: \(fileURL.path)\n")
            return
        }
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            SafeIO.logErr("ファイルオープンに失敗しました: \(fileURL.path)\n")
            return
        }
        fileHandle = handle
        currentPath = fileURL.path
        SafeIO.logErr("セッション開始: \(fileURL.path)\n")
    }

    /// cue を1行 JSON として追記する。セッション未オープンなら何もしない。
    func append(cue: Cue) {
        guard let handle = fileHandle else {
            SafeIO.logErr("警告: セッション未オープンのため cue を破棄しました\n")
            return
        }
        let obj: [String: Any] = [
            "speaker": cue.speaker,
            "text": cue.text,
            "start": cue.start,
            "end": cue.end,
            "seq": cue.seq,
            "revision": cue.revision,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if !SafeIO.write(handle, Data(line.utf8)) {
            // ディスクフル / FD クローズ等で追記に失敗。無限に失敗ログを出さないよう停止する。
            teardown(log: "追記失敗（ディスクフル/FDクローズの可能性）: seq=\(cue.seq)\n")
        }
    }

    /// セッションファイルを閉じる。二重クローズは無視する。
    func closeSession() {
        teardown(log: "セッション終了\n")
    }

    /// FD を閉じてセッション状態をリセットする。未オープンなら何もしない。
    private func teardown(log: String) {
        guard let handle = fileHandle else { return }
        handle.closeFile()
        fileHandle = nil
        currentPath = nil
        SafeIO.logErr(log)
    }
}
