#!/bin/bash
# ==============================================================================
# Smart Mover for Unraid – interactive setup (setup_custommover.sh) – V7
#
# Writes smart_mover.ini next to the scripts (or to $CUSTOMMOVER_INI). Global
# settings first, then optional per-share overrides for every share whose mover
# direction is set (shareUseCache yes/prefer). Paths are never stored: the run
# script derives them from /boot/config/shares at runtime.
#
# Environment: CUSTOMMOVER_INI, CUSTOMMOVER_SHARES_DIR (default /boot/config/shares)
# ==============================================================================

set -u

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
INI_FILE="${CUSTOMMOVER_INI:-$SCRIPT_DIR/smart_mover.ini}"
SHARES_DIR="${CUSTOMMOVER_SHARES_DIR:-/boot/config/shares}"
TEMP_INI="$(mktemp)"
trap 'rm -f "$TEMP_INI"' EXIT

if [[ -t 1 ]]; then GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
else GREEN=''; BLUE=''; YELLOW=''; CYAN=''; RED=''; NC=''; fi

echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}   Smart Mover – Setup V7${NC}"
echo -e "${BLUE}==============================================${NC}"
echo -e "   INI: $INI_FILE"
echo -e "   Only GLOBAL settings and optional per-share overrides are stored;"
echo -e "   share paths and directions come from $SHARES_DIR at runtime."
echo -e "${BLUE}==============================================${NC}"

# --- helpers -------------------------------------------------------------------
get_ini_value() {  # section key
    [[ -f "$INI_FILE" ]] || return 0
    awk -v sec="[$1]" -v key="$2" '
        { sub(/\r$/, "") }
        /^[ \t]*[#;]/ { next }
        /^[ \t]*\[/ { line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line); insec = (line == sec); next }
        insec { i = index($0, "="); if (i == 0) next
                k = substr($0, 1, i - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
                if (k == key) { v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } }' "$INI_FILE"
}

ask_int() {  # prompt default min max -> echoes value
    local val
    while true; do
        read -e -i "$2" -p "$1: " val; [[ -z "$val" ]] && val="$2"
        if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= $3 && val <= $4 )); then echo "$val"; return; fi
        echo -e "   ${RED}Please enter a whole number between $3 and $4.${NC}" >&2
    done
}

ask_choice() {  # prompt default choices(space separated)
    local val
    while true; do
        read -e -i "$2" -p "$1 [$3]: " val; [[ -z "$val" ]] && val="$2"
        for c in $3; do [[ "$val" == "$c" ]] && { echo "$val"; return; }; done
        echo -e "   ${RED}Please enter one of: $3${NC}" >&2
    done
}

ask_for_files() {  # prompt current_list -> echoes comma list
    local current="$2" collected="" input real
    echo -e "${YELLOW}$1${NC}" >&2
    if [[ -n "$current" ]]; then
        echo -e "   Current: ${CYAN}$current${NC}" >&2
        read -p "   Keep these? [Y/n = clear]: " -n 1 -r resp >&2; echo "" >&2
        [[ "$resp" =~ ^[Nn]$ ]] || collected="$current"
    fi
    echo -e "   Add exclude files (TAB completes, empty line finishes). Lines: /abs/dir, /abs/file, *.nfo, substring" >&2
    while true; do
        read -e -p "   > Add file: " input
        [[ -z "$input" ]] && break
        if [[ -f "$input" ]]; then real=$(realpath "$input"); else real="$input"; echo -e "   ${YELLOW}(file does not exist yet – stored anyway)${NC}" >&2; fi
        [[ -z "$collected" ]] && collected="$real" || collected="$collected,$real"
    done
    echo "$collected"
}

share_mode() { sed -n 's/^shareUseCache="\([^"]*\)".*/\1/p' "$1" | tr -d '\r' | head -1; }
share_pool() { local p; p=$(sed -n 's/^shareCachePool="\([^"]*\)".*/\1/p' "$1" | tr -d '\r' | head -1); echo "${p:-cache}"; }
share_pool2() { sed -n 's/^shareCachePool2="\([^"]*\)".*/\1/p' "$1" | tr -d '\r' | head -1; }

[[ -d "$SHARES_DIR" ]] || { echo -e "${RED}Share config directory not found: $SHARES_DIR${NC}"; exit 1; }

# --- 1. GLOBAL -------------------------------------------------------------------
echo -e "\n${BLUE}[1] Global settings${NC}"
MOVER_BIN=$(get_ini_value GLOBAL mover_bin)
if [[ -z "$MOVER_BIN" || ! -x "$MOVER_BIN" ]]; then
    MOVER_BIN=""
    for cand in /usr/libexec/unraid/move /usr/local/sbin/move /usr/local/bin/move; do [[ -x "$cand" ]] && { MOVER_BIN="$cand"; break; }; done
fi
if [[ -z "$MOVER_BIN" ]]; then
    echo -e "   ${YELLOW}Unraid move binary not found – enter the path (leave empty to decide later):${NC}"
    read -e -p "   mover_bin: " MOVER_BIN
else
    echo -e "   Mover binary: ${GREEN}$MOVER_BIN${NC}"
fi

OLD=$(get_ini_value GLOBAL log_file); DEF_LOG="${OLD:-$SCRIPT_DIR/smart_mover.log}"
read -e -i "$DEF_LOG" -p "   Log file: " LOG_FILE; [[ -z "$LOG_FILE" ]] && LOG_FILE="$DEF_LOG"
OLD=$(get_ini_value GLOBAL min_age); GLOBAL_MIN_AGE=$(ask_int "   Global min age in days (0 = move immediately)" "${OLD:-0}" 0 36500)
OLD=$(get_ini_value GLOBAL age_stat); GLOBAL_AGE_STAT=$(ask_choice "   Age based on" "${OLD:-ctime}" "ctime mtime")
echo -e "   ${CYAN}ctime = time the file landed on the pool (survives rsync -a, but chmod/chown resets it); mtime = file modification time${NC}"
OLD=$(get_ini_value GLOBAL move_when_used_above); GLOBAL_THRESHOLD=$(ask_int "   Only move when pool usage is above % (0 = always)" "${OLD:-0}" 0 100)
OLD=$(get_ini_value GLOBAL move_prefer_shares); MOVE_PREFER=$(ask_choice "   Also handle 'prefer' shares (array -> pool, like the stock mover)" "${OLD:-yes}" "yes no")
OLD=$(get_ini_value GLOBAL mover_debug); MOVER_DEBUG=$(ask_int "   Mover debug level 0-3 (1 logs every moved file)" "${OLD:-0}" 0 3)
OLD=$(get_ini_value GLOBAL global_excludes); GLOBAL_EXCLUDES=$(ask_for_files "   Global exclude files (apply to ALL shares):" "$OLD")

{
    echo "# Smart Mover configuration – generated by setup_custommover.sh"
    echo "[GLOBAL]"
    echo "mover_bin=$MOVER_BIN"
    echo "log_file=$LOG_FILE"
    echo "min_age=$GLOBAL_MIN_AGE"
    echo "age_stat=$GLOBAL_AGE_STAT"
    echo "move_when_used_above=$GLOBAL_THRESHOLD"
    echo "move_prefer_shares=$MOVE_PREFER"
    echo "mover_debug=$MOVER_DEBUG"
    echo "global_excludes=$GLOBAL_EXCLUDES"
    echo ""
} > "$TEMP_INI"

# --- 2. SHARE OVERRIDES ------------------------------------------------------------
echo -e "\n${BLUE}[2] Share overrides (optional)${NC}"
echo -e "   Only shares that need settings different from GLOBAL."

shopt -s nullglob
for cfg in "$SHARES_DIR"/*.cfg; do
    SHARE_NAME=$(basename "$cfg" .cfg)
    MODE=$(share_mode "$cfg")
    [[ "$MODE" == "yes" || "$MODE" == "prefer" ]] || continue
    POOL=$(share_pool "$cfg"); POOL2=$(share_pool2 "$cfg")
    if [[ "$MODE" == "yes" ]]; then DIRECTION="$POOL -> ${POOL2:-array}"; else DIRECTION="${POOL2:-array} -> $POOL"; fi

    OLD_S_AGE=$(get_ini_value "$SHARE_NAME" min_age)
    OLD_S_STAT=$(get_ini_value "$SHARE_NAME" age_stat)
    OLD_S_THR=$(get_ini_value "$SHARE_NAME" move_when_used_above)
    OLD_S_EXC=$(get_ini_value "$SHARE_NAME" excludes)
    OLD_S_SKIP=$(get_ini_value "$SHARE_NAME" skip)
    HAS_OVERRIDE=false
    [[ -n "$OLD_S_AGE$OLD_S_STAT$OLD_S_THR$OLD_S_EXC$OLD_S_SKIP" ]] && HAS_OVERRIDE=true

    echo -e "\n----------------------------------------------"
    echo -e "Share ${GREEN}[$SHARE_NAME]${NC}  mode: $MODE  direction: ${CYAN}$DIRECTION${NC}"
    DO_CONFIG=false
    if [[ "$HAS_OVERRIDE" == true ]]; then
        echo -e "   Custom settings: age=${CYAN}${OLD_S_AGE:-global}${NC} age_stat=${CYAN}${OLD_S_STAT:-global}${NC} threshold=${CYAN}${OLD_S_THR:-global}${NC} skip=${CYAN}${OLD_S_SKIP:-no}${NC}"
        echo -e "   Excludes: ${CYAN}${OLD_S_EXC:-none}${NC}"
        read -p "   [K]eep / [E]dit / [D]elete (back to global) [K/e/d]: " -n 1 -r ACTION; echo ""
        case "$ACTION" in
            [Dd]*) echo "   -> reverted to global defaults."; continue ;;
            [Ee]*) DO_CONFIG=true ;;
            *)     { echo "[$SHARE_NAME]"
                     [[ -n "$OLD_S_AGE" ]] && echo "min_age=$OLD_S_AGE"
                     [[ -n "$OLD_S_STAT" ]] && echo "age_stat=$OLD_S_STAT"
                     [[ -n "$OLD_S_THR" ]] && echo "move_when_used_above=$OLD_S_THR"
                     [[ -n "$OLD_S_EXC" ]] && echo "excludes=$OLD_S_EXC"
                     [[ -n "$OLD_S_SKIP" ]] && echo "skip=$OLD_S_SKIP"
                     echo ""; } >> "$TEMP_INI"
                   continue ;;
        esac
    else
        echo -e "   Uses global defaults."
        read -p "   Create custom rule? [y/N]: " -n 1 -r ADD_NEW; echo ""
        [[ "$ADD_NEW" =~ ^[Yy]$ ]] && DO_CONFIG=true
    fi

    if [[ "$DO_CONFIG" == true ]]; then
        SKIP=$(ask_choice "   Skip this share entirely" "${OLD_S_SKIP:-no}" "yes no")
        if [[ "$SKIP" == "yes" ]]; then
            printf '[%s]\nskip=yes\n\n' "$SHARE_NAME" >> "$TEMP_INI"
            echo -e "   ${GREEN}-> share will be skipped.${NC}"
            continue
        fi
        if [[ "$MODE" == "prefer" ]]; then
            echo -e "   ${CYAN}prefer share: files come back to the pool; the global age filter does not apply here${NC}"
            read -e -i "${OLD_S_AGE:-}" -p "   Min age in days (empty = no age filter): " SHARE_AGE
        else
            read -e -i "${OLD_S_AGE:-}" -p "   Min age in days (empty = global $GLOBAL_MIN_AGE): " SHARE_AGE
        fi
        [[ -n "$SHARE_AGE" && ! "$SHARE_AGE" =~ ^[0-9]+$ ]] && { echo -e "   ${RED}not a number – ignored${NC}"; SHARE_AGE=""; }
        read -e -i "${OLD_S_STAT:-}" -p "   Age based on ctime|mtime (empty = global $GLOBAL_AGE_STAT): " SHARE_STAT
        [[ -n "$SHARE_STAT" && "$SHARE_STAT" != "ctime" && "$SHARE_STAT" != "mtime" ]] && { echo -e "   ${RED}must be ctime or mtime – ignored${NC}"; SHARE_STAT=""; }
        SHARE_THR=""
        if [[ "$MODE" == "yes" ]]; then
            read -e -i "${OLD_S_THR:-}" -p "   Only move when pool usage above % (empty = global $GLOBAL_THRESHOLD): " SHARE_THR
            [[ -n "$SHARE_THR" && ! "$SHARE_THR" =~ ^[0-9]+$ ]] && { echo -e "   ${RED}not a number – ignored${NC}"; SHARE_THR=""; }
        fi
        SHARE_EXCLUDES=$(ask_for_files "   Share exclude files (in addition to global):" "$OLD_S_EXC")
        if [[ -z "$SHARE_AGE$SHARE_STAT$SHARE_THR$SHARE_EXCLUDES" ]]; then
            echo -e "   -> nothing set, share uses global defaults."
            continue
        fi
        { echo "[$SHARE_NAME]"
          [[ -n "$SHARE_AGE" ]] && echo "min_age=$SHARE_AGE"
          [[ -n "$SHARE_STAT" ]] && echo "age_stat=$SHARE_STAT"
          [[ -n "$SHARE_THR" ]] && echo "move_when_used_above=$SHARE_THR"
          [[ -n "$SHARE_EXCLUDES" ]] && echo "excludes=$SHARE_EXCLUDES"
          echo ""; } >> "$TEMP_INI"
        echo -e "   ${GREEN}-> override saved.${NC}"
    fi
done
shopt -u nullglob

mkdir -p "$(dirname "$INI_FILE")"
cp "$TEMP_INI" "$INI_FILE"
echo -e "\n${BLUE}==============================================${NC}"
echo -e "${GREEN}Configuration saved: $INI_FILE${NC}"
echo -e "Next: $SCRIPT_DIR/custommover_run.sh --list-shares, then a dry-run without --run."
