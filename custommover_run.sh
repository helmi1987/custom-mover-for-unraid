#!/bin/bash
# ==============================================================================
# Smart Mover for Unraid (custommover_run.sh) – V7
#
# Wrapper around the official Unraid move binary. For every user share whose
# mover direction is set in /boot/config/shares/<share>.cfg, files are filtered
# by age and exclude lists and then piped to the move binary:
#
#   shareUseCache="yes"     Primary: pool, Secondary: array/pool2, Mover: pool -> array (or pool2)
#                           Source scanned: /mnt/<pool>/<share>
#   shareUseCache="prefer"  Primary: pool, Secondary: array/pool2, Mover: array (or pool2) -> pool
#                           Source scanned: /mnt/user0/<share> (or /mnt/<pool2>/<share>)
#   "only" / "no"           nothing to move, skipped
#
# Usage:
#   custommover_run.sh                 dry-run (default): show what would move, touch nothing
#   custommover_run.sh --run           move for real
#   custommover_run.sh --force         ignore the age filter (exclude lists still apply)
#   custommover_run.sh --force-all     ignore age AND exclude lists
#   custommover_run.sh --share "A,B"   only these shares
#   custommover_run.sh --list-shares   show discovered shares, direction and effective settings
#   custommover_run.sh --help
#
# Environment variables (override INI / defaults; CLI flags take precedence):
#   CUSTOMMOVER_MODE          dry | run
#   CUSTOMMOVER_FORCE         age | all
#   CUSTOMMOVER_SHARES        comma separated share filter
#   CUSTOMMOVER_INI           path to smart_mover.ini      (default: <script dir>/smart_mover.ini)
#   CUSTOMMOVER_LOG_LEVEL     DEBUG | INFO | WARN         (default: INFO)
#   CUSTOMMOVER_MOVER_DEBUG   0-3, -d level for the move binary (overrides INI mover_debug)
#   CUSTOMMOVER_IGNORE_MOVER  1 = run even if the stock Unraid mover is currently running
#   CUSTOMMOVER_SHARES_DIR    share config dir           (default: /boot/config/shares, for tests)
#   CUSTOMMOVER_MNT           mount root                 (default: /mnt, for tests)
#
# INI (smart_mover.ini):
#   [GLOBAL]  mover_bin, log_file, min_age (days), age_stat (ctime|mtime), global_excludes (comma list),
#             move_when_used_above (percent, 0 = always), move_prefer_shares (yes|no), mover_debug (0-3),
#             max_list (dry-run lines shown on console)
#   [<Share>] min_age, age_stat, excludes, move_when_used_above, skip=yes
#
# Exclude files: one entry per line, comments (#) and blank lines ignored, CRLF tolerated.
#   /abs/path/dir          protects the directory and everything below it
#   /abs/path/file.mkv     protects exactly that file (an EmbyCache exclude list works as-is)
#   *.nfo  or  Season 0*   glob against the file name (no slash) or the full path (with slash)
#   anything else          substring match on the full path (legacy behaviour)
#   /mnt/user/<share>/...  and /mnt/user0/<share>/... are translated to the scanned source root
# ==============================================================================

set -u -o pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
INI_FILE="${CUSTOMMOVER_INI:-$SCRIPT_DIR/smart_mover.ini}"
SHARES_DIR="${CUSTOMMOVER_SHARES_DIR:-/boot/config/shares}"
MNT="${CUSTOMMOVER_MNT:-/mnt}"
LOCK_FILE="$SCRIPT_DIR/.custommover.lock"
MOVER_PIDFILE="/var/run/mover.pid"
LOG_LEVEL="${CUSTOMMOVER_LOG_LEVEL:-INFO}"

DRY_RUN=true
FORCE_AGE=false
FORCE_ALL=false
LIST_ONLY=false
TARGET_SHARES="${CUSTOMMOVER_SHARES:-}"
[[ "${CUSTOMMOVER_MODE:-dry}" == "run" ]] && DRY_RUN=false
case "${CUSTOMMOVER_FORCE:-}" in age) FORCE_AGE=true ;; all) FORCE_AGE=true; FORCE_ALL=true ;; esac

usage() {  # prints the header comment block above
    awk 'NR > 2 && /^# =====/ { exit } NR > 2 { sub(/^# ?/, ""); print }' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)         DRY_RUN=false; shift ;;
        --force)       FORCE_AGE=true; shift ;;
        --force-all)   FORCE_AGE=true; FORCE_ALL=true; shift ;;
        --share)       [[ $# -ge 2 ]] || { echo "--share needs a value"; exit 1; }; TARGET_SHARES="$2"; shift 2 ;;
        --list-shares) LIST_ONLY=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done

# ------------------------------------------------------------------ INI
[[ -f "$INI_FILE" ]] || { echo "Error: $INI_FILE missing – run setup_custommover.sh first."; exit 1; }

get_ini_val() {  # section key
    awk -v sec="[$1]" -v key="$2" '
        { sub(/\r$/, "") }
        /^[ \t]*[#;]/ { next }
        /^[ \t]*\[/ { line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line); insec = (line == sec); next }
        insec {
            i = index($0, "=")
            if (i == 0) next
            k = substr($0, 1, i - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k == key) { v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
        }' "$INI_FILE"
}

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

MOVER_BIN=$(get_ini_val GLOBAL mover_bin)
LOG_FILE=$(get_ini_val GLOBAL log_file)
GLOBAL_MIN_AGE=$(get_ini_val GLOBAL min_age)
GLOBAL_AGE_STAT=$(get_ini_val GLOBAL age_stat)
GLOBAL_EXC=$(get_ini_val GLOBAL global_excludes)
GLOBAL_THRESHOLD=$(get_ini_val GLOBAL move_when_used_above)
MOVE_PREFER=$(get_ini_val GLOBAL move_prefer_shares)
MOVER_DEBUG=$(get_ini_val GLOBAL mover_debug)
MAX_LIST=$(get_ini_val GLOBAL max_list)

if [[ -z "$MOVER_BIN" ]]; then
    for cand in /usr/libexec/unraid/move /usr/local/sbin/move /usr/local/bin/move; do
        [[ -x "$cand" ]] && { MOVER_BIN="$cand"; break; }
    done
fi
: "${GLOBAL_MIN_AGE:=0}" "${GLOBAL_AGE_STAT:=ctime}" "${GLOBAL_THRESHOLD:=0}" "${MOVE_PREFER:=yes}" "${MOVER_DEBUG:=0}" "${MAX_LIST:=50}"
[[ -z "$LOG_FILE" ]] && LOG_FILE="$SCRIPT_DIR/smart_mover.log"
MOVER_DEBUG="${CUSTOMMOVER_MOVER_DEBUG:-$MOVER_DEBUG}"

# ------------------------------------------------------------------ Logging
mkdir -p "$(dirname "$LOG_FILE")"
if [[ -t 1 ]]; then GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GREY='\033[0;90m'; NC='\033[0m'
else GREEN=''; YELLOW=''; RED=''; GREY=''; NC=''; fi

rotate_logs() {
    [[ -f "$LOG_FILE" ]] || return 0
    (( $(stat -c%s "$LOG_FILE") > 10485760 )) || return 0
    for i in {19..1}; do [[ -f "$LOG_FILE.$i" ]] && mv -f "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"; done
    mv -f "$LOG_FILE" "$LOG_FILE.1"
}

log() {  # level message
    local level="$1"; shift
    local msg="$*" ts c=$NC
    [[ "$level" == "DEBUG" && "$LOG_LEVEL" != "DEBUG" ]] && return 0
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in INFO) c=$GREEN ;; WARN) c=$YELLOW ;; ERROR) c=$RED ;; DEBUG) c=$GREY ;; esac
    printf '%b[%s] [%s] %s%b\n' "$c" "$ts" "$level" "$msg" "$NC"
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE"
}

die() { log ERROR "$*"; exit 1; }

human() {
    local b=$1 u=(B KB MB GB TB PB) i=0
    while (( b >= 1024 && i < 5 )); do b=$(( b / 1024 )); (( i++ )); done
    echo "$b ${u[$i]}"
}

# ------------------------------------------------------------------ Validation
is_int "$GLOBAL_MIN_AGE" || die "GLOBAL min_age must be a whole number of days (got '$GLOBAL_MIN_AGE')"
is_int "$GLOBAL_THRESHOLD" || die "GLOBAL move_when_used_above must be a percentage 0-100 (got '$GLOBAL_THRESHOLD')"
is_int "$MOVER_DEBUG" || die "mover_debug must be 0-3"
[[ "$GLOBAL_AGE_STAT" == "ctime" || "$GLOBAL_AGE_STAT" == "mtime" ]] || die "age_stat must be ctime or mtime"
[[ -d "$SHARES_DIR" ]] || die "Share config directory not found: $SHARES_DIR"

# ------------------------------------------------------------------ Lock / stock mover
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another Smart Mover run is active ($LOCK_FILE) – exiting."; exit 2
fi
stock_mover_running() {
    local pid
    pid=$(cat "$MOVER_PIDFILE" 2>/dev/null) || return 1
    [[ -n "$pid" && -d "/proc/$pid" ]]
}

# ------------------------------------------------------------------ Excludes
# Builds EXCL_ARGS (find expression fragments) for one share. Patterns pointing into
# /mnt/user/<share> or /mnt/user0/<share> are rewritten to the scanned source root.
build_excludes() {  # share_name source_root exclude_files(comma list)...
    local share="$1" src="$2"; shift 2
    EXCL_ARGS=(-false)
    EXCL_COUNT=0
    local f line
    for f in "$@"; do
        f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
        [[ -z "$f" ]] && continue
        if [[ ! -f "$f" ]]; then log WARN "  exclude file not found: $f"; continue; fi
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue
            line="${line%/}"
            line="${line/#$MNT\/user\/$share/$src}"
            line="${line/#$MNT\/user0\/$share/$src}"
            case "$line" in
                /*)  # absolute path: file or subtree
                    EXCL_ARGS+=(-o -path "$line" -o -path "$line/*") ;;
                *[\*\?\[]*)  # glob
                    if [[ "$line" == */* ]]; then EXCL_ARGS+=(-o -path "$line"); else EXCL_ARGS+=(-o -name "$line"); fi ;;
                *)   # substring (legacy)
                    EXCL_ARGS+=(-o -path "*$line*") ;;
            esac
            (( EXCL_COUNT++ )) || true
        done < "$f"
    done
}

# ------------------------------------------------------------------ Cleanup
remove_empty_parents() {  # root file...
    local root="$1"; shift
    local -A seen=()
    local f d
    for f in "$@"; do
        d=$(dirname "$f")
        while [[ "$d" == "$root/"* && -z "${seen[$d]:-}" ]]; do
            seen[$d]=1
            if [[ -d "$d" ]] && rmdir "$d" 2>/dev/null; then
                log INFO "  removed empty directory: $d"
            else
                break
            fi
            d=$(dirname "$d")
        done
    done
}

# ------------------------------------------------------------------ Share processing
TOTAL_FILES=0; TOTAL_BYTES=0; TOTAL_MOVED=0; TOTAL_LEFT=0

process_share() {  # name mode pool pool2
    local name="$1" mode="$2" pool="$3" pool2="$4"
    local src direction age_days age_stat threshold excludes skip
    local min_age_override

    skip=$(get_ini_val "$name" skip)
    if [[ "$skip" == "yes" ]]; then log INFO "[$name] skip=yes in INI"; return 0; fi

    case "$mode" in
        yes)
            src="$MNT/$pool/$name"
            direction="$pool -> ${pool2:-array}" ;;
        prefer)
            if [[ "$MOVE_PREFER" != "yes" ]]; then log INFO "[$name] prefer share, move_prefer_shares=no – skipped"; return 0; fi
            if [[ -n "$pool2" ]]; then src="$MNT/$pool2/$name"; else src="$MNT/user0/$name"; fi
            direction="${pool2:-array} -> $pool" ;;
        *)  return 0 ;;
    esac

    min_age_override=$(get_ini_val "$name" min_age)
    age_stat=$(get_ini_val "$name" age_stat); : "${age_stat:=$GLOBAL_AGE_STAT}"
    threshold=$(get_ini_val "$name" move_when_used_above); : "${threshold:=$GLOBAL_THRESHOLD}"
    excludes=$(get_ini_val "$name" excludes)
    if [[ "$mode" == "prefer" ]]; then
        age_days="${min_age_override:-0}"   # bringing files back to the pool: no age filter unless set per share
    else
        age_days="${min_age_override:-$GLOBAL_MIN_AGE}"
    fi
    is_int "$age_days" || { log ERROR "[$name] min_age '$age_days' is not a number – share skipped"; return 1; }
    is_int "$threshold" || { log ERROR "[$name] move_when_used_above '$threshold' is not a number – share skipped"; return 1; }
    [[ "$age_stat" == "ctime" || "$age_stat" == "mtime" ]] || { log ERROR "[$name] age_stat must be ctime|mtime – share skipped"; return 1; }

    if [[ "$LIST_ONLY" == true ]]; then
        printf '  %-24s %-7s %-24s age>%s d (%s)  threshold %s%%  excludes: %s\n' "$name" "$mode" "$direction" "$age_days" "$age_stat" "$threshold" "${excludes:-${GLOBAL_EXC:-none}}"
        return 0
    fi

    log INFO "[$name] $direction  (source: $src)"
    if [[ ! -d "$src" ]]; then log INFO "  nothing on the source side – skipped"; return 0; fi

    # Threshold: only move when the pool that should be freed is fuller than X% (pool -> array shares only)
    if [[ "$mode" == "yes" ]] && (( threshold > 0 )) && [[ "$FORCE_AGE" == false ]]; then
        local used
        used=$(df --output=pcent "$MNT/$pool" 2>/dev/null | tail -1 | tr -dc '0-9')
        if [[ -n "$used" ]] && (( used < threshold )); then
            log INFO "  pool $pool at ${used}% < threshold ${threshold}% – nothing moved"
            return 0
        fi
        log INFO "  pool $pool at ${used:-?}% >= threshold ${threshold}%"
    fi

    # Age filter
    local -a AGE_ARGS=()
    if [[ "$FORCE_AGE" == true ]]; then
        log WARN "  FORCE: age filter ignored (configured: $age_days days)"
    elif (( age_days > 0 )); then
        local mins=$(( age_days * 1440 )) flag="-cmin"
        [[ "$age_stat" == "mtime" ]] && flag="-mmin"
        AGE_ARGS=("$flag" "+$mins")
        log INFO "  age filter: older than $age_days days ($age_stat)"
    else
        log INFO "  age filter: none (0 days)"
    fi

    # Excludes
    EXCL_ARGS=(-false); EXCL_COUNT=0
    if [[ "$FORCE_ALL" == true ]]; then
        log WARN "  FORCE-ALL: exclude lists ignored"
    else
        local -a EXCL_FILES=()
        IFS=',' read -ra EXCL_FILES <<< "$GLOBAL_EXC,$excludes"
        build_excludes "$name" "$src" "${EXCL_FILES[@]}"
        (( EXCL_COUNT > 0 )) && log INFO "  excludes: $EXCL_COUNT patterns"
    fi

    # Find candidates (files and symlinks; excluded dirs are pruned, excluded files dropped)
    local -a FILES=()
    local find_err
    find_err=$(mktemp)
    mapfile -d '' FILES < <(find "$src" \( "${EXCL_ARGS[@]}" \) -prune -o \( -type f -o -type l \) "${AGE_ARGS[@]}" -print0 2>"$find_err")
    if [[ -s "$find_err" ]]; then while IFS= read -r line; do log WARN "  find: $line"; done < "$find_err"; fi
    rm -f "$find_err"

    # Drop names containing newlines – the move binary reads one path per line
    local -a CLEAN=() f
    for f in "${FILES[@]}"; do
        if [[ "$f" == *$'\n'* ]]; then log WARN "  skipped (newline in name): ${f//$'\n'/\\n}"; else CLEAN+=("$f"); fi
    done
    FILES=("${CLEAN[@]}")

    local count=${#FILES[@]}
    if (( count == 0 )); then log INFO "  no files match"; return 0; fi
    local bytes
    bytes=$(printf '%s\0' "${FILES[@]}" | xargs -0 stat -c %s 2>/dev/null | awk '{s+=$1} END {print s+0}')
    (( TOTAL_FILES += count, TOTAL_BYTES += bytes )) || true

    if [[ "$DRY_RUN" == true ]]; then
        log INFO "  [DRY-RUN] would move $count files ($(human "$bytes"))"
        local i=0
        for f in "${FILES[@]}"; do
            (( i++ )) || true
            if (( i <= MAX_LIST )); then printf '     %s\n' "$f"; fi
            printf '[DRY-RUN]     %s\n' "$f" >> "$LOG_FILE"
        done
        (( count > MAX_LIST )) && echo "     ... $((count - MAX_LIST)) more (full list in $LOG_FILE)"
        return 0
    fi

    # Execute
    log INFO "  moving $count files ($(human "$bytes")) via $MOVER_BIN"
    local mover_out rc
    mover_out=$(mktemp)
    local -a MOVER_CMD=("$MOVER_BIN")
    (( MOVER_DEBUG > 0 )) && MOVER_CMD+=(-d "$MOVER_DEBUG")
    printf '%s\n' "${FILES[@]}" | "${MOVER_CMD[@]}" >"$mover_out" 2>&1
    rc=$?
    while IFS= read -r line; do log DEBUG "  mover: $line"; done < "$mover_out"
    if (( rc != 0 )); then
        log ERROR "  move binary exited with code $rc – see $LOG_FILE (mover_debug=1 for details)"
        [[ "$LOG_LEVEL" != "DEBUG" ]] && tail -n 5 "$mover_out" | while IFS= read -r line; do log ERROR "  mover: $line"; done
    fi
    rm -f "$mover_out"

    # Verify: what is still on the source side?
    local -a MOVED=() LEFT=()
    for f in "${FILES[@]}"; do
        if [[ -e "$f" || -L "$f" ]]; then LEFT+=("$f"); else MOVED+=("$f"); fi
    done
    (( TOTAL_MOVED += ${#MOVED[@]}, TOTAL_LEFT += ${#LEFT[@]} )) || true
    log INFO "  moved ${#MOVED[@]} of $count files"
    if (( ${#LEFT[@]} > 0 )); then
        log WARN "  ${#LEFT[@]} files still on the source side (in use, or already present at the destination):"
        local i=0
        for f in "${LEFT[@]}"; do (( i++ )) || true; (( i <= 10 )) && log WARN "     $f"; done
        (( ${#LEFT[@]} > 10 )) && log WARN "     ... $(( ${#LEFT[@]} - 10 )) more"
    fi
    (( ${#MOVED[@]} > 0 )) && remove_empty_parents "$src" "${MOVED[@]}"
    return 0
}

# ------------------------------------------------------------------ Main
rotate_logs
if [[ "$LIST_ONLY" == false ]]; then
    log INFO "=== Smart Mover start ($([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo LIVE)) ==="
    [[ -n "$TARGET_SHARES" ]] && log INFO "share filter: $TARGET_SHARES"
    if stock_mover_running && [[ "${CUSTOMMOVER_IGNORE_MOVER:-0}" != "1" ]]; then
        log WARN "The stock Unraid mover is running ($MOVER_PIDFILE) – aborting to avoid moving the same files twice. Set CUSTOMMOVER_IGNORE_MOVER=1 to override."
        exit 2
    fi
    if [[ "$DRY_RUN" == false ]]; then
        [[ -n "$MOVER_BIN" && -x "$MOVER_BIN" ]] || die "move binary not found or not executable: '${MOVER_BIN:-<empty>}' (set mover_bin in $INI_FILE)"
    fi
else
    echo "Shares discovered in $SHARES_DIR (mode yes/prefer only):"
fi

shopt -s nullglob
FOUND=0
for cfg in "$SHARES_DIR"/*.cfg; do
    SHARE_NAME=$(basename "$cfg" .cfg)
    MODE=$(sed -n 's/^shareUseCache="\([^"]*\)".*/\1/p' "$cfg" | tr -d '\r' | head -1)
    [[ "$MODE" == "yes" || "$MODE" == "prefer" ]] || continue
    if [[ -n "$TARGET_SHARES" && ",$TARGET_SHARES," != *",$SHARE_NAME,"* ]]; then continue; fi
    POOL=$(sed -n 's/^shareCachePool="\([^"]*\)".*/\1/p' "$cfg" | tr -d '\r' | head -1)
    POOL2=$(sed -n 's/^shareCachePool2="\([^"]*\)".*/\1/p' "$cfg" | tr -d '\r' | head -1)
    [[ -z "$POOL" ]] && POOL="cache"
    (( FOUND++ )) || true
    process_share "$SHARE_NAME" "$MODE" "$POOL" "$POOL2" || true
done
shopt -u nullglob

if [[ "$LIST_ONLY" == true ]]; then
    (( FOUND == 0 )) && echo "  (none)"
    exit 0
fi
(( FOUND == 0 )) && log WARN "no share with shareUseCache yes/prefer found in $SHARES_DIR${TARGET_SHARES:+ matching '$TARGET_SHARES'}"
if [[ "$DRY_RUN" == true ]]; then
    log INFO "=== Finished (dry-run): $TOTAL_FILES files, $(human "$TOTAL_BYTES") would move ==="
else
    log INFO "=== Finished: $TOTAL_MOVED moved, $TOTAL_LEFT left of $TOTAL_FILES candidates ($(human "$TOTAL_BYTES")) ==="
fi
exit 0
