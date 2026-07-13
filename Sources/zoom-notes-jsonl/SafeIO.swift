// クラッシュしない書き込みヘルパ。
//
// Swift の従来の FileHandle.write(_:)（旧 writeData:）は、書き込み失敗（EPIPE /
// ディスクフル / クローズ済み FD）時に Objective-C の NSException を raise する。
// これは Swift では do/catch できず、未捕捉 ObjC 例外はランタイムのトラップ経路を
// 通って SIGTRAP としてプロセスを落とす。
//
// throwing 版 write(contentsOf:)（macOS 10.15.4+）は同じ失敗を catch 可能な Swift
// エラーとして throw するため、ここで握り潰してクラッシュを防ぐ。
import Foundation

enum SafeIO {
    /// stderr へ安全に書く。失敗しても決してクラッシュしない（黙って捨てる）。
    /// write() の stderr 特化ではなく、「壊れてもログ手段が無いので成否を返さず握り潰す」
    /// という別ポリシー（write は成否を返し呼び出し側が対処する）。
    static func logErr(_ s: String) {
        do { try FileHandle.standardError.write(contentsOf: Data(s.utf8)) }
        catch { /* stderr が壊れている（EPIPE/クローズ）場合はログ手段が無いので握り潰す */ }
    }

    /// 任意の FileHandle へ安全に書く。成功可否を返す。
    @discardableResult
    static func write(_ handle: FileHandle, _ data: Data) -> Bool {
        do { try handle.write(contentsOf: data); return true }
        catch { return false }
    }
}
