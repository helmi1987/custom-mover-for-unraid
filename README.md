# Smart Mover for Unraid

**Smart Mover** is an advanced, logic-based wrapper for the internal Unraid Mover. Unlike the standard mover, which moves "everything" based on simple share settings, Smart Mover gives you granular control over **what** moves and **when** it moves.

**Key Feature:** Files are filtered by **Age (CTIME)** and **Exclude Lists** before being piped directly to the official Unraid Mover binary.

## ✨ Features

*   **Precision Age Filter:** Moves files only after they have been on the cache for X days. Uses `CTIME` (Change Time) for accuracy, calculating age in minutes (e.g., 1 day = 1440 mins).
*   **Exclude System:** Define global or share-specific exclude files (e.g., keep `.nfo`, `appdata`, or specific media on cache).
*   **Unraid 7 & Multi-Pool Ready:** Automatically detects Unraid version and supports multiple cache pools (e.g., `/mnt/nvme`, `/mnt/cache`).
*   **Smart Cleanup:** Removes empty directories only in paths where files were successfully moved. Includes root-share protection.
*   **Dry-Run by Default:** No files are touched unless you explicitly use the `--run` flag.

## 🚀 Installation & Setup

### 1\. Setup

Run the interactive setup wizard. It scans your Unraid config, detects cache pools, and creates the configuration.

```
./setup.sh
```

The wizard will generate a file named `smart_mover.ini`.

### 2\. Configuration (smart\_mover.ini)

You can edit the INI file manually or rerun `setup.sh` to update it.
```
[GLOBAL]
mover_bin=/usr/libexec/unraid/move
min_age=0
global_excludes=/mnt/user/system/excludes/global.txt

[Movies]
path=/mnt/cache/Movies
min_age=30
excludes=/mnt/user/system/excludes/movies.txt
```
## ⚙️ Usage & CLI Arguments

The script uses safety flags. Running it without arguments will perform a **Simulation (Dry-Run)**.

```
./smart_mover.sh [OPTIONS]
```

| Option | Description |
| --- | --- |
| `--run` | **ACTIVATE.** Disables Dry-Run mode and executes the move. |
| `--force` | **Ignore Age.** Moves all files regardless of how old they are, but **still respects** exclude lists. Useful for freeing up space quickly while keeping protected files. |
| `--force-all` | **Nuke Mode.** Ignores Age AND Exclude lists. Moves everything in the configured shares to the array. |
| `--share "Name"` | **Filter.** Only process specific shares. Separate multiple names with commas (e.g., `--share "Movies,TV"`). |
| `--help` | Shows the help menu. |

## 📋 Examples

### Daily Maintenance (Cronjob)

Moves files that match the age criteria defined in your config.

```
./smart_mover.sh --run
```

### Emergency Cleanup (Cache Full)

Moves everything immediately to free space, but keeps your excluded files (metadata, appdata, etc.) safe on cache.

```
./smart_mover.sh --run --force
```

### Testing a specific Share

Simulates what would happen for the "Downloads" share.

```
./smart_mover.sh --share "Downloads"
```

## ⚠️ Important Notes

*   **CTIME vs MTIME:** This script uses `CTIME` (Change Time) to determine file age. This represents the time the file metadata was last changed (e.g., when it was written to the cache). This is more accurate than Modification Time for downloaded media.
*   **Cleanup:** The script attempts to remove empty directories after moving files. It contains safety logic to never delete the share root itself.
