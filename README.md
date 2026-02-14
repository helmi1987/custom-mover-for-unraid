# Smart Mover für Unraid

Ein intelligenter, konfigurierbarer Wrapper für den Unraid Mover. Er ermöglicht selektives Verschieben von Dateien vom Cache zum Array basierend auf Dateialter, Pfaden und Ausschlusskriterien (Excludes).

## Funktionen

*   **Selektives Verschieben:** Nutzt Exclude-Listen (Global & Pro Share), um bestimmte Dateien dauerhaft auf dem Cache zu halten.
*   **Age-Based Moving:** Verschiebt Dateien erst, wenn sie ein bestimmtes Alter (z.B. 14 Tage) erreicht haben.
*   **Smart Cleanup:** Bereinigt leere Verzeichnisse nach dem Verschieben, schützt aber Root-Ordner.
*   **Unraid Native:** Nutzt im Hintergrund die offizielle Mover-Binary für maximale Kompatibilität.
*   **Dry-Run Safe:** Führt standardmäßig keine Aktionen aus, solange nicht explizit bestätigt.

## Konfiguration (ini)

Die Datei `smart_mover.ini` steuert das Verhalten. Sie wird über `setup.sh` erstellt.

```
[GLOBAL]
mover_bin=/usr/libexec/unraid/move
# Standard: Dateien müssen 0 Tage alt sein (sofort verschieben)
min_age=0 
global_excludes=/mnt/user/system/excludes/global.txt

[Filme]
path=/mnt/cache/Filme
# Hier: Erst nach 30 Tagen verschieben
min_age=30
excludes=/mnt/user/system/excludes/filme.txt
```

## Verwendung & Argumente

Aufruf: `./smart_mover.sh [OPTIONEN]`

| Argument | Beschreibung |
| --- | --- |
| `--help` | Zeigt diese Hilfe an und beendet das Skript. |
| `--run` | **Scharfschalten.** Ohne diesen Schalter läuft das Skript nur im Simulationsmodus (Dry-Run). |
| `--force` | Ignoriert das `min_age` (Dateialter). Verschiebt alle Dateien, die nicht in einer Exclude-Liste stehen. |
| `--force-all` | Vorsicht! Ignoriert Dateialter **UND** Exclude-Listen. Verschiebt alles im Share-Ordner. |
| `--share "Name"` | Verarbeitet nur die angegebenen Shares (Komma-getrennt, z.B. `--share "Filme,TV"`). |

**Hinweis:** Das Skript löscht leere Ordner auf dem Cache nur dann, wenn es dort zuvor Dateien entfernt hat. Es greift niemals in Ordner ein, die nicht Teil des Mover-Prozesses waren.

## Beispiele

**Standardlauf (Test):**  
Zeigt an, was verschoben würde (beachtet Alter & Excludes).

`./smart_mover.sh`

**Ernstfall (Verschieben):**  
Verschiebt Dateien, die alt genug sind und nicht excluded wurden.

`./smart_mover.sh --run`

**Nur "Serien" sofort aufräumen:**  
Ignoriert das Dateialter, beachtet aber Excludes (z.B. .nfo Dateien bleiben).

`./smart_mover.sh --run --force --share "Serien"`
