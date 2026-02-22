#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  rclone_sync.sh --send
  rclone_sync.sh --get

Behavior:
  --send  Mirror local master_withoutball/* -> remote work_related/master_withoutball/*
  --get   Mirror remote work_related/master_withoutball/* -> local master_withoutball/*

Notes:
  - Uses rclone sync so destination becomes identical to source.
  - If deletions are needed, script warns and asks confirmation.
  - Remote name comes from WITHOUTBALL_REMOTE, otherwise first configured rclone remote.
USAGE
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

MODE="$1"
if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "$MODE" != "--send" && "$MODE" != "--get" ]]; then
  echo "Error: use exactly one of --send or --get." >&2
  usage
  exit 1
fi

RCLONE_BIN="${RCLONE_BIN:-}"
if [[ -z "$RCLONE_BIN" ]]; then
  if command -v rclone >/dev/null 2>&1; then
    RCLONE_BIN="$(command -v rclone)"
  elif [[ -x "$HOME/tools/apps/mamba/envs/tardis_env/bin/rclone" ]]; then
    RCLONE_BIN="$HOME/tools/apps/mamba/envs/tardis_env/bin/rclone"
  elif [[ -x "/Users/kemalinecik/tools/apps/mamba/envs/tardis_env/bin/rclone" ]]; then
    RCLONE_BIN="/Users/kemalinecik/tools/apps/mamba/envs/tardis_env/bin/rclone"
  fi
fi

if [[ -z "$RCLONE_BIN" ]]; then
  echo "Error: rclone not found in PATH or tardis_env." >&2
  exit 1
fi

REMOTE_NAME="${WITHOUTBALL_REMOTE:-}"
if [[ -z "$REMOTE_NAME" ]]; then
  while IFS= read -r remote; do
    remote="${remote%:}"
    if [[ -n "$remote" ]]; then
      REMOTE_NAME="$remote"
      break
    fi
  done < <("$RCLONE_BIN" listremotes)
fi

if [[ -z "$REMOTE_NAME" ]]; then
  echo "Error: no rclone remote found. Configure one with 'rclone config'." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

REMOTE_DIR="${REMOTE_NAME}:startup_related/master_withoutball"

if [[ "$MODE" == "--send" ]]; then
  SRC="${LOCAL_DIR%/}/"
  DST="${REMOTE_DIR%/}/"
else
  SRC="${REMOTE_DIR%/}/"
  DST="${LOCAL_DIR%/}/"
fi

DRYRUN_LOG="$(mktemp)"
cleanup() {
  rm -f "$DRYRUN_LOG"
}
trap cleanup EXIT

echo "Source:      $SRC"
echo "Destination: $DST"
echo "Checking planned changes..."
"$RCLONE_BIN" sync "$SRC" "$DST" --dry-run --fast-list --progress --stats 5s --log-level NOTICE \
  2>&1 | tee "$DRYRUN_LOG"
echo "Dry-run finished."

DELETE_COUNT="$(grep -Ec "Skipped (delete|rmdir) as --dry-run is set" "$DRYRUN_LOG" || true)"
if [[ "${DELETE_COUNT:-0}" -gt 0 ]]; then
  echo
  echo "Warning: $DELETE_COUNT destination item(s) will be deleted to mirror source."
  grep -E "Skipped (delete|rmdir) as --dry-run is set" "$DRYRUN_LOG" | sed -n '1,20p'
  if [[ "$DELETE_COUNT" -gt 20 ]]; then
    echo "... and more"
  fi
  echo
  if [[ -t 0 ]]; then
    read -r -p "Proceed with deletion + sync? [y/N] " answer
  else
    echo "No interactive terminal detected. Cancelled for safety."
    exit 1
  fi
  case "${answer:-}" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Cancelled."
      exit 1
      ;;
  esac
else
  echo "No deletions required."
fi

echo "Running sync..."
"$RCLONE_BIN" sync "$SRC" "$DST" --fast-list --progress
