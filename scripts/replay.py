#!/usr/bin/env python3
"""過去の文字起こし JSONL を、リアルタイム追記のように再生して書き出す。

消費側ツール（ファイルを tail して処理するもの）を実会議なしで開発・テストするための補助スクリプト。
元ファイルの行は一切加工せず、そのまま出力ファイルへ追記する。
"""
import argparse
import itertools
import json
import os
import random
import sys
import time


def parse_start(value):
    """--start の値（分の数値 または mm:ss）を秒（float）に変換する。"""
    if ":" in value:
        m, s = value.split(":", 1)
        return int(m) * 60 + float(s)
    return float(value) * 60


def fmt_mmss(sec):
    sec = int(max(sec, 0))
    return "%02d:%02d" % (sec // 60, sec % 60)


def load_entries(path):
    """元ファイルを読み、(行バイト列(改行1つ付き), cue情報) のリストを返す。

    パース不可行・空行は警告して無視する。行内容は読み込んだままで加工しない。
    """
    entries = []
    with open(path, "rb") as f:
        data = f.read()
    for lineno, raw in enumerate(data.split(b"\n"), 1):
        raw = raw.rstrip(b"\r")
        if not raw.strip():
            continue
        try:
            obj = json.loads(raw)
            start = float(obj["start"])
        except (ValueError, KeyError, TypeError) as e:
            print("警告: %d 行目を無視します (%s)" % (lineno, e), file=sys.stderr)
            continue
        entries.append({
            "line": raw + b"\n",
            "start": start,
            "speaker": obj.get("speaker"),
            "text": obj.get("text"),
            "revision": obj.get("revision"),
        })
    return entries


def dedupe(entries):
    """revision==1 で (speaker, text) が出力済みの行を除く（全履歴の再出力バースト対策）。

    revision>1 の行は訂正内容なので常に残す。
    """
    seen = set()
    result = []
    for e in entries:
        key = (e["speaker"], e["text"])
        if e["revision"] == 1 and key in seen:
            continue
        seen.add(key)
        result.append(e)
    return result


def write_line(fd, line, rng, prob, delay):
    """1行を1回の write で書く。確率 prob で2回の write に分割し、間に delay 秒待つ。"""
    if prob > 0 and len(line) > 1 and rng.random() < prob:
        pos = rng.randint(1, len(line) - 1)
        os.write(fd, line[:pos])
        time.sleep(delay)
        os.write(fd, line[pos:])
    else:
        os.write(fd, line)


def main():
    ap = argparse.ArgumentParser(description="文字起こし JSONL をリアルタイム追記のように再生する")
    ap.add_argument("input", help="元の JSONL ファイル")
    ap.add_argument("--out", default="./replay/live.jsonl", help="出力先 (既定: ./replay/live.jsonl)")
    ap.add_argument("--speed", type=float, default=1.0, help="再生速度の倍率 (既定: 1.0)")
    ap.add_argument("--start", default="0", help="開始位置。分 (10, 2.5) または mm:ss (12:30)。それより前は一括書き出し")
    ap.add_argument("--partial-prob", type=float, default=0.0, help="1行を2回の write に分割する確率 (既定: 0)")
    ap.add_argument("--partial-delay", type=float, default=0.05, help="分割 write の間の待ち秒 (既定: 0.05、speed 非適用)")
    ap.add_argument("--seed", type=int, default=None, help="乱数シード (再現用)")
    ap.add_argument("--dedupe", action="store_true", help="revision==1 で出力済みの (speaker, text) の行をスキップ")
    args = ap.parse_args()

    if args.speed <= 0:
        ap.error("--speed は正の値を指定してください")
    try:
        offset = parse_start(args.start)
    except ValueError:
        ap.error("--start の形式が不正です: %s" % args.start)

    rng = random.Random(args.seed)
    entries = load_entries(args.input)

    # 前回の再生結果を消費側が読み続けないよう、入力の内容に関わらず先に作り直す
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    if not entries:
        os.close(fd)
        print("出力対象の行がありません", file=sys.stderr)
        return 1

    if args.dedupe:
        before = len(entries)
        entries = dedupe(entries)
        print("dedupe: %d -> %d 行" % (before, len(entries)), file=sys.stderr)

    # 開始位置の基準時刻（先頭行 start + offset）
    first = entries[0]["start"]
    base = first + offset
    bulk = [e for e in entries if e["start"] < base]
    rest = [e for e in entries if e["start"] >= base]

    written = 0
    try:
        # 開始位置より前を一括書き出し（1行1write）
        for e in bulk:
            os.write(fd, e["line"])
            written += 1
        if bulk:
            print("[%s] 一括書き出し %d 行" % (fmt_mmss(offset), written), file=sys.stderr)

        # 以降は絶対スケジュールで再生。同一 start の行は連続で書く
        t0 = time.monotonic()
        for start, group in itertools.groupby(rest, key=lambda e: e["start"]):
            wait = t0 + (start - base) / args.speed - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            n = 0
            for e in group:
                write_line(fd, e["line"], rng, args.partial_prob, args.partial_delay)
                n += 1
            written += n
            print("[%s] +%d 行 (計 %d / %d)" % (fmt_mmss(start - first), n, written, len(entries)), file=sys.stderr)
    finally:
        os.close(fd)
    print("完了: %d 行を %s へ書き出しました" % (written, args.out), file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
