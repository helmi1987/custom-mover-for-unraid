#!/bin/bash
# ==============================================================================
# Smart Mover Executor V1.0
# Logik: Find -> Filter (Global+Share) -> Pipe to Mover -> Smart Cleanup
# Usage: ./custommover_run.sh [--run]
# ==============================================================================

# ------------------------------------------------------------------------------
# KONFIGURATION & SETUP
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INI_FILE="$SCRIPT_DIR/smart_mover.ini"
DRY_RUN=true

# Farben
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check Arguments
for arg in "$@"; do
    if [[ "$arg" == "--run" ]]; then
        DRY_RUN=false
    fi
done

# Check INI
if [[ ! -f "$INI_FILE" ]]; then
    echo -e "${RED}Fehler: $INI_FILE nicht gefunden. Bitte erst setup.sh ausführen.${NC}"
    exit 1
fi

# Hilfsfunktion: Wert aus INI lesen
get_ini_value() {
    local section="$1"
    local key="$2"
    sed -n "/^\[$section\]/,/^\[/p" "$INI_FILE" | grep "^$key=" | cut -d'=' -f2-
}

# Globale Config laden
MOVER_BIN=$(get_ini_value "GLOBAL" "mover_bin")
LOG_FILE=$(get_ini_value "GLOBAL" "log_file")
GLOBAL_EXCLUDES_RAW=$(get_ini_value "GLOBAL" "global_excludes")

# Log Verzeichnis erstellen
mkdir -p "$(dirname "$LOG_FILE")"

# Log Rotation (altes Log umbenennen)
if [[ -f "$LOG_FILE" ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi

# Logging Funktion (Konsole + Datei)
log() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "$msg"
    # Farben entfernen für Logfile
    echo "[$timestamp] $(echo -e "$msg" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# START
# ------------------------------------------------------------------------------
if $DRY_RUN; then
    log "${YELLOW}=== SMART MOVER GESTARTET (DRY-RUN) ===${NC}"
    log "Nutze --run für scharfen Modus."
else
    log "${GREEN}=== SMART MOVER GESTARTET (LIVE MODE) ===${NC}"
fi

# Mover Binary Check
if [[ ! -x "$MOVER_BIN" ]]; then
    log "${RED}CRITICAL: Mover Binary nicht gefunden unter $MOVER_BIN${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# SHARE LOOP
# ------------------------------------------------------------------------------
# Alle Sections finden, die nicht GLOBAL sind
grep "^\[" "$INI_FILE" | grep -v "\[GLOBAL\]" | tr -d '[]' | while read -r SHARE_NAME; do
    
    SHARE_PATH=$(get_ini_value "$SHARE_NAME" "path")
    SHARE_EXCLUDES_RAW=$(get_ini_value "$SHARE_NAME" "excludes")

    if [[ ! -d "$SHARE_PATH" ]]; then
        log "${YELLOW}Skip: Pfad für [$SHARE_NAME] existiert nicht ($SHARE_PATH)${NC}"
        continue
    fi

    log "\n${BLUE}Verarbeite Share: [$SHARE_NAME] ($SHARE_PATH)${NC}"

    # -------------------------------------------------
    # 1. EXCLUDE LISTEN ZUSAMMENBAUEN
    # -------------------------------------------------
    # Wir erstellen ein temporäres Pattern-File für grep
    EXCLUDE_PATTERN_FILE=$(mktemp)
    
    # Globale Excludes hinzufügen
    IFS=',' read -ra ADDR <<< "$GLOBAL_EXCLUDES_RAW"
    for ex_file in "${ADDR[@]}"; do
        if [[ -f "$ex_file" ]]; then
            cat "$ex_file" >> "$EXCLUDE_PATTERN_FILE"
            # Sicherstellen dass am Ende ein Newline ist
            echo "" >> "$EXCLUDE_PATTERN_FILE"
        fi
    done

    # Share Excludes hinzufügen
    IFS=',' read -ra ADDR <<< "$SHARE_EXCLUDES_RAW"
    for ex_file in "${ADDR[@]}"; do
        if [[ -f "$ex_file" ]]; then
            cat "$ex_file" >> "$EXCLUDE_PATTERN_FILE"
            echo "" >> "$EXCLUDE_PATTERN_FILE"
        fi
    done

    # Leere Zeilen aus Pattern File entfernen
    sed -i '/^$/d' "$EXCLUDE_PATTERN_FILE"

    # -------------------------------------------------
    # 2. DATEIEN FINDEN & FILTERN
    # -------------------------------------------------
    # Array für Move-Kandidaten
    FILES_TO_MOVE=()
    
    # Find Logik:
    # 1. find: Suche alle Dateien
    # 2. grep -v -F -f: Exclude (Fixed String Match aus Pattern File)
    #    -F ist wichtig, damit Punkte im Dateinamen nicht als Regex interpretiert werden!
    #    Wenn Pattern File leer ist, grept er nichts weg (korrekt).
    
    if [[ -s "$EXCLUDE_PATTERN_FILE" ]]; then
        # Mit Exclude Filter
        while IFS= read -r file; do
            FILES_TO_MOVE+=("$file")
        done < <(find "$SHARE_PATH" -type f | grep -v -F -f "$EXCLUDE_PATTERN_FILE")
    else
        # Keine Excludes definiert -> Alles nehmen
        while IFS= read -r file; do
            FILES_TO_MOVE+=("$file")
        done < <(find "$SHARE_PATH" -type f)
    fi

    rm "$EXCLUDE_PATTERN_FILE"
    
    COUNT=${#FILES_TO_MOVE[@]}
    
    if [[ $COUNT -eq 0 ]]; then
        log "   -> Keine Dateien zum Verschieben gefunden (oder alles excluded)."
        continue
    fi

    log "   -> Gefunden: $COUNT Dateien zum Verschieben."

    # -------------------------------------------------
    # 3. MOVER EXECUTION (PIPE)
    # -------------------------------------------------
    
    # Dateiliste als String vorbereiten (für Log & Pipe)
    MOVE_LIST_STRING=""
    for f in "${FILES_TO_MOVE[@]}"; do
        MOVE_LIST_STRING+="$f"$'\n'
        # Im Dryrun detailliert loggen, im Live nur Summary (sonst Logspam bei 10k Files)
        if $DRY_RUN; then log "      [PLAN] $f"; fi
    done

    if ! $DRY_RUN; then
        log "   -> Starte Mover Pipe..."
        
        # Die Magie: String in STDIN der Binary pipen
        echo -n "$MOVE_LIST_STRING" | "$MOVER_BIN"
        
        MOVER_EXIT=$?
        if [[ $MOVER_EXIT -eq 0 ]]; then
            log "   ${GREEN}-> Mover erfolgreich beendet.${NC}"
            
            # -------------------------------------------------
            # 4. SMART CLEANUP (Nur bei Erfolg)
            # -------------------------------------------------
            log "   -> Starte Smart Cleanup..."
            
            # Wir extrahieren die Verzeichnisse der bewegten Dateien
            # sort -u = Unique, sort -r = Reverse (tiefste zuerst)
            DIRS_TO_CLEAN=$(echo "$MOVE_LIST_STRING" | xargs -I {} dirname "{}" | sort -u | sort -r)
            
            # Cache Cleanup
            echo "$DIRS_TO_CLEAN" | while read -r dir; do
                [[ -z "$dir" ]] && continue
                
                # Prüfen ob leer
                if [[ -d "$dir" && -z "$(ls -A "$dir")" ]]; then
                    # Schutz-Check: Ist dies der Share Root?
                    # Wir prüfen ob der Ordnername dem Share-Namen entspricht (einfachster Check)
                    BASE_NAME=$(basename "$dir")
                    if [[ "$BASE_NAME" == "$SHARE_NAME" ]]; then
                        log "      [SKIP] Root Protection: $dir"
                        continue
                    fi

                    # Löschen
                    rmdir "$dir" 2>/dev/null
                    if [[ ! -d "$dir" ]]; then
                        log "      [CLEAN] Cache Ordner gelöscht: $dir"
                    fi
                fi
            done
            
            # Array Cleanup (Optional, falls auf Array leere Ordner entstehen - meist nicht nötig beim Mover Cache->Array, 
            # aber falls Pfade angeglichen werden sollen).
            # Hier implementieren wir nur den Cache Cleanup wie angefordert, um Mover-Reste zu entfernen.

        else
            log "${RED}   -> FEHLER beim Mover (Exit Code $MOVER_EXIT)${NC}"
        fi
    else
        log "   -> [DRY-RUN] Keine Aktionen durchgeführt."
    fi

done

log "\n${GREEN}=== FERTIG ===${NC}"
