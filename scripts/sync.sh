#!/usr/bin/env bash
#
# synchronize.sh — Modern rsync-based project sync for HPC
#
# Self-contained single file. No external utility scripts needed.
#
# Usage:
#   ./synchronize.sh                Interactive mode (default)
#   ./synchronize.sh send           Send local code to remote
#   ./synchronize.sh pull           Pull sync directories from remote
#   ./synchronize.sh send-pull      Send code + pull sync dirs
#   ./synchronize.sh push-all       Push everything to remote
#   ./synchronize.sh pull-all       Pull everything from remote
#   ./synchronize.sh watch          Watch for changes and auto-sync
#   ./synchronize.sh status         Show current configuration
#   ./synchronize.sh test           Test remote connection
#   ./synchronize.sh help           Show help
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  HOW THIS SCRIPT WORKS (beginner guide)                                │
# └─────────────────────────────────────────────────────────────────────────┘
#
# This script keeps your local project folder in sync with a copy on a
# remote HPC server. It uses rsync, which only transfers files that have
# actually changed — so repeated syncs are fast.
#
# ── KEY CONCEPTS ──────────────────────────────────────────────────────────
#
#   Your laptop                          HPC server
#   ┌───────────────────┐               ┌───────────────────┐
#   │ master_withoutball │ ── send ──▶   │ master_withoutball │
#   │   src/             │               │   src/             │
#   │   configs/         │ ◀── pull ──   │   pose-transformer/│ ← sync dir
#   │   ...              │               │   ...              │
#   └───────────────────┘               └───────────────────┘
#
#   "Code"        Your project files (source code, configs, scripts, etc.).
#                 Flows: laptop → server.
#                 The SYNC_DIRS and EXCLUSIONS are skipped when sending.
#
#   "Sync dirs"   Large output directories that LIVE on the server (model
#                 checkpoints, training results, generated data). These are
#                 never pushed to the server — only pulled from it.
#                 Currently configured: pose-transformer
#
#   "Exclusions"  Files/folders NEVER synced in either direction:
#                 __pycache__, .git, .venv, *.DS_Store, etc.
#                 See the EXCLUSIONS array below to customise.
#
# ── COMMANDS — what gets synced where ─────────────────────────────────────
#
#   send        Upload your local CODE to the server.
#               ✓ Synced:  everything in your project folder
#               ✗ Skipped: sync dirs (pose-transformer) + exclusions
#               Direction: laptop → server
#               If you deleted a file locally, you'll be asked whether
#               to also delete it on the server.
#
#   pull        Download SYNC DIRECTORIES from the server to your laptop.
#               ✓ Synced:  only the directories listed in SYNC_DIRS
#               ✗ Skipped: exclusions (__pycache__, etc.)
#               Direction: server → laptop
#
#   send-pull   Runs "send" then "pull". The most common workflow:
#               push your latest code, then grab the latest results.
#
#   push-all    Upload EVERYTHING (code + sync dirs) to the server.
#               ⚠ Dangerous: overwrites the entire remote project.
#               Requires typing "yes" to confirm.
#               Use for: initial setup, or full local→remote resync.
#
#   pull-all    Download EVERYTHING from the server to your laptop.
#               ⚠ Dangerous: overwrites your entire local project.
#               Requires typing "yes" to confirm.
#               Use for: cloning the server state to a new machine.
#
#   watch       Sits in the background watching your local files. Whenever
#               something changes, it automatically runs "send".
#               Uses fswatch if installed, otherwise polls every 5s.
#
#   status      Prints paths, exclusions, and other configuration.
#   test        Tests if the server is reachable via SSH.
#   help        Shows a coloured help summary in the terminal.
#
# ── SAFETY ────────────────────────────────────────────────────────────────
#
#   Before every transfer, a dry-run detects what would change. If any
#   files would be DELETED on the destination, you see the full list and
#   choose:
#     [y] Sync with deletions  — remote files not in source are removed
#     [s] Skip deletions       — transfer new/changed files, delete nothing
#     [n] Cancel               — abort the whole operation
#
# ── RECOMMENDED INSTALLS ────────────────────────────────────────────────
#
#   brew install rsync       Newer rsync (3.x) with overall transfer
#                            progress bar. macOS ships an old 2.6.9-compat
#                            build that only shows per-file progress.
#   brew install fswatch     Instant file-change detection for watch mode.
#                            Without it the script falls back to polling.
#   brew install sshpass     Required. Provides password-based SSH auth
#                            so rsync can connect non-interactively.
#
set -o pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  CONFIGURATION — edit this section to match your environment
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Source password (sshpass). The script must define `password_icb`.
PASSWORD_FILE="/Users/kemalinecik/Documents/Helmholtz/password.sh"

LOCAL_PATH="/Users/kemalinecik/git_nosync"
SERVER_PATH="/lustre/groups/ml01/workspace/kemal.inecik"
PROJECT_NAME="master_withoutball"
REMOTE_USER="kemal.inecik"
REMOTE_HOST="hpc-build01"

# Patterns to always exclude from sync
EXCLUSIONS=(
    "__pycache__"
    "*.DS_Store"
    ".idea"
    ".mypy_cache"
    "*.ipynb_checkpoints"
    ".git"
    "*_build"
    ".nox"
    ".pytest_cache"
    ".venv"
    "*.egg-info"
    ".ruff_cache"
    "htmlcov"
    ".coverage"
    "coverage.xml"
    "*.py[cod]"
    ".eggs"
    "pose-transformer/outputs"
    "pose-transformer/.cache"
    "pose-transformer/logs"
    "data/hackathon/data/DFL-MAT-J03WOY"
    "data/hackathon/data/DFL-MAT-J03WPY"
    "data/hackathon/data/DFL-MAT-J03WQQ"
    "data/hackathon/data/DFL-MAT-J03WR9"
)

# Directories to pull FROM the server (not pushed with code)
SYNC_DIRS=(
    "pose-transformer"
    "data/hackathon/data"
)

# SSH / rsync tunables
SSH_CONNECT_TIMEOUT=20
RSYNC_IO_TIMEOUT=300    # seconds of I/O inactivity before rsync aborts
SSH_CMD="ssh -o LogLevel=error -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
RSYNC_BASE_OPTS=(-avhz --partial --timeout="$RSYNC_IO_TIMEOUT" --stats --itemize-changes)

# Watch-mode polling interval (used only when fswatch is unavailable)
WATCH_INTERVAL=5

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  PREREQUISITES — fail fast with clear messages
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

for _cmd in rsync sshpass; do
    command -v "$_cmd" &>/dev/null || {
        echo "ERROR: '${_cmd}' is required but not found. Install: brew install ${_cmd}" >&2; exit 1
    }
done
unset _cmd

# shellcheck disable=SC1090
source "$PASSWORD_FILE" || {
    echo "ERROR: Cannot source password file: ${PASSWORD_FILE}" >&2; exit 1
}
[[ -n "${password_icb:-}" ]] || {
    echo "ERROR: \$password_icb not set in ${PASSWORD_FILE}" >&2; exit 1
}

# Export password as env var so sshpass can use -e (reads $SSHPASS).
# This avoids exposing the password on the command line (visible in `ps`).
export SSHPASS="$password_icb"

# Detect rsync capability: --info=progress2 (overall %) needs rsync ≥ 3.1
# Apple ships openrsync (2.6.9-compatible) which only supports --progress.
# Install Homebrew rsync (`brew install rsync`) for the nicer overall bar.
RSYNC_PROGRESS_FLAG="--progress"
# Note: `|| true` is required — `head -1` closes the pipe early, causing
# SIGPIPE on rsync (multi-line output), which `set -o pipefail` turns into
# a non-zero exit status.
RSYNC_VERSION_STR=$(rsync --version 2>&1 | head -1 || true)
if [[ -z "$RSYNC_VERSION_STR" ]]; then
    RSYNC_VERSION_STR="unknown"
    echo "WARNING: 'rsync --version' produced no output. rsync may be broken." >&2
elif [[ "$RSYNC_VERSION_STR" =~ version\ [3-9]\. ]]; then
    RSYNC_PROGRESS_FLAG="--info=progress2"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  DERIVED CONSTANTS (do not edit)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

readonly REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
readonly REMOTE_PROJECT="${SERVER_PATH}/${PROJECT_NAME}"
readonly LOCAL_PROJECT="${LOCAL_PATH}/${PROJECT_NAME}"
readonly LOCKDIR="/tmp/.synchronize_${PROJECT_NAME}.lock"

[[ -d "$LOCAL_PROJECT" ]] || {
    echo "ERROR: Local project does not exist: ${LOCAL_PROJECT}" >&2; exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  TERMINAL — colors, symbols, logging
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
    RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
    RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[1;34m'; MAGENTA=$'\033[1;35m'; CYAN=$'\033[1;36m'

    # Gradient colors for decorative elements (256-color with fallback)
    if (( $(tput colors 2>/dev/null || echo 0) >= 256 )); then
        G1=$'\033[38;5;205m'    # hot pink
        G2=$'\033[38;5;171m'    # orchid
        G3=$'\033[38;5;135m'    # medium purple
        G4=$'\033[38;5;99m'     # slate blue
        G5=$'\033[38;5;75m'     # cornflower blue
    else
        G1="$MAGENTA"; G2="$MAGENTA"; G3="$BLUE"; G4="$CYAN"; G5="$CYAN"
    fi
else
    RST=''; BOLD=''; DIM=''
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''
    G1=''; G2=''; G3=''; G4=''; G5=''
fi

SYM_OK="✓"; SYM_FAIL="✗"; SYM_WARN="⚠"; SYM_INFO="●"
SYM_UP="▲"; SYM_DOWN="▼"; SYM_UPDOWN="↕"; SYM_DEL="✕"; SYM_WATCH="◉"

# Format seconds → "12s" or "2m05s"
_fmt_elapsed() {
    local h=$(( $1 / 3600 )) m=$(( ($1 % 3600) / 60 )) s=$(( $1 % 60 ))
    if (( h > 0 )); then
        printf '%dh%02dm%02ds' "$h" "$m" "$s"
    elif (( m > 0 )); then
        printf '%dm%02ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
}

_ts()     { date +'%H:%M:%S'; }
log()     { printf '%s\n' "${DIM}$(_ts)${RST}  ${CYAN}${SYM_INFO}${RST}  $*"; }
ok()      { printf '%s\n' "${DIM}$(_ts)${RST}  ${GREEN}${SYM_OK}${RST}  $*"; }
warn()    { printf '%s\n' "${DIM}$(_ts)${RST}  ${YELLOW}${SYM_WARN}${RST}  $*"; }
err()     { printf '%s\n' "${DIM}$(_ts)${RST}  ${RED}${SYM_FAIL}${RST}  $*" >&2; }
die()     { err "$@"; exit 1; }

# Debug logging — enable with SYNCHRONIZE_DEBUG=1
readonly DEBUG="${SYNCHRONIZE_DEBUG:-0}"
_debug() {
    (( DEBUG )) && printf '%s\n' "${DIM}$(_ts)  DBG  $*${RST}" >&2
    return 0
}

# Gradient horizontal rule (pink → orchid → purple → slate → cornflower)
separator() {
    local seg="════════════"
    printf '%s\n' "${G1}${seg}${G2}${seg}${G3}${seg}${G4}${seg}${G5}${seg}${RST}"
}

# Subtle dim separator for menu divisions
_dim_separator() {
    printf '%s\n' "  ${DIM}$(printf '%.0s─' {1..56})${RST}"
}

header() {
    echo ""
    separator
    printf '%s\n' "  ${BOLD}$*${RST}"
    separator
}

# Animated spinner with elapsed time and color-cycling.
# Usage:  some_command &
#         _spinner $! "Doing something"
_spinner() {
    local pid="$1" msg="$2"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local colors=("$G1" "$G2" "$G3" "$G4" "$G5")
    local n=${#frames[@]}
    local nc=${#colors[@]}
    local i=0 start=$SECONDS

    tput civis 2>/dev/null

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( SECONDS - start ))
        local ts
        ts=$(_fmt_elapsed "$elapsed")
        # Cycle spinner color every ~3 seconds
        local ci=0
        (( nc > 0 )) && ci=$(( (elapsed / 3) % nc ))
        printf "\r%s%s%s  %s %s%s%s  " "${colors[$ci]}" "${frames[i % n]}" "$RST" "$msg" "$DIM" "$ts" "$RST"
        (( i++ )) || true
        sleep 0.08
    done

    printf "\r\033[K"
    tput cnorm 2>/dev/null
}

# Live progress monitor — polls the rsync output file for progress lines,
# displays bytes transferred / percentage / speed, and prints each file
# as it is transferred in real time.
# Usage:  rsync ... > tmpfile &
#         _progress_monitor $! tmpfile "label"
_progress_monitor() {
    local pid="$1" tmpfile="$2" label="$3"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local colors=("$G1" "$G2" "$G3" "$G4" "$G5")
    local n=${#frames[@]}
    local nc=${#colors[@]}
    local i=0 start=$SECONDS last_progress="" last_elapsed=-1
    local shown_files=0

    tput civis 2>/dev/null

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( SECONDS - start ))
        local ts
        ts=$(_fmt_elapsed "$elapsed")

        # Every ~0.5s, check for newly transferred files and print them live
        if (( i % 3 == 0 )); then
            local new_files
            new_files=$(tr '\r' '\n' < "$tmpfile" 2>/dev/null \
                | grep -E '^[><]f|^\*deleting' \
                | tail -n +$(( shown_files + 1 ))) || true
            if [[ -n "$new_files" ]]; then
                local new_count=0
                while IFS= read -r fline; do
                    [[ -z "$fline" ]] && continue
                    printf "\r\033[K"
                    _print_file_line "$fline"
                    (( new_count++ )) || true
                done <<< "$new_files"
                (( shown_files += new_count )) || true
            fi
        fi

        # Read last 2KB of output, extract latest progress line (contains %)
        local pline
        pline=$(tail -c 2048 "$tmpfile" 2>/dev/null | tr '\r' '\n' | grep -E '[0-9].*%' | tail -1) || true

        if [[ -n "$pline" ]]; then
            pline="${pline#"${pline%%[! ]*}"}"      # trim leading whitespace
            pline="${pline%% (xfr#*}"               # trim (xfr#N, to-chk=M/T)
            pline="${pline%% (xfr*}"                # trim alternate format
            # Only redraw when progress data or elapsed second changes
            if [[ "$pline" != "$last_progress" ]] || (( elapsed != last_elapsed )); then
                printf "\r\033[K  ${G3}⟫${RST}  ${BOLD}${label}${RST}  %s  ${DIM}%s${RST}" "$pline" "$ts"
                last_progress="$pline"
                last_elapsed=$elapsed
            fi
        else
            # No progress data yet — show animated spinner
            local ci=0
            (( nc > 0 )) && ci=$(( (elapsed / 3) % nc ))
            printf "\r%s%s%s  Syncing ${BOLD}${label}${RST}  ${DIM}%s${RST}  " "${colors[$ci]}" "${frames[i % n]}" "$RST" "$ts"
        fi

        (( i++ )) || true
        sleep 0.15
    done

    # After process ends, show any remaining files not yet displayed
    local remaining
    remaining=$(tr '\r' '\n' < "$tmpfile" 2>/dev/null \
        | grep -E '^[><]f|^\*deleting' \
        | tail -n +$(( shown_files + 1 ))) || true
    if [[ -n "$remaining" ]]; then
        while IFS= read -r fline; do
            [[ -z "$fline" ]] && continue
            printf "\r\033[K"
            _print_file_line "$fline"
            (( shown_files++ )) || true
        done <<< "$remaining"
    fi

    _MONITOR_SHOWN_FILES=$shown_files
    printf "\r\033[K"
    tput cnorm 2>/dev/null
}

_confirm_or_abort() {
    local msg="$1"
    local answer
    read -r -p "${DIM}$(_ts)${RST}  ${YELLOW}${SYM_WARN}${RST}  ${msg} Type ${BOLD}yes${RST} to confirm: " answer
    if [[ "$answer" == "yes" ]]; then
        return 0
    fi
    log "Operation cancelled."
    return 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  SAFETY — atomic lockfile, cleanup
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

acquire_lock() {
    # mkdir is atomic on all POSIX systems — no race condition
    local mkdir_err
    if mkdir_err=$(mkdir "$LOCKDIR" 2>&1); then
        echo "$$" > "$LOCKDIR/pid"
        return
    fi
    # mkdir failed — could be EEXIST (another instance) or something else
    if [[ ! -d "$LOCKDIR" ]]; then
        # Lock dir doesn't exist → mkdir failed for a non-EEXIST reason (perms, disk full, ...)
        die "Cannot create lock directory ${LOCKDIR}: ${mkdir_err}"
    fi
    # Lock exists — check if the holder is still alive
    local old_pid
    old_pid=$(<"$LOCKDIR/pid" 2>/dev/null) || old_pid=""
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        die "Another instance is already running (PID ${old_pid})."
    fi
    # Stale lock from a crashed run — reclaim it
    warn "Reclaiming stale lock from previous run (PID ${old_pid:-?})."
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || die "Cannot acquire lock after reclaim: check permissions on /tmp."
    echo "$$" > "$LOCKDIR/pid"
}

# Globals for safe cleanup of background work
_BG_PID=""
_TMPFILES=()
_MONITOR_SHOWN_FILES=0

_mktemp() {
    local f
    f=$(mktemp)
    _TMPFILES+=("$f")
    echo "$f"
}

_CLEANUP_DONE=0
cleanup() {
    (( _CLEANUP_DONE )) && return
    _CLEANUP_DONE=1
    tput cnorm 2>/dev/null
    if [[ -n "$_BG_PID" ]] && kill -0 "$_BG_PID" 2>/dev/null; then
        kill "$_BG_PID" 2>/dev/null
        wait "$_BG_PID" 2>/dev/null
    fi
    for f in "${_TMPFILES[@]}"; do rm -f "$f" 2>/dev/null; done
    rm -rf "$LOCKDIR"
}
_handle_interrupt() {
    printf '\n'
    warn "Interrupted."
    cleanup
    exit 130
}
trap cleanup EXIT
trap _handle_interrupt INT TERM HUP

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  EXCLUSION ARRAYS — built once at startup
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Strip rsync's "*deleting   filename" → "filename" (pure bash, no subshell)
_strip_deleting() {
    local s="${1#\*deleting}"
    echo "${s#"${s%%[! ]*}"}"      # trim leading spaces
}

# Convert a glob pattern to a POSIX extended regex (for fswatch --exclude)
_glob_to_regex() {
    local pat="$1"
    pat="${pat//./\\.}"     # escape literal dots
    pat="${pat//\*/.*}"     # glob * → regex .*
    pat="${pat//\?/.}"      # glob ? → regex .
    echo "$pat"
}

# Print a single file-change line with appropriate symbol and color
_print_file_line() {
    local line="$1"
    if [[ "$line" =~ ^\>f ]]; then
        printf '    %s %s\n' "${GREEN}${SYM_UP}${RST}" "${line:12}"
    elif [[ "$line" =~ ^\<f ]]; then
        printf '    %s %s\n' "${BLUE}${SYM_DOWN}${RST}" "${line:12}"
    elif [[ "$line" == \*deleting* ]]; then
        printf '    %s %s\n' "${RED}${SYM_DEL}${RST}" "$(_strip_deleting "$line")"
    fi
}

# Base exclusions (used for full push/pull and sync-dir pulls)
RSYNC_EXCL=()
for pat in "${EXCLUSIONS[@]}"; do
    RSYNC_EXCL+=("--exclude=${pat}")
done

# Exclusions + SYNC_DIRS (used when pushing code — skip data dirs)
RSYNC_EXCL_CODE=("${RSYNC_EXCL[@]}")
for dir in "${SYNC_DIRS[@]}"; do
    RSYNC_EXCL_CODE+=("--exclude=${dir}")
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  CORE — rsync wrapper with delete confirmation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# do_rsync LABEL SRC DST [--auto-delete] [extra rsync flags...]
#
# 1. Dry-run with --delete to discover what would be removed
# 2. If deletions found → prompt user (unless --auto-delete)
# 3. Actual transfer (with or without --delete based on answer)
do_rsync() {
    local label="$1" src="$2" dst="$3"
    shift 3

    local auto_delete=false
    if [[ "${1:-}" == "--auto-delete" ]]; then
        auto_delete=true
        shift
    fi

    # Remaining args are extra rsync flags (exclusions, etc.)
    local extra_flags=("$@")

    # Base command (without --delete and without src/dst)
    local cmd=(
        sshpass -e
        rsync -e "$SSH_CMD"
        "${RSYNC_BASE_OPTS[@]}"
        "${extra_flags[@]}"
    )

    # ── Phase 1: dry-run to detect deletions ────────────────────────────
    _debug "do_rsync label=${label} src=${src} dst=${dst} auto_delete=${auto_delete}"
    _debug "dry-run cmd: ${cmd[*]} --delete --dry-run ${src} ${dst}"
    local dry_tmpfile
    dry_tmpfile=$(_mktemp)
    "${cmd[@]}" --delete --dry-run "$src" "$dst" > "$dry_tmpfile" 2>&1 &
    _BG_PID=$!
    _spinner "$_BG_PID" "Scanning ${BOLD}${label}${RST}"
    wait "$_BG_PID"
    local dry_rc=$?
    _BG_PID=""
    local dry_output
    dry_output=$(<"$dry_tmpfile")
    rm -f "$dry_tmpfile"

    if (( dry_rc != 0 )); then
        err "Scan failed for ${BOLD}${label}${RST} (exit ${dry_rc})"
        if (( DEBUG )); then
            _debug "full dry-run output follows:"
            printf '%s\n' "$dry_output" >&2
        else
            printf '%s\n' "$dry_output" | tail -5
        fi
        if (( dry_rc == 255 )) || (( dry_rc == 5 )); then
            warn "Connection issue — is the server reachable? Try: ${BOLD}./synchronize.sh test${RST}"
        fi
        return 1
    fi

    # Collect deletions and count changes (no need to store change lines)
    local deletions=()
    local n_changes=0
    while IFS= read -r line; do
        if [[ "$line" == \*deleting* ]]; then
            deletions+=("$(_strip_deleting "$line")")
        elif [[ "$line" =~ ^\> ]] || [[ "$line" =~ ^\< ]]; then
            (( n_changes++ )) || true
        fi
    done <<< "$dry_output"

    # Show a preview of what will transfer
    local n_deletions=${#deletions[@]}
    local total=$((n_changes + n_deletions))

    if (( total == 0 )); then
        ok "${label}: ${DIM}already up to date.${RST}"
        return 0
    fi

    local t_s="s"; (( n_changes == 1 )) && t_s=""
    local d_s="s"; (( n_deletions == 1 )) && d_s=""
    log "${BOLD}${total}${RST} change(s) detected (${GREEN}${n_changes} transfer${t_s}${RST}, ${RED}${n_deletions} deletion${d_s}${RST})"

    # ── Phase 2: handle deletions ───────────────────────────────────────
    local use_delete=false
    if (( n_deletions > 0 )); then
        echo ""
        warn "${RED}${n_deletions} file(s)/folder(s) will be DELETED on the destination:${RST}"
        echo ""
        for f in "${deletions[@]}"; do
            printf '%s\n' "      ${RED}${SYM_DEL}  ${f}${RST}"
        done
        echo ""

        if $auto_delete; then
            warn "Auto-delete enabled (watch mode) — proceeding with deletions."
            use_delete=true
        else
            printf '%s\n' "    ${BOLD}[y]${RST} Sync WITH deletions"
            printf '%s\n' "    ${BOLD}[s]${RST} Sync WITHOUT deletions (skip deletes)"
            printf '%s\n' "    ${BOLD}[n]${RST} Cancel this operation"
            echo ""
            local answer
            read -r -p "    ${BOLD}❯${RST} " answer
            case "$answer" in
                [yY]|[yY][eE][sS])
                    use_delete=true
                    ;;
                [sS]|[sS][kK][iI][pP])
                    use_delete=false
                    warn "Syncing WITHOUT deletions."
                    ;;
                *)
                    log "Operation cancelled."
                    return 1
                    ;;
            esac
        fi
    fi

    # ── Phase 3: actual transfer with live progress ─────────────────────
    local start=$SECONDS
    log "Syncing ${BOLD}${label}${RST} ..."

    local actual_cmd=("${cmd[@]}" "$RSYNC_PROGRESS_FLAG")
    $use_delete && actual_cmd+=(--delete)

    _debug "transfer cmd: ${actual_cmd[*]} ${src} ${dst}"
    local tmpfile
    tmpfile=$(_mktemp)
    _MONITOR_SHOWN_FILES=0
    "${actual_cmd[@]}" "$src" "$dst" > "$tmpfile" 2>&1 &
    _BG_PID=$!
    _progress_monitor "$_BG_PID" "$tmpfile" "$label"
    wait "$_BG_PID"
    local rc=$?
    _BG_PID=""
    local elapsed=$(( SECONDS - start ))

    if (( rc != 0 )); then
        err "Rsync failed for ${BOLD}${label}${RST} (exit ${rc})"
        if (( DEBUG )); then
            _debug "full rsync output follows:"
            cat "$tmpfile" >&2
        else
            tail -10 "$tmpfile"
        fi
        rm -f "$tmpfile"
        if (( rc == 30 )); then
            warn "Timeout — the connection stalled for >${RSYNC_IO_TIMEOUT}s. Check network/VPN."
        elif (( rc == 5 )); then
            warn "Authentication error — check that \$SSHPASS / password file is correct."
        elif (( rc == 12 )); then
            warn "Protocol error — rsync version mismatch between local and remote?"
        elif (( rc == 23 )); then
            warn "Partial transfer — some files could not be transferred (permissions?)."
        elif (( rc == 24 )); then
            warn "Vanished files — some source files disappeared during transfer."
        elif (( rc == 255 )); then
            warn "Connection lost during transfer. Check network/VPN."
        fi
        return 1
    fi

    # ── Display results ─────────────────────────────────────────────────
    _display_results "$tmpfile" "$label" "$elapsed"
    rm -f "$tmpfile"
}

_display_results() {
    local tmpfile="$1" label="$2" elapsed="$3"

    # Use tr + grep (fast C tools) instead of bash string ops on huge output.
    # The old approach — output="${output//$'\r'/$'\n'}" then a bash while-read
    # loop — was O(n²) and caused multi-second delays on large syncs.
    local clean
    clean=$(tr '\r' '\n' < "$tmpfile")

    local all_changes
    all_changes=$(grep -E '^[><]f|^\*deleting' <<< "$clean" || true)

    # Count changes using grep -c (fast)
    local sent=0 recv=0 deleted=0
    if [[ -n "$all_changes" ]]; then
        sent=$(grep -cE '^>f' <<< "$all_changes") || sent=0
        recv=$(grep -cE '^<f' <<< "$all_changes") || recv=0
        deleted=$(grep -cF '*deleting' <<< "$all_changes") || deleted=0
    fi

    local total=$(( sent + recv + deleted ))

    if (( total == 0 )); then
        ok "${label}: ${DIM}already up to date${RST} ${DIM}($(_fmt_elapsed "$elapsed"))${RST}"
        return
    fi

    # Show any files not already displayed by the progress monitor
    if (( total > _MONITOR_SHOWN_FILES )); then
        echo ""
        local remaining
        remaining=$(tail -n +$(( _MONITOR_SHOWN_FILES + 1 )) <<< "$all_changes")
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            _print_file_line "$line"
        done <<< "$remaining"
    fi

    # Extract transfer speed and total size from rsync --stats output
    local xfer_speed total_size
    xfer_speed=$(grep -oE '[0-9,.]+[KMG]? bytes/sec' <<< "$clean" | head -1) || true
    total_size=$(grep -E '^Total transferred file size' <<< "$clean" | grep -oE '[0-9,.]+[KMG]?' | head -1) || true

    # Summary line
    echo ""
    local summary="${BOLD}${label}${RST}:"
    (( sent > 0 ))    && summary+="  ${GREEN}${sent} sent${RST}"
    (( recv > 0 ))    && summary+="  ${BLUE}${recv} received${RST}"
    (( deleted > 0 )) && summary+="  ${RED}${deleted} deleted${RST}"
    local meta
    meta=$(_fmt_elapsed "$elapsed")
    [[ -n "${total_size:-}" ]] && meta="${total_size} bytes, ${meta}"
    [[ -n "${xfer_speed:-}" ]] && meta+=", ${xfer_speed}"
    summary+="  ${DIM}(${meta})${RST}"
    ok "$summary"

    # Terminal bell for long-running syncs so you hear when it's done
    (( elapsed > 30 )) && printf '\a'
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  OPERATIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

op_send_code() {
    header "${SYM_UP} Send Local Code to Remote"
    do_rsync "code" \
        "${LOCAL_PROJECT}" \
        "${REMOTE}:${SERVER_PATH}" \
        "${RSYNC_EXCL_CODE[@]}"
}

op_pull_sync_dirs() {
    header "${SYM_DOWN} Pull Sync Directories from Remote"
    local rc=0
    for dir in "${SYNC_DIRS[@]}"; do
        local parent_dir
        parent_dir=$(dirname "$dir")
        local dest="${LOCAL_PROJECT}/${parent_dir}"

        if [[ ! -d "$dest" ]]; then
            die "Local directory '${dest}' does not exist."
        fi

        do_rsync "sync/${dir}" \
            "${REMOTE}:${REMOTE_PROJECT}/${dir}" \
            "${dest}" \
            "${RSYNC_EXCL[@]}" || rc=1
    done
    return "$rc"
}

op_send_and_pull() {
    local start=$SECONDS rc=0
    op_send_code || rc=1
    echo ""
    op_pull_sync_dirs || rc=1
    echo ""
    separator
    if (( rc == 0 )); then
        ok "${BOLD}Send + Pull complete${RST} ${DIM}(total: $(_fmt_elapsed $(( SECONDS - start ))))${RST}"
    else
        warn "${BOLD}Send + Pull finished with errors${RST} ${DIM}(total: $(_fmt_elapsed $(( SECONDS - start ))))${RST}"
    fi
}

op_push_all() {
    header "${SYM_UP} Push Everything to Remote"
    warn "This will overwrite the remote project with your local copy."
    _confirm_or_abort "You are about to push everything to the server." || return 0
    do_rsync "push-all" \
        "${LOCAL_PROJECT}" \
        "${REMOTE}:${SERVER_PATH}" \
        "${RSYNC_EXCL[@]}"
}

op_pull_all() {
    header "${SYM_DOWN} Pull Everything from Remote"
    warn "This will overwrite your local project with the remote copy."
    _confirm_or_abort "You are about to pull everything from the server." || return 0
    do_rsync "pull-all" \
        "${REMOTE}:${REMOTE_PROJECT}" \
        "${LOCAL_PATH}" \
        "${RSYNC_EXCL[@]}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  WATCH MODE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

op_watch() {
    header "${SYM_WATCH} Watch Mode"

    if command -v fswatch &>/dev/null; then
        _watch_fswatch
    else
        warn "fswatch not found — falling back to polling every ${WATCH_INTERVAL}s."
        warn "Install for instant detection: ${BOLD}brew install fswatch${RST}"
        echo ""
        _watch_polling
    fi
}

_watch_fswatch() {
    log "Watching ${BOLD}${LOCAL_PROJECT}${RST} via fswatch"
    log "Press ${BOLD}Ctrl+C${RST} to stop."
    echo ""

    # Build fswatch exclusion regexes (convert globs → POSIX extended regex)
    local fswatch_excl=()
    for pat in "${EXCLUSIONS[@]}" "${SYNC_DIRS[@]}"; do
        fswatch_excl+=(--exclude "$(_glob_to_regex "$pat")")
    done

    # Debounce: fswatch -o batches events and outputs a count
    fswatch -o -l 2 "${fswatch_excl[@]}" "${LOCAL_PROJECT}" \
        | while read -r n_events; do
            log "${YELLOW}${n_events} change(s) detected${RST} — syncing ..."
            do_rsync "auto-sync" \
                "${LOCAL_PROJECT}" \
                "${REMOTE}:${SERVER_PATH}" \
                --auto-delete \
                "${RSYNC_EXCL_CODE[@]}" \
            || warn "Sync failed — will retry on next change."
            echo ""
            log "Watching for changes ..."
        done
}

_watch_polling() {
    log "Polling ${BOLD}${LOCAL_PROJECT}${RST} every ${WATCH_INTERVAL}s"
    log "Press ${BOLD}Ctrl+C${RST} to stop."
    echo ""

    # Build find args once (they never change)
    local find_args=("${LOCAL_PROJECT}" -type f)
    for pat in "${EXCLUSIONS[@]}" "${SYNC_DIRS[@]}"; do
        find_args+=(! -path "*${pat}*")
    done

    # Use a reference file + find -newer instead of hashing every file.
    # This is O(1) on no-change polls (stops at first match) vs O(n) for md5.
    local ref_file
    ref_file=$(_mktemp)
    touch "$ref_file"
    log "Initial snapshot captured."

    # Allocate once — reuse by truncating each iteration (avoids _TMPFILES leak)
    local find_stderr_file
    find_stderr_file=$(_mktemp)
    local find_errors=0
    while true; do
        sleep "$WATCH_INTERVAL"
        # find piped to head -1 stops early via SIGPIPE — no need for GNU -quit
        : > "$find_stderr_file"
        if [[ -n "$(find "${find_args[@]}" -newer "$ref_file" -print 2>"$find_stderr_file" | head -1)" ]]; then
            log "${YELLOW}Changes detected${RST} — syncing ..."
            do_rsync "auto-sync" \
                "${LOCAL_PROJECT}" \
                "${REMOTE}:${SERVER_PATH}" \
                --auto-delete \
                "${RSYNC_EXCL_CODE[@]}" \
            || warn "Sync failed — will retry."
            touch "$ref_file"
            find_errors=0
            echo ""
            log "Watching for changes ..."
        elif [[ -s "$find_stderr_file" ]]; then
            # find produced errors — warn once, then throttle to avoid spam
            if (( find_errors == 0 )); then
                warn "find encountered errors while scanning:"
                head -3 "$find_stderr_file" | while IFS= read -r eline; do
                    printf '  %s\n' "${DIM}${eline}${RST}" >&2
                done
            fi
            (( find_errors++ )) || true
        fi
    done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  STATUS & CONNECTION TEST
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

op_status() {
    header "${SYM_INFO} Configuration"
    printf "  ${DIM}%-12s${RST}  ${BOLD}%s${RST}\n" "Project"    "$PROJECT_NAME"
    printf "  ${DIM}%-12s${RST}  %s\n"              "Local"      "$LOCAL_PROJECT"
    printf "  ${DIM}%-12s${RST}  %s:%s\n"           "Remote"     "$REMOTE" "$REMOTE_PROJECT"
    printf "  ${DIM}%-12s${RST}  %s\n"              "Sync dirs"  "${SYNC_DIRS[*]}"
    printf "  ${DIM}%-12s${RST}  %s\n"              "Exclusions" "${EXCLUSIONS[*]}"
    printf "  ${DIM}%-12s${RST}  %s\n"              "SSH"        "$SSH_CMD"
    printf "  ${DIM}%-12s${RST}  %s\n"              "Lock"       "$LOCKDIR"
    printf "  ${DIM}%-12s${RST}  %s\n"              "Progress"   "$RSYNC_PROGRESS_FLAG"
    printf "  ${DIM}%-12s${RST}  %s\n"              "rsync"      "$RSYNC_VERSION_STR"
    printf "  ${DIM}%-12s${RST}  %s\n"              "I/O timeout" "${RSYNC_IO_TIMEOUT}s"
    if (( DEBUG )); then
        printf "  ${DIM}%-12s${RST}  ${YELLOW}%s${RST}\n"  "Debug"       "ON (SYNCHRONIZE_DEBUG=1)"
    fi
    echo ""
}

op_test() {
    local start=$SECONDS
    local test_tmpfile
    test_tmpfile=$(_mktemp)
    sshpass -e ssh -o LogLevel=error -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" "${REMOTE}" "echo ok" > "$test_tmpfile" 2>&1 &
    _BG_PID=$!
    _spinner "$_BG_PID" "Connecting to ${BOLD}${REMOTE_HOST}${RST}"
    wait "$_BG_PID"
    local rc=$?
    _BG_PID=""
    local elapsed=$(( SECONDS - start ))
    local test_output
    test_output=$(<"$test_tmpfile")
    rm -f "$test_tmpfile"
    if (( rc == 0 )); then
        ok "Connected to ${BOLD}${REMOTE_HOST}${RST} ${DIM}($(_fmt_elapsed "$elapsed"))${RST}"
    else
        err "Cannot reach ${BOLD}${REMOTE_HOST}${RST} (exit ${rc}). Check VPN / network."
        if [[ -n "$test_output" ]]; then
            printf '  %s\n' "${DIM}${test_output}${RST}" >&2
        fi
        return 1
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  INTERACTIVE MENU
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

_show_banner() {
    echo ""
    separator
    printf '%s\n' "  ${G1}⚡${RST} ${G1}s${G1}y${G2}n${G2}c${G3}h${G3}r${G4}o${G4}n${G5}i${G5}z${G5}e${RST}  ${DIM}·${RST}  ${BOLD}${PROJECT_NAME}${RST}  ${DIM}$(date +'%a %b %d, %H:%M')${RST}"
    printf '%s\n' "     ${DIM}${LOCAL_PROJECT}${RST}"
    printf '%s\n' "  ${G5}   ↕${RST}  ${DIM}${REMOTE}:${REMOTE_PROJECT}${RST}"
    separator
}

_show_menu() {
    echo ""
    printf '%s\n' "  ${DIM}SYNC${RST}"
    printf '%s\n' "  ${G1}1${RST}  ${SYM_UP}  Send local code to remote"
    printf '%s\n' "  ${G2}2${RST}  ${SYM_DOWN}  Pull sync directories from remote"
    printf '%s\n' "  ${G3}3${RST}  ${SYM_UPDOWN}  Send code + pull sync dirs"
    printf '%s\n' "  ${G4}4${RST}  ${SYM_WATCH}  Watch for changes (auto-sync)"
    _dim_separator
    printf '%s\n' "  ${DIM}FULL${RST}"
    printf '%s\n' "  ${YELLOW}5${RST}  ${SYM_UP}  Push ${BOLD}everything${RST} to remote"
    printf '%s\n' "  ${YELLOW}6${RST}  ${SYM_DOWN}  Pull ${BOLD}everything${RST} from remote"
    _dim_separator
    printf '%s\n' "  ${DIM}INFO${RST}"
    printf '%s\n' "  ${CYAN}s${RST}  ${SYM_INFO}  Show status"
    printf '%s\n' "  ${CYAN}t${RST}  ${SYM_INFO}  Test connection"
    printf '%s\n' "  ${CYAN}h${RST}  ?  Help"
    printf '%s\n' "  ${DIM}q${RST}     ${DIM}Exit${RST}"
    echo ""
}

interactive() {
    local session_start=$SECONDS
    while true; do
        _show_banner
        _show_menu
        local option
        read -r -p "  ${BOLD}❯${RST} " option || { echo ""; break; }
        case "$option" in
            1)     op_send_code ;;
            2)     op_pull_sync_dirs ;;
            3)     op_send_and_pull ;;
            4)     op_watch ;;
            5)     op_push_all ;;
            6)     op_pull_all ;;
            s|S)   op_status ;;
            t|T)   op_test ;;
            h|H)   _show_help ;;
            q|Q)
                echo ""
                separator
                ok "${G5}Session complete${RST} ${DIM}($(_fmt_elapsed $(( SECONDS - session_start ))))${RST}"
                break
                ;;
            "")    ;;  # Enter refreshes the menu
            *)     warn "Invalid option '${option}' — press ${BOLD}h${RST} for help" ;;
        esac
    done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  CLI ENTRY POINT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

_show_help() {
    echo ""
    separator
    printf '%s\n' "  ${G1}⚡${RST} ${G1}s${G1}y${G2}n${G2}c${G3}h${G3}r${G4}o${G4}n${G5}i${G5}z${G5}e${RST}${DIM}.sh${RST}  ${DIM}— rsync-based project sync for HPC${RST}"
    separator
    echo ""
    printf '%s\n' "  ${BOLD}USAGE${RST}"
    printf '%s\n' "    ./synchronize.sh ${DIM}[command]${RST}"
    echo ""
    printf '%s\n' "  ${BOLD}WHAT THIS DOES${RST}"
    printf '%s\n' "    Keeps your local project in sync with a remote server using rsync."
    printf '%s\n' "    Only files that have changed are transferred, making it fast."
    echo ""
    printf '%s\n' "    ${BOLD}\"Code\"${RST}        = your project files (src, configs, scripts, ...)"
    printf '%s\n' "                    Flows: ${GREEN}laptop → server${RST}. Sync dirs are skipped."
    printf '%s\n' "    ${BOLD}\"Sync dirs\"${RST}   = large server-side outputs (checkpoints, results)"
    printf '%s\n' "                    Flows: ${BLUE}server → laptop${RST}. Currently: ${BOLD}${SYNC_DIRS[*]}${RST}"
    printf '%s\n' "    ${BOLD}\"Exclusions\"${RST}  = files never synced: ${DIM}${EXCLUSIONS[*]}${RST}"
    echo ""
    printf '%s\n' "  ${BOLD}COMMANDS${RST}"
    echo ""
    printf '%s\n' "    ${GREEN}send${RST}        Upload local code → server."
    printf '%s\n' "                ${DIM}Syncs everything except sync dirs and exclusions.${RST}"
    printf '%s\n' "                ${DIM}If you deleted a file locally, you'll be asked whether${RST}"
    printf '%s\n' "                ${DIM}to delete it on the server too.${RST}"
    echo ""
    printf '%s\n' "    ${GREEN}pull${RST}        Download sync directories ← server."
    printf '%s\n' "                ${DIM}Only fetches the directories in SYNC_DIRS.${RST}"
    printf '%s\n' "                ${DIM}Great for grabbing training outputs & checkpoints.${RST}"
    echo ""
    printf '%s\n' "    ${GREEN}send-pull${RST}   Send code, then pull sync dirs. ${DIM}(Most common workflow.)${RST}"
    echo ""
    printf '%s\n' "    ${YELLOW}push-all${RST}    Upload ${BOLD}everything${RST} → server.  ${RED}⚠ Overwrites remote.${RST}"
    printf '%s\n' "                ${DIM}Requires confirmation. Use for initial setup.${RST}"
    echo ""
    printf '%s\n' "    ${YELLOW}pull-all${RST}    Download ${BOLD}everything${RST} ← server.  ${RED}⚠ Overwrites local.${RST}"
    printf '%s\n' "                ${DIM}Requires confirmation. Use to clone server state.${RST}"
    echo ""
    printf '%s\n' "    ${CYAN}watch${RST}       Auto-sync: watches files and runs 'send' on change."
    printf '%s\n' "                ${DIM}Uses fswatch if installed, otherwise polls every ${WATCH_INTERVAL}s.${RST}"
    echo ""
    printf '%s\n' "    ${CYAN}status${RST}      Show current configuration (paths, exclusions, etc.)."
    printf '%s\n' "    ${CYAN}test${RST}        Test SSH connection to the remote server."
    printf '%s\n' "    ${DIM}help${RST}        Show this help."
    echo ""
    printf '%s\n' "  ${BOLD}SAFETY${RST}"
    printf '%s\n' "    Before transferring, a dry-run detects what would change."
    printf '%s\n' "    If files would be ${RED}deleted${RST}, you choose:"
    printf '%s\n' "      ${BOLD}[y]${RST} sync with deletions   ${BOLD}[s]${RST} skip deletions   ${BOLD}[n]${RST} cancel"
    echo ""
    printf '%s\n' "  ${BOLD}DEBUGGING${RST}"
    printf '%s\n' "    Set ${BOLD}SYNCHRONIZE_DEBUG=1${RST} to see full rsync commands and output."
    printf '%s\n' "    ${DIM}Example: SYNCHRONIZE_DEBUG=1 ./synchronize.sh send${RST}"
    echo ""
    printf '%s\n' "  Run without arguments for interactive mode."
    echo ""
}

main() {
    acquire_lock

    case "${1:-}" in
        send)       op_send_code ;;
        pull)       op_pull_sync_dirs ;;
        send-pull)  op_send_and_pull ;;
        push-all)   op_push_all ;;
        pull-all)   op_pull_all ;;
        watch)      op_watch ;;
        status)     op_status ;;
        test)       op_test ;;
        help|-h|--help)
            _show_help
            ;;
        "")         interactive ;;
        *)          die "Unknown command '${1}'. Try: ./synchronize.sh help" ;;
    esac
}

main "$@"
