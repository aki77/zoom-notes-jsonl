// 出力先ディレクトリの解決。
// 優先順位: --out <dir> 引数 > 環境変数 ZOOM_NOTES_OUTPUT_DIR > フォールバック（カレントディレクトリ）。
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
}
