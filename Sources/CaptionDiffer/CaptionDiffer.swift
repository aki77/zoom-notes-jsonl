// 追記される文字起こし行から「確定した新規 cue」を切り出す差分器。
//
// 課題:
//  - 文字起こしは行が下に追記される。末尾行は編集中（partial → final）で値が伸びうる。
//  - 同じスナップショットを何度もポーリングするので、既出行は再 emit しない。
//
// 方針（末尾行デバウンス）:
//  - スナップショット（行の配列）を突き合わせ、確定した行（末尾を除いた前方）を順に emit。
//  - 末尾行は "hot"（未確定）として保持し、
//     (a) その後さらに行が増える、または
//     (b) 末尾行の値が debounce 期間変化しない
//    のいずれかで確定させる。
//  - 各 cue には検出時の wall-clock を start/end に付与（Zoom 表示時刻は粒度が粗く使わない）。
//
// 遅延訂正:
//  - Zoom は確定後（末尾でなくなった後・debounce 完了後）に行を書き直すことがある。
//  - 直近 recentWindow 行分の確定内容を保持し、スナップショットの対応行が変化したら
//    同じ seq で revision を上げた cue を追加 emit する（JSONL は追記専用なので上書きしない）。

import Foundation

/// 文字起こしの1発話行（話者名は直近 AXButton から継承）。
public struct CaptionLine: Equatable {
    public let speaker: String  // Zoom 表示名
    public let text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

public struct Cue {
    public let speaker: String
    public let text: String
    public let start: Double  // epoch 秒
    public let end: Double
    public let seq: Int
    public let revision: Int  // 1 = 初回確定, 2 以上 = 訂正版
}

public final class CaptionDiffer {
    // 訂正検知のため直近確定行を追跡する軽量レコード。
    // lineIndex は対応するスナップショット行番号（訂正時にその行と突き合わせる）。
    private struct EmittedRecord {
        let lineIndex: Int
        let seq: Int
        var text: String
        var revision: Int
    }

    private var emittedCount = 0            // 確定 emit 済みの行数（前方一致で数える）
    private var seq = 0
    private var lastTailText = ""           // 末尾行の直近値
    private var lastTailChangeAt = 0.0      // 末尾行が最後に変化した時刻
    private let debounce: Double

    // 末尾近傍 N 行のみを追跡（emit 順＝行インデックス順、古い行から捨てる）。
    private var recentEmitted: [EmittedRecord] = []
    private let recentWindow: Int

    public init(tailDebounceSeconds: Double = 0.6, recentWindow: Int = 4) {
        self.debounce = tailDebounceSeconds
        self.recentWindow = recentWindow
    }

    /// 現在のスナップショットを与え、新たに確定した cue を返す。
    /// - Parameter now: 現在の epoch 秒（呼び出し側が渡す）。
    public func step(lines: [CaptionLine], now: Double) -> [Cue] {
        // 空スナップショットにはガードのみで意味のある末尾行が存在しない。以降の処理は
        // 末尾行の存在を前提にするため、取得自体をガードに統合して不変条件をコンパイラに保証させる。
        guard let tail = lines.last else { return [] }

        // スナップショットが縮んだ（会議切替・パネル再構築など）→ カウンタをリセットして取り直す。
        // 追記のみのパネルでは通常起きないが、防御的に扱う。
        if lines.count < emittedCount {
            emittedCount = 0
            lastTailText = ""
            lastTailChangeAt = now
            recentEmitted.removeAll()
        }

        // 末尾行の変化を追跡（デバウンス判定用）。
        let tailText = tail.text
        if tailText != lastTailText {
            lastTailText = tailText
            lastTailChangeAt = now
        }

        // 末尾行を確定に含めるか: 行数が emitted+1 を超えている（後続が来た）なら末尾より前は確定。
        // 末尾行自体は、debounce 秒変化がなければ確定に含める。
        let tailStable = (now - lastTailChangeAt) >= debounce
        // emittedCount を下回らせない（確定済み行を巻き戻さない = 逆順レンジ防止）。
        // 全行確定後に行数が増えないまま末尾行が書き直されると、tailStable=false 側で
        // lines.count - 1 < emittedCount となり emittedCount..<confirmedUpTo が逆順になって
        // Swift ランタイムトラップ（SIGTRAP）を起こすため。末尾書き直しは下の (B) が拾う。
        let confirmedUpTo = max(emittedCount, tailStable ? lines.count : lines.count - 1)

        var cues: [Cue] = []

        // (A) 新規確定行の emit。末尾近傍 N 行だけを recentEmitted に残す。
        for i in emittedCount..<confirmedUpTo {
            let line = lines[i]
            seq += 1
            cues.append(Cue(speaker: line.speaker, text: line.text, start: now, end: now, seq: seq, revision: 1))
            recentEmitted.append(EmittedRecord(lineIndex: i, seq: seq, text: line.text, revision: 1))
        }
        emittedCount = confirmedUpTo
        if recentEmitted.count > recentWindow {
            recentEmitted.removeFirst(recentEmitted.count - recentWindow)
        }

        // (B) 追跡中の直近行が後から書き直されていないか検知。record は対応行番号を持つので
        // 現在のスナップショットと直接突き合わせ、変化していれば同じ seq で revision を上げる。
        for i in recentEmitted.indices {
            let lineIndex = recentEmitted[i].lineIndex
            guard lineIndex < lines.count else { continue }
            let line = lines[lineIndex]
            if line.text != recentEmitted[i].text {
                recentEmitted[i].revision += 1
                recentEmitted[i].text = line.text
                cues.append(Cue(speaker: line.speaker, text: line.text, start: now, end: now,
                                seq: recentEmitted[i].seq, revision: recentEmitted[i].revision))
            }
        }

        return cues
    }
}
