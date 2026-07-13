// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "zoom-notes-jsonl",
    platforms: [.macOS(.v13)],
    targets: [
        // 差分ロジック本体（AX/AppKit 非依存）。ユニットテストから @testable import するため
        // executable ではなくライブラリターゲットに切り出している。
        .target(
            name: "CaptionDiffer",
            path: "Sources/CaptionDiffer"
        ),
        // 調査用ツール: Zoom の AX ツリーをダンプする（kuroko の ax-dump を流用）。
        .executableTarget(
            name: "ax-dump",
            path: "Sources/ax-dump"
        ),
        // 本体: Zoom「自分用メモ」文字起こしを AX で監視し cue を JSONL ファイルへ出力する。
        .executableTarget(
            name: "zoom-notes-jsonl",
            dependencies: ["CaptionDiffer"],
            path: "Sources/zoom-notes-jsonl"
        ),
        .testTarget(
            name: "CaptionDifferTests",
            dependencies: ["CaptionDiffer"],
            path: "Tests/CaptionDifferTests"
        ),
    ]
)
