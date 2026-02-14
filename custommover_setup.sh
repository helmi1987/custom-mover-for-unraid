#!/bin/bash
# ==============================================================================
# Smart Mover Setup V5.0
# Language: English
# Features: Unraid 7 detection, Multi-Pool, Smart Min-Age Fallback
# ==============================================================================

INI_FILE="smart_mover.ini"
TEMP_INI="${INI_FILE}.tmp"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Header
clear
echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}   Smart Mover - Configuration Setup          ${NC}"
echo -e "${BLUE}==============================================${NC}"

# Helper: Read value from INI
get_ini_value() {
    local section="$1"
    local key="$2"
    if [[ -f "$INI_FILE" ]]; then
        sed -n "/^\[$section\]/,/^\[/p" "$INI_FILE" | grep "^$key=" | cut -d'=' -f2-
    fi
}

# Helper: Ask for file paths (Output on Stderr to keep variable clean)
ask_for_files() {
    local prompt_text="$1"
    local collected_files=""
    
    echo -e "${YELLOW}$prompt_text${NC}" >&2
    echo -e "   (Use TAB for Auto-Complete. Leave empty to finish)" >&2
    
    while true; do
        read -e -p "   > Path: " input_file
        
        # Stop on empty input
        if [[ -z "$input_file" ]]; then
            break
        fi

        # Clean path
        if [[ -f "$input_file" ]]; then
            real_path=$(realpath "$input_file")
        else
            real_path="$input_file"
            # Just a warning, accept it anyway
             echo -e "     ${YELLOW}Note: File does not exist yet.${NC}" >&2
        fi

        if [[ -z "$collected_files" ]]; then
            collected_files="$real_path"
        else
            collected_files="$collected_files,$real_path"
        fi
    done
    
    # Echo result to Stdout for variable assignment
    echo "$collected_files"
}

# Start new INI
echo "# Smart Mover Configuration" > "$TEMP_INI"

# ------------------------------------------------------------------------------
# 1. SYSTEM & GLOBAL
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[1] System Configuration${NC}"

# Mover Binary (Unraid 7 vs 6)
if [[ -x "/usr/libexec/unraid/move" ]]; then
    MOVER_BIN="/usr/libexec/unraid/move"
elif [[ -x "/usr/local/bin/move" ]]; then
    MOVER_BIN="/usr/local/bin/move"
else
    echo -e "${RED}ERROR: Mover Binary not found!${NC}"
    rm "$TEMP_INI"
    exit 1
fi
echo -e "   Mover Binary: ${GREEN}$MOVER_BIN${NC}"

# Log File
OLD_LOG=$(get_ini_value "GLOBAL" "log_file")
DEFAULT_LOG="/mnt/user/system/scripts/smart_mover.log"
[[ -n "$OLD_LOG" ]] && DEFAULT_LOG="$OLD_LOG"

echo -e "\n   Where should logs be stored?"
read -e -i "$DEFAULT_LOG" -p "   > Logfile Path: " FINAL_LOG

# Global Min Age
OLD_AGE=$(get_ini_value "GLOBAL" "min_age")
DEFAULT_AGE="${OLD_AGE:-0}"

echo -e "\n   Global Minimum Age (Days)?"
echo -e "   (0 = Immediate move. Can be overridden per share)"
read -e -i "$DEFAULT_AGE" -p "   > Days: " GLOBAL_MIN_AGE

# Global Excludes
echo -e "\n${BLUE}[2] Global Excludes${NC}"
OLD_GLOBAL=$(get_ini_value "GLOBAL" "global_excludes")

echo -e "   Global excludes apply to ALL shares."
CHOICE="y"
if [[ -n "$OLD_GLOBAL" ]]; then
    echo -e "   Current: $OLD_GLOBAL"
    read -p "   Redefine? [y/N]: " -n 1 -r REPLY_EXC
    echo ""
    [[ ! $REPLY_EXC =~ ^[Yy]$ ]] && CHOICE="n"
fi

GLOBAL_EXCLUDES="$OLD_GLOBAL"
if [[ "$CHOICE" =~ ^[Yy]$ ]]; then
    GLOBAL_EXCLUDES=$(ask_for_files "Please specify Global Exclude files:")
fi

# Write Global Section
echo "[GLOBAL]" >> "$TEMP_INI"
echo "mover_bin=$MOVER_BIN" >> "$TEMP_INI"
echo "log_file=$FINAL_LOG" >> "$TEMP_INI"
echo "min_age=$GLOBAL_MIN_AGE" >> "$TEMP_INI"
echo "global_excludes=$GLOBAL_EXCLUDES" >> "$TEMP_INI"
echo "" >> "$TEMP_INI"

# ------------------------------------------------------------------------------
# 2. SHARES (Loop)
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3] Share Configuration${NC}"

for config_file in /boot/config/shares/*.cfg; do
    SHARE_NAME=$(basename "$config_file" .cfg)
    
    # Check if Cache is used
    if grep -qE 'shareUseCache="(yes|prefer)"' "$config_file"; then
        
        # Check if already configured
        OLD_PATH=$(get_ini_value "$SHARE_NAME" "path")
        
        # Multi-Pool Detection
        POOL_NAME=$(grep 'shareCachePool=' "$config_file" | cut -d'"' -f2)
        [[ -z "$POOL_NAME" ]] && POOL_NAME="cache"
        
        echo -e "\n----------------------------------------------"
        if [[ -n "$OLD_PATH" ]]; then
            # Existing Entry
            echo -e "Share ${GREEN}[$SHARE_NAME]${NC} is configured."
            echo -e "Options: [K]eep | [E]dit | [D]elete"
            read -p "   Choice [K/e/d]: " -n 1 -r ACTION
            echo ""
            
            case "$ACTION" in
                [Dd]* )
                    echo -e "   ${RED}-> Share '$SHARE_NAME' removed.${NC}"
                    continue ;;
                [Ee]* )
                    DO_CONFIG=true ;;
                * )
                    # Keep (Copy values exactly)
                    OLD_EXC=$(get_ini_value "$SHARE_NAME" "excludes")
                    OLD_S_AGE=$(get_ini_value "$SHARE_NAME" "min_age")
                    
                    echo "[$SHARE_NAME]" >> "$TEMP_INI"
                    echo "path=$OLD_PATH" >> "$TEMP_INI"
                    # Only write age if it was set
                    [[ -n "$OLD_S_AGE" ]] && echo "min_age=$OLD_S_AGE" >> "$TEMP_INI"
                    echo "excludes=$OLD_EXC" >> "$TEMP_INI"
                    echo "" >> "$TEMP_INI"
                    continue ;;
            esac
        else
            # New Share
            echo -e "New Cache-Share found: ${BLUE}[$SHARE_NAME]${NC} (Pool: $POOL_NAME)"
            read -p "   Configure? [y/N]: " -n 1 -r ADD_NEW
            echo ""
            if [[ "$ADD_NEW" =~ ^[Yy]$ ]]; then DO_CONFIG=true; else DO_CONFIG=false; fi
        fi

        if [ "$DO_CONFIG" = true ]; then
            # 1. Path Suggestion
            SUGGESTED_PATH="/mnt/${POOL_NAME}/${SHARE_NAME}"
            read -e -i "$SUGGESTED_PATH" -p "   Cache Path: " SHARE_CACHE_PATH
            
            # 2. Min Age (Smart Logic)
            echo -e "   Minimum Age for this share?"
            echo -e "   (Leave EMPTY to use Global Default: $GLOBAL_MIN_AGE days)"
            
            # Get old value for suggestion, but don't force it
            OLD_S_AGE=$(get_ini_value "$SHARE_NAME" "min_age")
            read -e -i "$OLD_S_AGE" -p "   > Days: " SHARE_AGE
            
            # 3. Excludes
            SHARE_EXCLUDES=$(ask_for_files "Exclude files for '$SHARE_NAME':")
            
            # Write to INI
            echo "[$SHARE_NAME]" >> "$TEMP_INI"
            echo "path=$SHARE_CACHE_PATH" >> "$TEMP_INI"
            
            # LOGIC: Only write min_age if user entered something
            if [[ -n "$SHARE_AGE" ]]; then
                echo "min_age=$SHARE_AGE" >> "$TEMP_INI"
            fi
            
            echo "excludes=$SHARE_EXCLUDES" >> "$TEMP_INI"
            echo "" >> "$TEMP_INI"
            echo -e "   ${GREEN}-> Saved.${NC}"
        fi
    fi
done

# Finalize
mv "$TEMP_INI" "$INI_FILE"
echo -e "\n${BLUE}==============================================${NC}"
echo -e "${GREEN}Configuration successfully saved: $INI_FILE${NC}"
