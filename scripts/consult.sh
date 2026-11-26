#!/usr/bin/env bash
# consult.sh — CLI 型アドバイザーのディスパッチャー
#
# Usage: consult.sh <advisor-name|default> <briefing-file>
#   CONSULT_NO_FALLBACK=1 を付けると、指定した相手が失敗しても次へ切り替えずに止まる
#   CONSULT_TIMEOUT_SECONDS=<秒> でその回だけタイムアウトを変えられる
#   CONSULT_LOCAL_CONFIG=<パス> で PC ごとの上書きファイルの場所を変えられる
#     （既定 ${XDG_CONFIG_HOME:-~/.config}/consult/config.json。あれば config.json に重ねる）
#
# 責務:
#   1. config.json（と PC ごとの上書きファイル）からアドバイザー名を解決する
#      disabled に挙がったアドバイザーは、この PC では使わないものとして飛ばす
#   2. type=cli のアドバイザーのみ扱う（claude-agent は Agent tool 側の責務）
#   3. command -v で可用性を検出し、無ければ fallback_order の次へ自動切替
#   4. briefing を input 方式（stdin / 引数展開）で渡し、タイムアウト付きで実行
#   5. 成功したら "=== ADVISOR: <label> (<name>) ===" ヘッダー付きで標準出力へ
#   6. 全滅なら非ゼロ終了し、試行ログを stderr に残す
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_CONFIG="$SCRIPT_DIR/../config.json"
LOCAL_CONFIG="${CONSULT_LOCAL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/consult/config.json}"

usage() {
  echo "Usage: $(basename "$0") <advisor-name|default> <briefing-file>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
REQUESTED="$1"
BRIEFING_FILE="$2"

[[ -f "$BRIEFING_FILE" ]] || { echo "ERROR: briefing file not found: $BRIEFING_FILE" >&2; exit 2; }
[[ -f "$BASE_CONFIG" ]] || { echo "ERROR: config not found: $BASE_CONFIG" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not found in PATH" >&2; exit 2; }

# PC ごとの上書きファイルがあれば config.json に重ねる。
# オブジェクト（advisors など）は中まで重ね、値や配列（default・fallback_order・disabled）は上書きファイルの方を使う。
CONFIG_FILE="$BASE_CONFIG"
if [[ -f "$LOCAL_CONFIG" ]]; then
  MERGED_CONFIG="$(mktemp)"
  trap 'rm -f "$MERGED_CONFIG"' EXIT
  jq -s '.[0] * .[1]' "$BASE_CONFIG" "$LOCAL_CONFIG" > "$MERGED_CONFIG" \
    || { echo "ERROR: 上書きファイルを読めません: $LOCAL_CONFIG" >&2; exit 2; }
  CONFIG_FILE="$MERGED_CONFIG"
fi

# タイムアウト秒数の優先順位: 環境変数 CONSULT_TIMEOUT_SECONDS > config.json > 既定900
TIMEOUT_SECONDS="${CONSULT_TIMEOUT_SECONDS:-$(jq -r '.timeout_seconds // 900' "$CONFIG_FILE")}"

resolve_name() {
  local name="$1"
  if [[ "$name" == "default" ]]; then
    jq -r '.default' "$CONFIG_FILE"
  else
    echo "$name"
  fi
}

# 単一アドバイザーを実行する。成功時は stdout にヘッダー+本文を出し、戻り値 0。
run_advisor() {
  local name="$1"
  local adv_json
  adv_json="$(jq -c --arg n "$name" '.advisors[$n] // empty' "$CONFIG_FILE")"

  if [[ -z "$adv_json" ]]; then
    echo "ERROR: unknown advisor '$name' in config.json" >&2
    return 1
  fi

  if jq -e --arg n "$name" '(.disabled // []) | index($n)' "$CONFIG_FILE" >/dev/null; then
    echo "SKIP: advisor '$name' はこの PC では使わない設定です（disabled）" >&2
    return 1
  fi

  local type label bin input
  type="$(jq -r '.type' <<<"$adv_json")"
  label="$(jq -r '.label // empty' <<<"$adv_json")"
  [[ -n "$label" ]] || label="$name"

  if [[ "$type" != "cli" ]]; then
    local model
    model="$(jq -r '.model // empty' <<<"$adv_json")"
    echo "SKIP: advisor '$name' ($label) is type '$type' — CLI ディスパッチャーの対象外です。Agent tool を model=\"$model\" で直接呼び出してください。" >&2
    return 2
  fi

  bin="$(jq -r '.bin' <<<"$adv_json")"
  input="$(jq -r '.input' <<<"$adv_json")"

  if ! command -v "$bin" >/dev/null 2>&1; then
    local hint
    hint="$(jq -r '.install_hint // empty' <<<"$adv_json")"
    echo "SKIP: advisor '$name' ($label) is unavailable — command '$bin' not found in PATH.${hint:+ $hint}" >&2
    return 3
  fi

  local -a args=()
  while IFS= read -r a; do
    args+=("$a")
  done < <(jq -r '.args[]' <<<"$adv_json")

  if [[ "$input" == "arg" ]]; then
    local prompt_content
    prompt_content="$(cat "$BRIEFING_FILE")"
    local -a final_args=()
    for a in "${args[@]}"; do
      if [[ "$a" == "{PROMPT}" ]]; then
        final_args+=("$prompt_content")
      else
        final_args+=("$a")
      fi
    done
    args=("${final_args[@]}")
  fi

  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"

  (
    if [[ "$input" == "stdin" ]]; then
      "$bin" "${args[@]}" < "$BRIEFING_FILE" >"$out_file" 2>"$err_file"
    else
      "$bin" "${args[@]}" >"$out_file" 2>"$err_file"
    fi
  ) &
  local pid=$!

  local waited=0
  local interval=1
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$interval"
    waited=$((waited + interval))
    if (( waited >= TIMEOUT_SECONDS )); then
      kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "TIMEOUT: advisor '$name' ($label) exceeded ${TIMEOUT_SECONDS}s and was killed." >&2
      rm -f "$out_file" "$err_file"
      return 4
    fi
  done

  wait "$pid"
  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: advisor '$name' ($label) exited with code $exit_code:" >&2
    cat "$err_file" >&2
    rm -f "$out_file" "$err_file"
    return 5
  fi

  if [[ ! -s "$out_file" ]]; then
    echo "ERROR: advisor '$name' ($label) produced empty output." >&2
    cat "$err_file" >&2
    rm -f "$out_file" "$err_file"
    return 6
  fi

  echo "=== ADVISOR: $label ($name) ==="
  cat "$out_file"
  rm -f "$out_file" "$err_file"
  return 0
}

RESOLVED_NAME="$(resolve_name "$REQUESTED")"

declare -a ATTEMPT_ORDER=("$RESOLVED_NAME")
[[ "${CONSULT_NO_FALLBACK:-0}" == "1" ]] || while IFS= read -r n; do
  already=0
  for existing in "${ATTEMPT_ORDER[@]}"; do
    [[ "$existing" == "$n" ]] && already=1 && break
  done
  [[ $already -eq 0 ]] && ATTEMPT_ORDER+=("$n")
done < <(jq -r '.fallback_order[]' "$CONFIG_FILE")

declare -a TRIED=()
for name in "${ATTEMPT_ORDER[@]}"; do
  TRIED+=("$name")
  if [[ "$name" != "$RESOLVED_NAME" ]]; then
    echo "INFO: falling back to advisor '$name'" >&2
  fi
  run_advisor "$name"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    exit 0
  fi
done

echo "FATAL: all advisors failed or were unavailable. Tried: ${TRIED[*]}" >&2
exit 1
