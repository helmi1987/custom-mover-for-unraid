#!/bin/bash
# ==============================================================================
# Smart Mover Setup V3.0
# Fixes: Stdout/Stderr Trennung für saubere INI, Log-Pfad Abfrage
# ==============================================================================

INI_FILE="smart_mover.ini"
TEMP_INI="${INI_FILE}.tmp"

# Farben
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Header
clear
echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}   Smart Mover - Configuration Setup V3       ${NC}"
echo -e "${BLUE}==============================================${NC}"

# Hilfsfunktion: Wert aus INI lesen
get_ini_value() {
    local section="$1"
    local key="$2"
    if [[ -f "$INI_FILE" ]]; then
        sed -n "/^\[$section\]/,/^\[/p" "$INI_FILE" | grep "^$key=" | cut -d'=' -f2-
    fi
}

# Hilfsfunktion: Excludes abfragen (FIX: Prompts auf >&2)
ask_for_files() {
    local prompt_text="$1"
    local collected_files=""
    
    # WICHTIG: Ausgabe auf >&2 (Stderr), damit sie NICHT in der Variable landet
    echo -e "${YELLOW}$prompt_text${NC}" >&2
    echo -e "   (Nutze TAB für Auto-Complete. Leere Eingabe = Fertig)" >&2
    
    while true; do
        # read -p schreibt standardmäßig auf stderr bei interaktiven Shells, 
        # aber wir erzwingen hier saubere Trennung.
        read -e -p "   > Pfad: " input_file
        
        # Abbruch bei leerer Eingabe
        if [[ -z "$input_file" ]]; then
            break
        fi

        # Pfad bereinigen
        if [[ -f "$input_file" ]]; then
            real_path=$(realpath "$input_file")
        else
            real_path="$input_file"
            echo -e "     ${RED}Hinweis: Datei existiert noch nicht.${NC}" >&2
        fi

        if [[ -z "$collected_files" ]]; then
            collected_files="$real_path"
        else
            collected_files="$collected_files,$real_path"
        fi
    done
    
    # NUR das Ergebnis auf Stdout ausgeben (für die Variable)
    echo "$collected_files"
}

# Start der neuen INI
echo "# Smart Mover Configuration" > "$TEMP_INI"

# ------------------------------------------------------------------------------
# 1. SYSTEM & GLOBAL
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[1] System Konfiguration${NC}"

# Mover Binary
if [[ -x "/usr/libexec/unraid/move" ]]; then
    MOVER_BIN="/usr/libexec/unraid/move"
elif [[ -x "/usr/local/bin/move" ]]; then
    MOVER_BIN="/usr/local/bin/move"
else
    echo -e "${RED}FEHLER: Mover Binary nicht gefunden!${NC}"
    rm "$TEMP_INI"
    exit 1
fi
echo -e "   Mover Binary: ${GREEN}$MOVER_BIN${NC}"

# Log File (NEU)
OLD_LOG=$(get_ini_value "GLOBAL" "log_file")
DEFAULT_LOG="/mnt/user/system/scripts/smart_mover.log"
[[ -n "$OLD_LOG" ]] && DEFAULT_LOG="$OLD_LOG"

echo -e "\n   Wo soll das Log gespeichert werden?"
read -e -i "$DEFAULT_LOG" -p "   > Logfile Pfad: " FINAL_LOG

# Global Excludes
echo -e "\n${BLUE}[2] Globale Excludes${NC}"
OLD_GLOBAL=$(get_ini_value "GLOBAL" "global_excludes")

# Fix: Falls alter Wert "kaputt" war (durch den Prompt-Text Fehler), ignorieren
if [[ "$OLD_GLOBAL" == *"Füge Globale"* ]]; then OLD_GLOBAL=""; fi

echo -e "   Globale Excludes gelten für ALLE Shares."
if [[ -n "$OLD_GLOBAL" ]]; then
    echo -e "   Aktuell: $OLD_GLOBAL"
    read -p "   Neu definieren? [j/N]: " -n 1 -r CHOICE
    echo ""
else
    CHOICE="j"
fi

GLOBAL_EXCLUDES="$OLD_GLOBAL"
if [[ "$CHOICE" =~ ^[Jj]$ ]]; then
    # Hier wird die Funktion aufgerufen und nur der Pfad gespeichert
    GLOBAL_EXCLUDES=$(ask_for_files "Bitte Globale Exclude-Dateien angeben:")
fi

# INI Schreiben (Global)
echo "[GLOBAL]" >> "$TEMP_INI"
echo "mover_bin=$MOVER_BIN" >> "$TEMP_INI"
echo "log_file=$FINAL_LOG" >> "$TEMP_INI"
echo "global_excludes=$GLOBAL_EXCLUDES" >> "$TEMP_INI"
echo "" >> "$TEMP_INI"

# ------------------------------------------------------------------------------
# 2. SHARES (Loop)
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3] Share Konfiguration${NC}"

# Cache Root (für Auto-Guessing)
CACHE_ROOT_GUESS="/mnt/cache"
if [[ -f "/var/local/emhttp/disks.ini" ]]; then
    TMP_CACHE=$(grep -Po 'fsMountPoint="\K[^"]+' "/var/local/emhttp/disks.ini" 2>/dev/null | grep "cache" | head -n 1)
    [[ -n "$TMP_CACHE" ]] && CACHE_ROOT_GUESS="$TMP_CACHE"
fi

for config_file in /boot/config/shares/*.cfg; do
    SHARE_NAME=$(basename "$config_file" .cfg)
    
    # Prüfe Cache Nutzung
    if grep -qE 'shareUseCache="(yes|prefer)"' "$config_file"; then
        
        # Check ob Eintrag schon existiert
        OLD_PATH=$(get_ini_value "$SHARE_NAME" "path")
        
        echo -e "\n----------------------------------------------"
        if [[ -n "$OLD_PATH" ]]; then
            # Existierender Eintrag
            echo -e "Share ${GREEN}[$SHARE_NAME]${NC} ist konfiguriert."
            echo -e "Optionen: [B]ehalten | [N]eu | [L]öschen"
            read -p "   Auswahl [B/n/l]: " -n 1 -r ACTION
            echo ""
            
            case "$ACTION" in
                [Ll]* )
                    echo -e "   ${RED}-> Share '$SHARE_NAME' entfernt.${NC}"
                    continue ;;
                [Nn]* )
                    # Neu konfigurieren
                    DO_CONFIG=true ;;
                * )
                    # Behalten (Werte kopieren)
                    OLD_EXC=$(get_ini_value "$SHARE_NAME" "excludes")
                    [[ "$OLD_EXC" == *"Füge spezifische"* ]] && OLD_EXC="" # Fix für kaputte alte INI

                    echo "[$SHARE_NAME]" >> "$TEMP_INI"
                    echo "path=$OLD_PATH" >> "$TEMP_INI"
                    echo "excludes=$OLD_EXC" >> "$TEMP_INI"
                    echo "" >> "$TEMP_INI"
                    continue ;;
            esac
        else
            # Neuer Share
            echo -e "Neuer Cache-Share gefunden: ${BLUE}[$SHARE_NAME]${NC}"
            read -p "   Konfigurieren? [j/N]: " -n 1 -r ADD_NEW
            echo ""
            if [[ "$ADD_NEW" =~ ^[Jj]$ ]]; then DO_CONFIG=true; else DO_CONFIG=false; fi
        fi

        if [ "$DO_CONFIG" = true ]; then
            # Pfad vorschlagen
            SUGGESTED_PATH="${CACHE_ROOT_GUESS}/${SHARE_NAME}"
            read -e -i "$SUGGESTED_PATH" -p "   Cache Pfad: " SHARE_CACHE_PATH
            
            # Excludes abfragen
            SHARE_EXCLUDES=$(ask_for_files "Exclude-Dateien für '$SHARE_NAME':")
            
            # Schreiben
            echo "[$SHARE_NAME]" >> "$TEMP_INI"
            echo "path=$SHARE_CACHE_PATH" >> "$TEMP_INI"
            echo "excludes=$SHARE_EXCLUDES" >> "$TEMP_INI"
            echo "" >> "$TEMP_INI"
            echo -e "   ${GREEN}-> Gespeichert.${NC}"
        fi
    fi
done

# Abschluss
mv "$TEMP_INI" "$INI_FILE"
echo -e "\n${BLUE}==============================================${NC}"
echo -e "${GREEN}Konfiguration erfolgreich gespeichert: $INI_FILE${NC}"
