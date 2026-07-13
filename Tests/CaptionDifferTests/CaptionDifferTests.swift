// CaptionDiffer の回帰テスト。
//
// 主目的: e91280c で修正した「全行確定後に末尾行が書き直されると
// emittedCount..<confirmedUpTo が逆順レンジになり SIGTRAP する」バグの再発防止。
// 実運用（7-10 のクラッシュ）は、この修正を含まない古いバイナリで動かし続けたことが
// 原因だったが、ロジック自体の回帰をテストで固定化しておく。
import XCTest
@testable import CaptionDiffer

final class CaptionDifferTests: XCTestCase {
    private func line(_ speaker: String, _ text: String) -> CaptionLine {
        CaptionLine(speaker: speaker, text: text)
    }

    /// e91280c が対象とした逆順シーケンス:
    /// 1. 行数分だけ経過させて全行を debounce 確定させる（emittedCount == lines.count）。
    /// 2. 行数を増やさず末尾行のテキストだけを書き換えて step を呼ぶ。
    /// 以前はこの (2) で emittedCount..<(lines.count - 1) が逆順になりクラッシュした。
    /// 修正後はクラッシュせず、(B) の訂正検知で revision が上がった cue が返るはず。
    func testTailRewriteAfterFullConfirmationDoesNotCrashAndEmitsRevision() {
        let differ = CaptionDiffer(tailDebounceSeconds: 0.6, recentWindow: 4)
        var now = 1000.0

        let lines = [
            line("話者A", "気をつけてください。"),
            line("話者A", "いろいろやってるけ*。"),
            line("話者A", "ちょっと。"),
            line("話者A", "なんか、例えば。"),
            line("話者A", "登録直後。"),
            line("話者A", "で。"),
            line("話者A", "三分間に。"),
            line("話者A", "十通以上。"),
        ]

        // 行が1本ずつ増えるのを模して、都度 step を呼びつつ確定させていく。
        var allCues: [Cue] = []
        for i in 1...lines.count {
            now += 1
            allCues += differ.step(lines: Array(lines[0..<i]), now: now)
        }
        // 末尾行を debounce 秒以上経過させて確定させる。
        now += 1.0
        allCues += differ.step(lines: lines, now: now)

        XCTAssertEqual(allCues.count, lines.count)
        XCTAssertTrue(allCues.allSatisfy { $0.revision == 1 })

        // 行数を増やさないまま末尾行を書き換える（Zoom の遅延訂正を模す）。
        // 以前はここで emittedCount(8)..<confirmedUpTo(7) の逆順レンジによりクラッシュした。
        var rewritten = lines
        rewritten[rewritten.count - 1] = line("話者A", "十通以上でした。")
        now += 0.1
        let revisionCues = differ.step(lines: rewritten, now: now)

        XCTAssertEqual(revisionCues.count, 1)
        XCTAssertEqual(revisionCues.first?.text, "十通以上でした。")
        XCTAssertEqual(revisionCues.first?.revision, 2)
        XCTAssertEqual(revisionCues.first?.seq, lines.count)
    }

    /// 通常系列: 末尾行が伸長を続け、増えなくなってから debounce 秒経過すると確定する。
    func testTailConfirmsAfterDebounceWithoutFurtherGrowth() {
        let differ = CaptionDiffer(tailDebounceSeconds: 0.6, recentWindow: 4)
        var now = 0.0

        let cues1 = differ.step(lines: [line("山田太郎", "今日は")], now: now)
        XCTAssertTrue(cues1.isEmpty, "末尾行はまだ確定しない")

        now += 0.3
        let cues2 = differ.step(lines: [line("山田太郎", "今日は。")], now: now)
        XCTAssertTrue(cues2.isEmpty, "テキストが変わったので debounce 再開")

        now += 0.7
        let cues3 = differ.step(lines: [line("山田太郎", "今日は。")], now: now)
        XCTAssertEqual(cues3.count, 1)
        XCTAssertEqual(cues3.first?.text, "今日は。")
        XCTAssertEqual(cues3.first?.revision, 1)
    }

    /// 後続行が追加されると、末尾より前の行は debounce を待たずに確定する。
    func testPrecedingLinesConfirmImmediatelyWhenFollowedByNewLine() {
        let differ = CaptionDiffer(tailDebounceSeconds: 0.6, recentWindow: 4)
        var now = 0.0

        let cues1 = differ.step(lines: [line("A", "one")], now: now)
        XCTAssertTrue(cues1.isEmpty)

        now += 0.05
        let cues2 = differ.step(lines: [line("A", "one"), line("A", "two")], now: now)
        XCTAssertEqual(cues2.count, 1, "one は two が来たことで確定するはず")
        XCTAssertEqual(cues2.first?.text, "one")
    }

    /// スナップショットが縮む（会議切替・パネル再構築）と内部カウンタがリセットされ、
    /// クラッシュせず取り直しになる。
    func testShrinkingSnapshotResetsState() {
        let differ = CaptionDiffer(tailDebounceSeconds: 0.6, recentWindow: 4)
        var now = 0.0

        for i in 1...5 {
            now += 1
            _ = differ.step(lines: (0..<i).map { line("A", "line\($0)") }, now: now)
        }
        now += 1.0
        let confirmed = differ.step(lines: (0..<5).map { line("A", "line\($0)") }, now: now)
        XCTAssertFalse(confirmed.isEmpty)

        // 会議が切り替わり行数が減る。
        now += 1.0
        let afterShrink = differ.step(lines: [line("B", "new session")], now: now)
        XCTAssertTrue(afterShrink.isEmpty, "新しい末尾行はまだ確定しない")

        now += 1.0
        let confirmedAfterShrink = differ.step(lines: [line("B", "new session")], now: now)
        XCTAssertEqual(confirmedAfterShrink.count, 1)
        // seq はセッションを通じた連番であり、行インデックスのリセットとは独立して増加し続ける。
        XCTAssertEqual(confirmedAfterShrink.first?.text, "new session")
    }

    /// recentWindow を超えて古い行は訂正検知の対象から外れる（クラッシュはしない）。
    func testOldLinesBeyondRecentWindowAreNotTrackedForRevision() {
        let differ = CaptionDiffer(tailDebounceSeconds: 0.1, recentWindow: 2)
        var now = 0.0

        let baseLines = (0..<5).map { line("A", "line\($0)") }
        for i in 1...baseLines.count {
            now += 1
            _ = differ.step(lines: Array(baseLines[0..<i]), now: now)
        }
        now += 0.2
        _ = differ.step(lines: baseLines, now: now)

        // recentWindow=2 なので line0 はもう追跡されていないはず。
        var rewritten = baseLines
        rewritten[0] = line("A", "line0 rewritten")
        now += 0.05
        let cues = differ.step(lines: rewritten, now: now)
        XCTAssertTrue(cues.isEmpty, "recentWindow 外の行は訂正として拾われない")
    }

    /// 空のスナップショットは何も返さずクラッシュしない。
    func testEmptySnapshotReturnsNoCues() {
        let differ = CaptionDiffer()
        XCTAssertTrue(differ.step(lines: [], now: 0).isEmpty)
    }
}
