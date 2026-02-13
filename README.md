# Smart Mover v1.0

Ein intelligenter Wrapper für den nativen Unraid Mover mit Unterstützung für Exclude-Listen und gezieltem Cleanup.

## 🚀 Funktionen & Features

**Selektives Verschieben**  
Nutzt `find` und Pipes, um nur gewünschte Dateien an den Mover zu übergeben. Excludes bleiben auf dem Cache.

**Dual-Filter System**  
Unterstützt **Globale Excludes** (für alle Shares) und **Share-Spezifische Excludes** gleichzeitig.

**Chirurgischer Cleanup**  
Löscht leere Verzeichnisse auf dem Cache nur dort, wo Dateien bewegt wurden. Enthält `Root-Protection` (Hauptordner bleiben erhalten).

**Native Integration**  
Verwendet die originale Unraid Mover Binary (\`/usr/libexec/unraid/move\`), um Dateikonsistenz und User-Share-Regeln zu gewährleisten.

**Interaktives Setup**  
Das Setup-Script erkennt Shares automatisch und unterstützt Tab-Completion für Pfade.

**Dry-Run Schutz**  
Standardmäßig werden keine Daten bewegt. Erst der Schalter `--run` aktiviert den scharfen Modus.

## ⚙️ Technische Funktionsweise

Im Gegensatz zum Standard-Mover, der pauschal alles verschiebt, arbeitet der Smart Mover in vier Phasen:

1\. Discovery: `find $PATH -type f` sucht alle Dateien auf dem Cache.

2\. Filtering: Abgleich gegen Globale & Share-Excludes (via grep).

3\. Execution: Pipe der gefilterten Liste direkt in die Unraid Mover Binary.

4\. Cleanup: Gezieltes Löschen leerer Quell-Ordner (mit Root-Schutz).

## 📥 Installation

1.  Erstelle einen Ordner für die Scripte (z.B. `/mnt/user/system/scripts/custom_mover/`).
2.  Kopiere die folgenden drei Dateien in diesen Ordner:
    *   `custommover_setup.sh`
    *   `custommover_run.sh`
3.  Mache die Scripte ausführbar:
    
    ```
    chmod +x custommover_setup.sh custommover_run.sh
    ```
    

## 🛠 Konfiguration (Setup)

Führe das Setup-Script aus, um die `smart_mover.ini` zu erstellen. Das Script scannt deine Unraid-Konfiguration.

```
./custommover_setup.sh
```

### Funktionen im Setup:

*   **Auto-Discovery:** Findet automatisch den Pfad zur Mover-Binary und deine Cache-Disk.
*   **Tab-Completion:** Bei der Eingabe von Exclude-Dateien kannst du die Tab-Taste nutzen.
*   **Multi-Exclude:** Du kannst mehrere Exclude-Dateien nacheinander hinzufügen (einfach Enter drücken, wenn fertig).
*   **Share-Management:** Erkennt neue Shares und fragt, ob diese konfiguriert werden sollen.

## ▶️ Verwendung (Run)

Das Script `custommover_run.sh` liest die erstellte INI-Datei und führt die Aktionen aus.

**Wichtig:** Das Script unterstützt Log-Rotation. Das Logfile liegt standardmäßig unter dem Pfad, der im Setup definiert wurde.

### 1\. Testlauf (Dry-Run)

Ohne Argumente läuft das Script im Simulationsmodus. Es zeigt an, welche Dateien verschoben würden (PLAN) und welche Filter greifen.

```
./custommover_run.sh
```

### 2\. Scharfer Modus (Live)

Verschiebt Dateien physikalisch und bereinigt leere Ordner.

```
./custommover_run.sh --run
```

## 📄 config.ini Struktur

Die Datei `smart_mover.ini` wird automatisch erstellt, kann aber auch manuell bearbeitet werden:

```
[GLOBAL]
mover_bin=/usr/libexec/unraid/move
log_file=/var/log/smart_mover.log
global_excludes=/mnt/user/system/exclude_global.txt

[Filme]
path=/mnt/cache/Filme
excludes=/mnt/user/system/exclude_filme.txt,/mnt/user/system/exclude_temp.txt

[Serien]
path=/mnt/cache/Serien
excludes=
```

Smart Mover Script © 2026 | Erstellt für Unraid User