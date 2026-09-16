#!/usr/bin/env bash
# Cap files under data/logs/ by copy-then-truncate so a live O_APPEND writer
# (start_bg opens logs with "ab") actually reclaims disk.
#
# `mv` of a live log is the silent failure this exists to prevent: the process
# keeps the old inode, df does not drop, and new lines land in the renamed
# file instead of the path operators tail.
#
# Defaults: rotate when size >= 104857600 bytes (100 MiB), keep 5 numbered
# copies (file.log.1 newest … file.log.5 oldest). History is capped, not
# deleted on first run — a retired EL log such as op-geth.log is rotated like
# any other. Tunables (optional, commented in .env.sepolia.example):
#   FORTEL2_LOG_ROTATE_BYTES
#   FORTEL2_LOG_ROTATE_KEEP
set -euo pipefail

rotate_log_file() {
  local f max keep sz i dest
  f="$1"
  max="${FORTEL2_LOG_ROTATE_BYTES:-104857600}"
  keep="${FORTEL2_LOG_ROTATE_KEEP:-5}"
  case "$max" in
    ''|*[!0-9]*)
      echo "ERROR: FORTEL2_LOG_ROTATE_BYTES must be a non-negative integer (got $max)" >&2
      return 1
      ;;
  esac
  case "$keep" in
    ''|*[!0-9]*)
      echo "ERROR: FORTEL2_LOG_ROTATE_KEEP must be a positive integer (got $keep)" >&2
      return 1
      ;;
  esac
  max=$((10#$max))
  keep=$((10#$keep))
  if [[ "$keep" -lt 1 ]]; then
    echo "ERROR: FORTEL2_LOG_ROTATE_KEEP must be >= 1" >&2
    return 1
  fi
  [[ -f "$f" ]] || return 0
  sz="$(wc -c < "$f" | tr -d '[:space:]')"
  sz=$((10#$sz))
  if [[ "$sz" -lt "$max" ]]; then
    return 0
  fi
  # Shift numbered copies. Deleting .${keep} is retention, not a sweep of live
  # history: the current file is copied, never unlinked out from under a writer.
  if [[ -f "${f}.${keep}" ]]; then
    rm -f -- "${f}.${keep}"
  fi
  i="$keep"
  while [[ "$i" -gt 1 ]]; do
    i=$((i - 1))
    if [[ -f "${f}.${i}" ]]; then
      mv -f "${f}.${i}" "${f}.$((i + 1))"
    fi
  done
  dest="${f}.1"
  # Same inode, then ftruncate via shell redirect. O_APPEND writes resume at 0.
  cp -p "$f" "$dest"
  : > "$f"
}

rotate_log_dir() {
  local dir="$1"
  local f
  [[ -d "$dir" ]] || return 0
  # Only the live *.log names. Numbered copies (*.log.1) are retention, not inputs.
  for f in "$dir"/*.log; do
    [[ -f "$f" ]] || continue
    rotate_log_file "$f"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--dir" ]]; then
    if [[ $# -ne 2 || -z "${2:-}" ]]; then
      echo "usage: rotate-logs.sh --dir DIR" >&2
      exit 2
    fi
    rotate_log_dir "$2"
    exit 0
  fi
  if [[ $# -ne 1 || -z "${1:-}" || "$1" == -* ]]; then
    echo "usage: rotate-logs.sh FILE" >&2
    echo "       rotate-logs.sh --dir DIR" >&2
    exit 2
  fi
  rotate_log_file "$1"
fi
