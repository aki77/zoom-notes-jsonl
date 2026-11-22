// 起動時設定の解決。
// 出力先の優先順位: --out <dir> 引数 > 環境変数 ZOOM_NOTES_OUTPUT_DIR > フォールバック（カレントディレクトリ）。
import CaptionDiffer
import Foundation

enum Config {
    static func resolveOutputDir() -> URL {
        let args = CommandLine.arguments
        var outDir: String?
        if let idx = args.firstIndex(of: "--out"), idx + 1 < args.count {
            outDir = args[idx + 1]
        } else if let envDir = ProcessInfo.processInfo.environment["ZOOM_NOTES_OUTPUT_DIR"] {
            outDir = envDir
        }

        let path = outDir ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL

        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        SafeIO.logErr("出力先: \(url.path)\n")
        return url
    }

    /// 末尾行の確定待ち秒数。環境変数 ZOOM_NOTES_TAIL_DEBOUNCE_SECONDS で上書きできる。
    /// 不正値を黙って既定値に置き換えると設定ミスに気づけないため、エラー終了する。
    static func resolveTailDebounceSeconds() -> Double {
        guard let raw = ProcessInfo.processInfo.environment["ZOOM_NOTES_TAIL_DEBOUNCE_SECONDS"] else {
            let value = CaptionDiffer.defaultTailDebounceSeconds
            SafeIO.logErr("確定待ち: \(value)秒（既定値）\n")
            return value
        }
        guard let value = Double(raw), value.isFinite, value > 0 else {
            SafeIO.logErr("ZOOM_NOTES_TAIL_DEBOUNCE_SECONDS は正の数で指定してください: \(raw)\n")
            exit(64)
        }
        SafeIO.logErr("確定待ち: \(value)秒\n")
        return value
    }
}
