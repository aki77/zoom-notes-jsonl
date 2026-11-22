#!/usr/bin/env bash
# zoom-notes-jsonl を launchd の LaunchAgent として登録・解除する。
#
#   scripts/launch-agent.sh install [OUTPUT_DIR]   ビルドして登録（ログイン時に自動起動）
#   scripts/launch-agent.sh uninstall              登録解除とバイナリ削除
#   scripts/launch-agent.sh status                 稼働状態と直近ログの表示
set -euo pipefail

readonly LABEL="local.zoom-notes-jsonl"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT
# アクセシビリティ権限はバイナリのパスと署名に紐づくため、ビルド成果物ではなく固定パスへ置く。
readonly INSTALL_DIR="$HOME/Library/Application Support/zoom-notes-jsonl"
readonly BINARY_PATH="$INSTALL_DIR/zoom-notes-jsonl"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly LOG_DIR="$HOME/Library/Logs/zoom-notes-jsonl"
readonly LOG_PATH="$LOG_DIR/zoom-notes-jsonl.log"
DOMAIN="gui/$(id -u)"
readonly DOMAIN

usage() {
  cat >&2 <<EOF
usage:
  $0 install [OUTPUT_DIR]   (OUTPUT_DIR 省略時は環境変数 ZOOM_NOTES_OUTPUT_DIR を使う)
                            (確定待ち秒数は環境変数 ZOOM_NOTES_TAIL_DEBOUNCE_SECONDS で指定。省略時は既定値)
  $0 uninstall
  $0 status
EOF
  exit 64
}

is_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

unload_if_loaded() {
  is_loaded || return 0
  launchctl bootout "$DOMAIN/$LABEL"
  # bootout 直後に bootstrap すると "Input/output error" になることがあるため、解除完了を待つ。
  for _ in $(seq 1 50); do
    is_loaded || return 0
    sleep 0.1
  done
  echo "エラー: $LABEL の登録解除が完了しませんでした" >&2
  exit 1
}

# ad-hoc 署名だとアクセシビリティ権限がバイナリのハッシュに紐づき、再ビルドのたびに外れる。
# 証明書で署名すると権限が証明書に紐づくため、再インストールしても維持される。
resolve_signing_identity() {
  if [[ -n "${ZOOM_NOTES_SIGNING_IDENTITY:-}" ]]; then
    echo "$ZOOM_NOTES_SIGNING_IDENTITY"
    return 0
  fi
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) ".*$/\1/p' | head -n 1
}

sign_binary() {
  local path="$1" identity="$2"
  if [[ -z "$identity" ]]; then
    echo "警告: コード署名用の証明書が見つからないため ad-hoc 署名のままにします（再インストールのたびにアクセシビリティの許可が外れます）" >&2
    return 0
  fi
  codesign --force --sign "$identity" --identifier zoom-notes-jsonl "$path"
  codesign --verify --strict "$path"
}

# plutil で組み立てるのは、パスに & や < が含まれても XML を壊さないため。
write_plist() {
  local output_dir="$1"
  local tail_debounce="$2"
  local tmp_plist="$PLIST_PATH.tmp"
  rm -f "$tmp_plist"
  plutil -create xml1 "$tmp_plist"
  plutil -insert Label -string "$LABEL" "$tmp_plist"
  plutil -insert ProgramArguments -array "$tmp_plist"
  plutil -insert ProgramArguments.0 -string "$BINARY_PATH" "$tmp_plist"
  plutil -insert EnvironmentVariables -dictionary "$tmp_plist"
  plutil -insert EnvironmentVariables.ZOOM_NOTES_OUTPUT_DIR -string "$output_dir" "$tmp_plist"
  if [[ -n "$tail_debounce" ]]; then
    plutil -insert EnvironmentVariables.ZOOM_NOTES_TAIL_DEBOUNCE_SECONDS -string "$tail_debounce" "$tmp_plist"
  fi
  plutil -insert RunAtLoad -bool true "$tmp_plist"
  # クラッシュハンドラは _exit(128+sig) で終わるため Crashed では拾えない。非0終了で再起動させる。
  # SIGTERM 時は exit(0) なので、launchctl での停止後に勝手に再起動はしない。
  plutil -insert KeepAlive -dictionary "$tmp_plist"
  plutil -insert KeepAlive.SuccessfulExit -bool false "$tmp_plist"
  # アクセシビリティ未許可（exit 2）の間に許可ダイアログが連発しないよう、再起動間隔を空ける。
  plutil -insert ThrottleInterval -integer 30 "$tmp_plist"
  plutil -insert StandardOutPath -string "$LOG_PATH" "$tmp_plist"
  plutil -insert StandardErrorPath -string "$LOG_PATH" "$tmp_plist"
  plutil -lint "$tmp_plist" >/dev/null
  mv -f "$tmp_plist" "$PLIST_PATH"
}

cmd_install() {
  local output_dir="${1:-${ZOOM_NOTES_OUTPUT_DIR:-}}"
  if [[ -z "$output_dir" ]]; then
    # launchd 配下のカレントディレクトリは / なので、未指定のフォールバックには頼れない。
    echo "エラー: 出力先を引数か ZOOM_NOTES_OUTPUT_DIR で指定してください" >&2
    usage
  fi
  local tail_debounce="${ZOOM_NOTES_TAIL_DEBOUNCE_SECONDS:-}"
  # 不正値のまま登録すると、常駐側が起動直後のエラー終了と再起動を繰り返すため、登録前に弾く。
  if [[ -n "$tail_debounce" ]] && ! [[ "$tail_debounce" =~ ^[0-9]+(\.[0-9]+)?$ && "$tail_debounce" =~ [1-9] ]]; then
    echo "エラー: ZOOM_NOTES_TAIL_DEBOUNCE_SECONDS は正の数で指定してください: $tail_debounce" >&2
    exit 64
  fi
  mkdir -p "$output_dir"
  output_dir="$(cd "$output_dir" && pwd -P)"

  swift build -c release --package-path "$REPO_ROOT"

  mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$(dirname "$PLIST_PATH")"
  # 実行中バイナリを上書きするとコード署名キャッシュと食い違って kill されうるため、別名コピー後に置き換える。
  # 署名に失敗しても稼働中のエージェントを止めないよう、登録解除より前に署名まで済ませる。
  trap 'rm -f "$BINARY_PATH.tmp"' EXIT
  cp "$REPO_ROOT/.build/release/zoom-notes-jsonl" "$BINARY_PATH.tmp"
  chmod 755 "$BINARY_PATH.tmp"
  local signing_identity
  signing_identity="$(resolve_signing_identity)"
  sign_binary "$BINARY_PATH.tmp" "$signing_identity"

  unload_if_loaded
  mv -f "$BINARY_PATH.tmp" "$BINARY_PATH"

  write_plist "$output_dir" "$tail_debounce"
  launchctl bootstrap "$DOMAIN" "$PLIST_PATH"

  cat <<EOF
登録しました: $LABEL
  バイナリ: $BINARY_PATH
  出力先:   $output_dir
  確定待ち: ${tail_debounce:-既定値}${tail_debounce:+秒}
  署名:     ${signing_identity:-ad-hoc}
  ログ:     $LOG_PATH

初回（ad-hoc 署名なら再インストールのたびに）は、システム設定 > プライバシーとセキュリティ > アクセシビリティ で
上記バイナリ（zoom-notes-jsonl）を許可してください。許可後、最大30秒で自動的に起動し直します。
一覧に古い zoom-notes-jsonl が残っていると許可が効かないため、その場合は「−」で削除してから許可し直してください。
状態確認: $0 status
EOF
}

cmd_uninstall() {
  unload_if_loaded
  rm -f "$PLIST_PATH"
  rm -rf "$INSTALL_DIR"
  cat <<EOF
登録を解除しました: $LABEL
ログ（$LOG_DIR）と出力済みの JSONL は残しています。
アクセシビリティの許可リストに残った zoom-notes-jsonl は、必要ならシステム設定から削除してください。
EOF
}

cmd_status() {
  if ! is_loaded; then
    echo "未登録です: $LABEL"
    return 0
  fi
  # launchctl print の書式が変わって0件になっても、ログ表示まで到達させる。
  launchctl print "$DOMAIN/$LABEL" | grep -E '^\s*(state|pid|last exit code|runs) =' || true
  if [[ -f "$LOG_PATH" ]]; then
    echo "--- $LOG_PATH（末尾10行）---"
    tail -n 10 "$LOG_PATH"
  fi
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  *) usage ;;
esac
