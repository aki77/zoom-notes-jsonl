// クラッシュ直前の状態を crash.log に残す観測性レイヤ。
//
// DiagnosticReports にレポートが残らないケース（fish のジョブとして短命に落ちる等）でも
// 原因を追えるよう、落ちる直前の状態（処理中の行数・最後の cue・セッションファイルパス）を
// 自前で記録する。
//
// 設計の肝: signal handler 内では async-signal-safe な処理しか許されない
// （malloc / String 補間 / Foundation / FileManager は禁止）。そのため
//  - 状態は「平時」に固定長 C バッファへ書き込んでおき、
//  - crash.log の fd は「起動時」に open しておき、
//  - ハンドラ内では write(2) で事前バッファを吐くだけ
// にする。ObjC 未捕捉例外は NSSetUncaughtExceptionHandler でも拾う（保険）。
import CaptionDiffer
import Foundation
import Darwin

enum CrashLog {
    // 起動時に open しておく crash.log の fd。ハンドラ内では open せずこれに write する。
    private static var crashFD: Int32 = -1
    // 実際の書き込み先 fd。crash.log を開けなかった場合は stderr(2) にフォールバック。
    private static var fd: Int32 { crashFD >= 0 ? crashFD : 2 }

    // ハンドラから読む状態。固定長 C バッファへ平時のみ書き込む
    // （String を保持するとハンドラ内アクセスが async-signal-safe でないため）。
    private static var lastLineCountBuf = [CChar](repeating: 0, count: 32)
    private static var lastCueBuf = [CChar](repeating: 0, count: 512)
    private static var sessionPathBuf = [CChar](repeating: 0, count: 1024)

    // update はホットパス（0.3秒×cue数）で呼ばれるため、変化しない値は再書き込みしない。
    private static var lastLineCount = -1
    private static var lastSessionPath: String?

    // backtrace 用の事前確保バッファ（ハンドラ内で malloc しないため）。
    private static var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)

    /// 起動時に1回。crash.log を事前 open し、シグナル/例外ハンドラを設置する。
    static func setup(outputDir: URL) {
        let path = outputDir.appendingPathComponent("crash.log").path
        crashFD = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        installHandlers()
    }

    /// 平時（通常コンテキスト）にメインループから呼ぶ。String → C バッファ変換は安全。
    /// cue は毎回更新するが、変化しない lineCount / sessionPath は差分時のみ書き込む。
    static func update(lineCount: Int, cue: Cue?, sessionPath: String?) {
        if let c = cue {
            setCString(&lastCueBuf, "\(c.speaker): \(c.text) (seq=\(c.seq) rev=\(c.revision))")
        }
        if lineCount != lastLineCount {
            lastLineCount = lineCount
            setCString(&lastLineCountBuf, "\(lineCount)")
        }
        if sessionPath != lastSessionPath {
            lastSessionPath = sessionPath
            setCString(&sessionPathBuf, sessionPath ?? "")
        }
    }

    /// String を固定長 C バッファへ NUL 終端付きでコピー（切り詰めあり）。
    private static func setCString(_ buf: inout [CChar], _ s: String) {
        s.withCString { _ = strlcpy(&buf, $0, buf.count) }
    }

    // --- ここから async-signal-safe 領域 ---

    private static func installHandlers() {
        // ObjC 未捕捉例外（NSException 経路の保険）。通常コンテキストで動く。
        // 記録後 _exit で即終了する（ここから raise/正常終了経路に戻るとデッドロックしうる）。
        NSSetUncaughtExceptionHandler { _ in
            CrashLog.writeRaw("=== uncaught NSException ===\n")
            CrashLog.dumpState()
            CrashLog.dumpBacktrace()
            CrashLog.writeRaw("\n")
            _exit(134)  // 128 + SIGABRT 相当
        }
        for s in [SIGTRAP, SIGSEGV, SIGABRT, SIGILL, SIGFPE, SIGBUS] {
            signal(s) { sig in
                CrashLog.writeRaw("=== fatal signal ")
                CrashLog.writeSignalName(sig)
                CrashLog.writeRaw(" ===\n")
                CrashLog.dumpState()
                CrashLog.dumpBacktrace()
                CrashLog.writeRaw("\n")
                // async-signal-safe に即終了する。raise(sig) + SIG_DFL は Swift/ObjC ランタイムの
                // ロックに触れてカーネルで終了処理がデッドロックしうる（実機で確認）ため使わない。
                // 終了コードはシェル慣習の 128 + シグナル番号。
                _exit(128 + sig)
            }
        }
    }

    private static func dumpState() {
        dumpField("lines=", &lastLineCountBuf)
        dumpField("lastCue=", &lastCueBuf)
        dumpField("session=", &sessionPathBuf)
    }

    private static func dumpField(_ label: StaticString, _ buf: inout [CChar]) {
        writeRaw(label)
        writeBuf(&buf)
        writeRaw("\n")
    }

    // 呼び出しスタックを crash.log へ吐く。backtrace / backtrace_symbols_fd は
    // async-signal-safe（_fd 版は事前確保バッファへ直接書き malloc しない）。
    private static func dumpBacktrace() {
        writeRaw("backtrace:\n")
        let n = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, n, fd)
    }

    // write(2) は async-signal-safe。StaticString も静的領域なのでハンドラ内で安全。
    private static func writeRaw(_ s: StaticString) {
        s.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
    }

    private static func writeBuf(_ buf: inout [CChar]) {
        buf.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            let n = strnlen(base, p.count)
            _ = write(fd, base, n)
        }
    }

    // String(sig) は async-signal-safe でないため、既知シグナルは StaticString で分岐する。
    private static func writeSignalName(_ sig: Int32) {
        switch sig {
        case SIGTRAP: writeRaw("SIGTRAP")
        case SIGSEGV: writeRaw("SIGSEGV")
        case SIGABRT: writeRaw("SIGABRT")
        case SIGILL: writeRaw("SIGILL")
        case SIGFPE: writeRaw("SIGFPE")
        case SIGBUS: writeRaw("SIGBUS")
        default: writeRaw("UNKNOWN")
        }
    }
}
