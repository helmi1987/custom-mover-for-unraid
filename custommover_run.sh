#!/bin/bash
# ==============================================================================
# Script: smart_mover.sh
# Description: Executes the Smart Mover logic based on smart_mover.ini
#              Filters files by age (CMIN precision)/exclude and pipes to Unraid Mover.
# ==============================================================================

set -u

# --- CONSTANTS & DEFAULTS ---
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
INI_FILE="$SCRIPT_DIR/smart_mover.ini"
TEMP_EXCLUDE_FILE="/tmp/smart_mover_excludes.tmp"

# Flags
DRY_RUN=true
FORCE_AGE=false
FORCE_ALL=false
TARGET_SHARES=""

# Colors for Console Output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- ERROR HANDLING ---
trap 'handle_error $? $LINENO' ERR

handle_error() {
    local exit_code=$1
    local line_no=$2
    log_message "ERROR" "Script failed at line $line_no with exit code $exit_code"
    rm -f "$TEMP_EXCLUDE_FILE"
    exit $exit_code
}

# --- ARGUMENT PARSING ---
show_help() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --run              ACTIVATE script (Disable Dry-Run)"
    echo "  --force            Ignore file age (min_age), but respect excludes"
    echo "  --force-all        Ignore file age AND excludes (Move everything!)"
    echo "  --share \"Name\"     Only process specific shares (comma separated)"
    echo "  --help             Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)       DRY_RUN=false; shift ;;
        --force)     FORCE_AGE=true; shift ;;
        --force-all) FORCE_ALL=true; FORCE_AGE=true; shift ;;
        --share)     TARGET_SHARES="$2"; shift 2 ;;
        --help)      show_help ;;
        *)           echo "Unknown option: $1"; show_help ;;
    esac
done

# --- CONFIG LOADING ---
if [[ ! -f "$INI_FILE" ]]; then
    echo -e "${RED}Error: Configuration file not found at $INI_FILE${NC}"
    echo "Please run setup.sh first."
    exit 1
fi

get_global_val() {
    local key=$1
    sed -n "/^\[GLOBAL\]/,/^\[/p" "$INI_FILE" | grep "^$key=" | cut -d= -f2-
}

MOVER_BIN=$(get_global_val "mover_bin")
LOG_DIR_PATH=$(get_global_val "log_dir")
GLOBAL_MIN_AGE=$(get_global_val "min_age")
GLOBAL_EXCLUDES=$(get_global_val "global_excludes")

[[ -z "$MOVER_BIN" ]] && MOVER_BIN="/usr/local/bin/move"
[[ -z "$GLOBAL_MIN_AGE" ]] && GLOBAL_MIN_AGE=0
[[ -z "$LOG_DIR_PATH" ]] && LOG_DIR_PATH="$SCRIPT_DIR/logs"

LOG_FILE="$LOG_DIR_PATH/smart_mover.log"

# --- LOGGING & ROTATION ---
rotate_logs() {
    mkdir -p "$LOG_DIR_PATH"
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -c%s "$LOG_FILE")
        if (( size > 10485760 )); then
            echo "Rotating log file..."
            for i in {19..1}; do
                [[ -f "$LOG_FILE.$i" ]] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
            done
            mv "$LOG_FILE" "$LOG_FILE.1"
        fi
    fi
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    case "$level" in
        "INFO") color="$GREEN" ;;
        "WARN") color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
    esac
    echo -e "${color}[$timestamp] [$level] $message${NC}"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# --- CORE FUNCTIONS ---
run_cleanup() {
    local moved_files_list="$1"
    local share_root="$2"
    
    if [[ -z "$moved_files_list" ]]; then return; fi
    
    log_message "INFO" "Starting cleanup for empty directories..."
    local dirs_to_check
    dirs_to_check=$(echo "$moved_files_list" | xargs -n1 dirname | sort -u | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)
    
    while IFS= read -r dir_path; do
        if [[ "$dir_path" == "$share_root" ]]; then continue; fi
        if [[ "$dir_path" != "$share_root"* ]]; then continue; fi

        if [[ -d "$dir_path" ]]; then
            rmdir "$dir_path" 2>/dev/null
            if [[ ! -d "$dir_path" ]]; then
                log_message "INFO" "  -> Removed empty dir: $dir_path"
            fi
        fi
    done <<< "$dirs_to_check"
}

process_share() {
    local name="$1"
    local path="$2"
    local min_age="$3"
    local excludes="$4"
    
    log_message "INFO" "Processing Share: [$name]"
    
    if [[ ! -d "$path" ]]; then
        log_message "WARN" "  -> Path does not exist: $path (Skipping)"
        return
    fi

    # 1. Prepare Excludes
    rm -f "$TEMP_EXCLUDE_FILE"
    touch "$TEMP_EXCLUDE_FILE"

    if [[ "$FORCE_ALL" == false ]]; then
        add_to_temp() {
            local list="$1"
            IFS=',' read -ra ADDR <<< "$list"
            for f in "${ADDR[@]}"; do
                [[ -f "$f" ]] && cat "$f" >> "$TEMP_EXCLUDE_FILE"
            done
        }
        add_to_temp "$GLOBAL_EXCLUDES"
        add_to_temp "$excludes"
    fi

    # 2. Determine Age (Converted to Minutes)
    local effective_age_days
    effective_age_days="${min_age:-$GLOBAL_MIN_AGE}"
    
    local find_args=""
    
    if [[ "$FORCE_AGE" == true ]]; then
        log_message "WARN" "  -> FORCE enabled: Ignoring min_age ($effective_age_days days)"
    else
        if [[ "$effective_age_days" -gt 0 ]]; then
            # Convert Days to Minutes for precision (Find logic: +1 day means >48h, so we use minutes)
            local min_minutes=$((effective_age_days * 1440))
            find_args="-cmin +$min_minutes"
            log_message "INFO" "  -> Filter: Files older than $effective_age_days days (> $min_minutes minutes CTIME)"
        else
            log_message "INFO" "  -> Filter: Immediate move (0 days)"
        fi
    fi

    # 3. Build Find Command
    local find_cmd="find \"$path\" -depth -type f $find_args"

    # 4. Execute Search
    local candidates
    candidates=$(eval "$find_cmd")

    if [[ -z "$candidates" ]]; then
        log_message "INFO" "  -> No files found matching age criteria."
        return
    fi

    # 5. Apply Excludes
    local final_list=""
    if [[ -s "$TEMP_EXCLUDE_FILE" ]]; then
        final_list=$(echo "$candidates" | grep -v -F -f "$TEMP_EXCLUDE_FILE")
    else
        final_list="$candidates"
    fi

    if [[ -z "$final_list" ]]; then
        log_message "INFO" "  -> No files left after exclude filtering."
        return
    fi

    # 6. Execute Mover
    local count
    count=$(echo "$final_list" | wc -l)
    
    if [[ "$DRY_RUN" == true ]]; then
        log_message "INFO" "  -> [DRY-RUN] Would move $count files:"
        echo "$final_list" | sed 's/^/     /'
    else
        log_message "INFO" "  -> Moving $count files..."
        
        echo "$final_list" | "$MOVER_BIN"
        
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            log_message "INFO" "  -> Move successful."
            run_cleanup "$final_list" "$path"
        else
            log_message "ERROR" "  -> Mover binary returned error code $exit_code"
        fi
    fi
}

# --- MAIN EXECUTION ---
rotate_logs
log_message "INFO" "=== Starting Smart Mover ==="

if [[ "$DRY_RUN" == true ]]; then
    log_message "WARN" "RUN MODE: DRY-RUN (Simulation only. Use --run to execute)"
else
    log_message "INFO" "RUN MODE: LIVE (Executing moves)"
fi

[[ -n "$TARGET_SHARES" ]] && log_message "INFO" "FILTER: Processing only shares: $TARGET_SHARES"

current_section=""
section_path=""
section_age=""
section_excludes=""

while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)

    [[ $key =~ ^#.* ]] && continue
    [[ -z $key ]] && continue

    if [[ $key =~ ^\[(.*)\]$ ]]; then
        if [[ -n "$current_section" ]] && [[ "$current_section" != "GLOBAL" ]]; then
            should_run=true
            if [[ -n "$TARGET_SHARES" ]]; then
                if [[ ",$TARGET_SHARES," != *",$current_section,"* ]]; then
                    should_run=false
                fi
            fi
            if [[ "$should_run" == true ]]; then
                process_share "$current_section" "$section_path" "$section_age" "$section_excludes"
            fi
        fi

        current_section="${BASH_REMATCH[1]}"
        section_path=""
        section_age=""
        section_excludes=""
    else
        case "$key" in
            path)     section_path="$value" ;;
            min_age)  section_age="$value" ;;
            excludes) section_excludes="$value" ;;
        esac
    fi
done < "$INI_FILE"

if [[ -n "$current_section" ]] && [[ "$current_section" != "GLOBAL" ]]; then
    should_run=true
    if [[ -n "$TARGET_SHARES" ]]; then
        if [[ ",$TARGET_SHARES," != *",$current_section,"* ]]; then
            should_run=false
        fi
    fi
    if [[ "$should_run" == true ]]; then
        process_share "$current_section" "$section_path" "$section_age" "$section_excludes"
    fi
fi

rm -f "$TEMP_EXCLUDE_FILE"
log_message "INFO" "=== Finished ==="
