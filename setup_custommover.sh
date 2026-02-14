#!/bin/bash
# ==============================================================================
# Script: setup.sh (V6.2 Dynamic & Informative)
# Description: Configures Global settings & Share Overrides.
#              FIX: Shows current values before asking to Keep/Edit/Delete.
# ==============================================================================

INI_FILE="smart_mover.ini"
TEMP_INI="${INI_FILE}.tmp"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}   Smart Mover - Dynamic Setup V6.2           ${NC}"
echo -e "${BLUE}==============================================${NC}"
echo -e "   This setup only configures GLOBAL settings and"
echo -e "   OPTIONAL overrides. Paths are detected automatically."
echo -e "${BLUE}==============================================${NC}"

# --- HELPER FUNCTIONS ---
get_ini_value() {
    local section="$1"
    local key="$2"
    if [[ -f "$INI_FILE" ]]; then
        sed -n "/^\[$section\]/,/^\[/p" "$INI_FILE" | grep "^$key=" | cut -d'=' -f2-
    fi
}

ask_for_files() {
    local prompt_text="$1"
    local current_list="$2"
    local collected_files=""

    echo -e "${YELLOW}$prompt_text${NC}" >&2
    
    # 1. Handle Existing List
    if [[ -n "$current_list" ]]; then
        echo -e "   Current: ${CYAN}$current_list${NC}" >&2
        read -p "   Keep these? [Y/n (clear)]: " -n 1 -r response >&2
        echo "" >&2
        if [[ $response =~ ^[Nn]$ ]]; then
            collected_files=""
            echo -e "   -> List cleared." >&2
        else
            collected_files="$current_list"
        fi
    fi

    # 2. Add New Files
    echo -e "   (TAB for Auto-Complete. Empty to finish)" >&2
    while true; do
        read -e -p "   > Add Path: " input_file
        
        if [[ -z "$input_file" ]]; then break; fi
        
        if [[ -f "$input_file" ]]; then 
            real_path=$(realpath "$input_file")
        else 
            real_path="$input_file"
        fi

        if [[ -z "$collected_files" ]]; then 
            collected_files="$real_path"
        else 
            collected_files="$collected_files,$real_path"
        fi
    done
    echo "$collected_files"
}

# --- START INI ---
echo "# Smart Mover Configuration (Dynamic Mode)" > "$TEMP_INI"

# --- 1. GLOBAL SETTINGS ---
echo -e "\n${BLUE}[1] Global Settings${NC}"

# Mover Binary
if [[ -x "/usr/libexec/unraid/move" ]]; then MOVER_BIN="/usr/libexec/unraid/move";
elif [[ -x "/usr/local/bin/move" ]]; then MOVER_BIN="/usr/local/bin/move";
else echo -e "${RED}Error: Mover binary not found!${NC}"; rm "$TEMP_INI"; exit 1; fi
echo -e "   Mover Binary: ${GREEN}$MOVER_BIN${NC}"

# Log Path
OLD_LOG=$(get_ini_value "GLOBAL" "log_file")
DEF_LOG="${OLD_LOG:-/mnt/user/system/scripts/smart_mover.log}"
read -e -i "$DEF_LOG" -p "   Logfile Path: " FINAL_LOG

# Global Age
OLD_AGE=$(get_ini_value "GLOBAL" "min_age")
DEF_AGE="${OLD_AGE:-0}"
read -e -i "$DEF_AGE" -p "   Global Min Age (Days): " GLOBAL_MIN_AGE

# Global Excludes
OLD_EXC=$(get_ini_value "GLOBAL" "global_excludes")
echo -e "   Global Excludes (apply to ALL shares):"
GLOBAL_EXCLUDES=$(ask_for_files "Files:" "$OLD_EXC")

echo "[GLOBAL]" >> "$TEMP_INI"
echo "mover_bin=$MOVER_BIN" >> "$TEMP_INI"
echo "log_file=$FINAL_LOG" >> "$TEMP_INI"
echo "min_age=$GLOBAL_MIN_AGE" >> "$TEMP_INI"
echo "global_excludes=$GLOBAL_EXCLUDES" >> "$TEMP_INI"
echo "" >> "$TEMP_INI"


# --- 2. SHARE OVERRIDES ---
echo -e "\n${BLUE}[2] Share Overrides (Optional)${NC}"
echo -e "   Only configure shares that need DIFFERENT settings than Global."

for config_file in /boot/config/shares/*.cfg; do
    SHARE_NAME=$(basename "$config_file" .cfg)
    
    # Check if Cache is used
    if grep -qE 'shareUseCache="(yes|prefer)"' "$config_file"; then
        
        # Check if Override exists in INI
        OLD_S_AGE=$(get_ini_value "$SHARE_NAME" "min_age")
        OLD_S_EXC=$(get_ini_value "$SHARE_NAME" "excludes")
        
        HAS_OVERRIDE=false
        [[ -n "$OLD_S_AGE" || -n "$OLD_S_EXC" ]] && HAS_OVERRIDE=true
        
        echo -e "\n----------------------------------------------"
        if [[ "$HAS_OVERRIDE" == true ]]; then
            echo -e "Share ${GREEN}[$SHARE_NAME]${NC} has custom settings."
            
            # --- NEU: INFO ANZEIGE ---
            # Zeigt die aktuellen Werte an, bevor gefragt wird
            DISPLAY_AGE="${OLD_S_AGE:-Default ($GLOBAL_MIN_AGE)}"
            
            echo -e "   Current Age:      ${CYAN}$DISPLAY_AGE${NC} days"
            if [[ -n "$OLD_S_EXC" ]]; then
                echo -e "   Current Excludes: ${CYAN}$OLD_S_EXC${NC}"
            else
                echo -e "   Current Excludes: ${CYAN}None${NC}"
            fi
            # -------------------------

            echo -e "Options: [K]eep | [E]dit | [D]elete (Revert to Global)"
            read -p "   Choice [K/e/d]: " -n 1 -r ACTION; echo ""
            
            case "$ACTION" in
                [Dd]*) 
                    echo -e "   -> Reverted to Global defaults."
                    continue ;; 
                [Ee]*) DO_CONFIG=true ;;
                *) # Keep
                   echo "[$SHARE_NAME]" >> "$TEMP_INI"
                   [[ -n "$OLD_S_AGE" ]] && echo "min_age=$OLD_S_AGE" >> "$TEMP_INI"
                   [[ -n "$OLD_S_EXC" ]] && echo "excludes=$OLD_S_EXC" >> "$TEMP_INI"
                   echo "" >> "$TEMP_INI"
                   continue ;; 
            esac
        else
            echo -e "Share ${BLUE}[$SHARE_NAME]${NC} uses Global defaults."
            read -p "   Create custom rule? [y/N]: " -n 1 -r ADD_NEW; echo ""
            if [[ "$ADD_NEW" =~ ^[Yy]$ ]]; then DO_CONFIG=true; else DO_CONFIG=false; fi
        fi

        if [[ "$DO_CONFIG" == true ]]; then
            echo -e "   Defining Override for '$SHARE_NAME':"
            
            # Min Age
            DEF_S_AGE="${OLD_S_AGE:-$GLOBAL_MIN_AGE}"
            read -e -i "$DEF_S_AGE" -p "   Custom Min Age (Empty = Global): " SHARE_AGE
            
            # Excludes
            SHARE_EXCLUDES=$(ask_for_files "   Custom Exclude files:" "$OLD_S_EXC")
            
            # Write Section (NO PATH!)
            echo "[$SHARE_NAME]" >> "$TEMP_INI"
            [[ -n "$SHARE_AGE" ]] && echo "min_age=$SHARE_AGE" >> "$TEMP_INI"
            [[ -n "$SHARE_EXCLUDES" ]] && echo "excludes=$SHARE_EXCLUDES" >> "$TEMP_INI"
            echo "" >> "$TEMP_INI"
            echo -e "   ${GREEN}-> Override saved.${NC}"
        fi
    fi
done

mv "$TEMP_INI" "$INI_FILE"
echo -e "\n${BLUE}==============================================${NC}"
echo -e "${GREEN}Configuration saved!${NC}"
