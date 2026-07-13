# zoom-notes-jsonl

Zoom の「自分用メモ」に表示される文字起こしを macOS Accessibility (AX) で監視し、会議セッション（自分用メモパネルを開いてから閉じるまで）ごとに1ファイルの JSON Lines として、指定したディレクトリへリアルタイムに追記するだけの常駐ツールです。

発話行（cue）をそのまま出力します。ターン結合・相槌スパニング・無音融合や、話者の自分/自分以外の写像は行いません。話者名は Zoom の表示名がそのまま入ります。Zoom 側が確定後の文字起こしを書き直した場合（音声認識の遅延訂正など）は、同じ `seq` の訂正版レコードを追記します（後述の `revision`）。

## 前提

- macOS 専用。
- **アクセシビリティ権限が必須**です。システム設定 > プライバシーとセキュリティ > アクセシビリティ で、ビルドしたバイナリ（またはそれを起動したターミナル）を許可してください。未許可の場合は起動時にエラーメッセージを表示して終了します（exit code 2）。
- 会議中は Zoom の「自分用メモ」ウィンドウで文字起こしを開いておいてください。閉じるとそのセッションのファイルが閉じられます。

## ビルド

```sh
swift build -c release
```

## 実行

出力先は `--out` 引数または環境変数 `ZOOM_NOTES_OUTPUT_DIR` で指定します。どちらも未指定の場合はカレントディレクトリに出力します。

```sh
ZOOM_NOTES_OUTPUT_DIR=~/zoom-transcripts .build/release/zoom-notes-jsonl
# または
.build/release/zoom-notes-jsonl --out ~/zoom-transcripts
```

## 出力

会議セッション（自分用メモパネルの検出〜クローズ）ごとに、セッション開始時刻を元にしたファイル名で JSON Lines ファイルが作成されます。

```
2026-07-02T113105-transcript.jsonl
```

各行は1発話（cue）を表す JSON オブジェクトです。

```json
{"speaker":"山田太郎","text":"今日は。","start":1751433065.12,"end":1751433065.12,"seq":1,"revision":1}
```

- `speaker`: Zoom の表示名（自分/自分以外の判定はしません）
- `text`: 発話テキスト
- `start` / `end`: 検出時の epoch 秒（同値になります）
- `seq`: セッション内の通し番号
- `revision`: 訂正版番号（1 始まり）。Zoom 側が確定後に文字起こしを書き直した場合、同じ `seq` を持つ行が `revision` を上げて追記されます。**読み出す際は同一 `seq` の中で `revision` が最大の行を最新の内容として採用してください。**

進捗・状態（`waiting_panel` / `active` / `panel_closed` 等）は標準エラー出力にのみログされ、JSONL ファイルには混ざりません。

## デバッグ用ツール

`ax-dump` は Zoom の AX ツリーを調査するための補助ツールです。Zoom 側の AX 構造が変わった場合の調査に使えます。

```sh
swift run ax-dump               # 全ウィンドウの AX ツリーをダンプ
swift run ax-dump --watch       # 1秒ごとにテキスト要素の差分を表示
swift run ax-dump --text-only   # テキスト要素のみ列挙
swift run ax-dump --find-notes  # 「自分用メモ」ウィンドウを全プロセス横断で探索
swift run ax-dump --dump-notes  # 「自分用メモ」ウィンドウの構造をダンプ
```
