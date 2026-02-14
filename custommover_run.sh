#!/bin/bash
# ==============================================================================
# Script: smart_mover.sh (V6.1 Dynamic & Precision)
# Description: Dynamically scans Unraid Shares at runtime.
#              Uses CMIN (Minutes) for precise age calculation.
# ==============================================================================

set -u

# --- CONSTANTS ---
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
INI_FILE="$SCRIPT_DIR/smart_mover.ini"
TEMP_EXCLUDE_FILE="/tmp/smart_mover_excludes.tmp"

# Flags
DRY_RUN=true
FORCE_AGE=false
FORCE_ALL=false
TARGET_SHARES=""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- ERROR HANDLING ---
trap 'handle_error $? $LINENO' ERR
handle_error() {
    log_message "ERROR" "Script failed at line $2 with exit code $1"
    rm -f "$TEMP_EXCLUDE_FILE"
    exit $1
}

# --- ARGS ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)       DRY_RUN=false; shift ;;
        --force)     FORCE_AGE=true; shift ;;
        --force-all) FORCE_ALL=true; FORCE_AGE=true; shift ;;
        --share)     TARGET_SHARES="$2"; shift 2 ;;
        --help)      echo "Usage: $0 [--run] [--force] [--force-all] [--share \"Name,Name\"]"; exit 0 ;;
        *)           echo "Unknown: $1"; exit 1 ;;
    esac
done

# --- LOAD GLOBAL CONFIG ---
if [[ ! -f "$INI_FILE" ]]; then echo "Error: $INI_FILE missing."; exit 1; fi

get_ini_val() {
    local section=$1
    local key=$2
    sed -n "/^\[$section\]/,/^\[/p" "$INI_FILE" | grep "^$key=" | cut -d= -f2-
}

MOVER_BIN=$(get_ini_val "GLOBAL" "mover_bin")
LOG_FILE=$(get_ini_val "GLOBAL" "log_file")
GLOBAL_MIN_AGE=$(get_ini_val "GLOBAL" "min_age")
GLOBAL_EXC=$(get_ini_val "GLOBAL" "global_excludes")

# Fallbacks
[[ -z "$MOVER_BIN" ]] && MOVER_BIN="/usr/local/bin/move"
[[ -z "$GLOBAL_MIN_AGE" ]] && GLOBAL_MIN_AGE=0
[[ -z "$LOG_FILE" ]] && LOG_FILE="$SCRIPT_DIR/smart_mover.log"

# --- LOGGING ---
rotate_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        if (( $(stat -c%s "$LOG_FILE") > 10485760 )); then
            for i in {19..1}; do [[ -f "$LOG_FILE.$i" ]] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"; done
            mv "$LOG_FILE" "$LOG_FILE.1"
        fi
    fi
}

log_message() {
    local level="$1"; local msg="$2"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local c=$NC
    case "$level" in "INFO") c=$GREEN;; "WARN") c=$YELLOW;; "ERROR") c=$RED;; esac
    echo -e "${c}[$ts] [$level] $msg${NC}"
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"
}

# --- FUNCTIONS ---
run_cleanup() {
    local list="$1"; local root="$2"
    [[ -z "$list" ]] && return
    log_message "INFO" "Cleaning empty directories..."
    
    echo "$list" | xargs -n1 dirname | sort -u | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2- | while read -r d; do
        # Safety: Only delete if inside share root AND not the root itself
        if [[ "$d" != "$root" && "$d" == "$root"* && -d "$d" ]]; then
            rmdir "$d" 2>/dev/null
            [[ ! -d "$d" ]] && log_message "INFO" "  -> Removed: $d"
        fi
    done
}

process_share() {
    local name="$1"
    local path="$2"
    local min_age="$3"
    local excludes="$4"
    
    log_message "INFO" "Processing Share: [$name] (Path: $path)"
    
    if [[ ! -d "$path" ]]; then
        log_message "WARN" "  -> Path not found (Skipping)"
        return
    fi

    # 1. Prepare Excludes
    rm -f "$TEMP_EXCLUDE_FILE"
    touch "$TEMP_EXCLUDE_FILE"
    if [[ "$FORCE_ALL" == false ]]; then
        for f in ${GLOBAL_EXC//,/ } ${excludes//,/ }; do
            [[ -f "$f" ]] && cat "$f" >> "$TEMP_EXCLUDE_FILE"
        done
    fi

    # 2. Age Calculation (Minutes Precision)
    local age_days="${min_age:-$GLOBAL_MIN_AGE}"
    local find_args=""
    
    if [[ "$FORCE_AGE" == true ]]; then
        log_message "WARN" "  -> FORCE: Ignoring age ($age_days days)"
    else
        if (( age_days > 0 )); then
            # HIER PASSIERT DIE MAGIE: Tage * 1440 = Minuten
            local mins=$((age_days * 1440))
            find_args="-cmin +$mins"
            log_message "INFO" "  -> Filter: > $age_days days ($mins mins CTIME)"
        else
            log_message "INFO" "  -> Filter: Immediate (0 days)"
        fi
    fi

    # 3. Find
    # -depth processes content before directory itself
    local files
    files=$(find "$path" -depth -type f $find_args)
    
    if [[ -z "$files" ]]; then
        log_message "INFO" "  -> No files match age."
        return
    fi

    # 4. Exclude
    local targets="$files"
    if [[ -s "$TEMP_EXCLUDE_FILE" ]]; then
        targets=$(echo "$files" | grep -v -F -f "$TEMP_EXCLUDE_FILE")
    fi

    if [[ -z "$targets" ]]; then
        log_message "INFO" "  -> All files excluded."
        return
    fi

    # 5. Execute
    local count=$(echo "$targets" | wc -l)
    if [[ "$DRY_RUN" == true ]]; then
        log_message "INFO" "  -> [DRY-RUN] Would move $count files:"
        echo "$targets" | sed 's/^/     /'
    else
        log_message "INFO" "  -> Moving $count files..."
        echo "$targets" | "$MOVER_BIN"
        
        # Check Exit Code
        if [[ $? -eq 0 ]]; then
            log_message "INFO" "  -> Move successful."
            run_cleanup "$targets" "$path"
        else
            log_message "ERROR" "  -> Mover failed."
        fi
    fi
}


# --- MAIN ---
mkdir -p "$(dirname "$LOG_FILE")"
rotate_logs
log_message "INFO" "=== Starting Smart Mover (Dynamic) ==="
[[ "$DRY_RUN" == true ]] && log_message "WARN" "DRY-RUN MODE" || log_message "INFO" "LIVE MODE"
[[ -n "$TARGET_SHARES" ]] && log_message "INFO" "FILTER: Shares=$TARGET_SHARES"

# DYNAMIC DISCOVERY LOOP
for cfg in /boot/config/shares/*.cfg; do
    SHARE_NAME=$(basename "$cfg" .cfg)
    
    # Check if share is enabled for cache move
    if grep -qE 'shareUseCache="(yes|prefer)"' "$cfg"; then
        
        # Check Filters
        if [[ -n "$TARGET_SHARES" ]]; then
            if [[ ",$TARGET_SHARES," != *",$SHARE_NAME,"* ]]; then continue; fi
        fi

        # Detect Pool
        POOL=$(grep 'shareCachePool=' "$cfg" | cut -d'"' -f2)
        [[ -z "$POOL" ]] && POOL="cache"
        
        # Construct Path
        SHARE_PATH="/mnt/$POOL/$SHARE_NAME"
        
        # Check for INI Overrides
        OVERRIDE_AGE=$(get_ini_val "$SHARE_NAME" "min_age")
        OVERRIDE_EXC=$(get_ini_val "$SHARE_NAME" "excludes")
        
        # Execute
        process_share "$SHARE_NAME" "$SHARE_PATH" "$OVERRIDE_AGE" "$OVERRIDE_EXC"
    fi
done

rm -f "$TEMP_EXCLUDE_FILE"
log_message "INFO" "=== Finished ==="
