# Smart Mover for Unraid

**Smart Mover** is a wrapper around the official Unraid `move` binary. The stock mover moves *everything* a share's settings allow; Smart Mover filters by **age** and **exclude lists** first and then pipes the remaining paths to the very same binary – so allocation, split level, in-use checks and permissions are still handled by Unraid.

## Features

* **Correct direction per share** – read from `/boot/config/shares/<share>.cfg` at runtime:
  `shareUseCache="yes"` → pool → array (or secondary pool), `"prefer"` → array (or secondary pool) → pool, `"only"`/`"no"` → skipped.
* **Age filter** in days, based on `ctime` (default: the time the file landed on the pool, survives `rsync -a`) or `mtime` – global or per share. Not applied to `prefer` shares unless set per share.
* **Exclude lists** – one or more files per share plus global ones. Entries: a directory (protects the subtree), an exact file path (an [EmbyCache](https://github.com/helmi1987/embycache-for-unraid) exclude list works unchanged), a glob (`*.nfo`, `Season 0*`) or a plain substring. Comments, blank lines and CRLF are tolerated; `/mnt/user/<share>/…` paths are translated to the scanned pool path.
* **Threshold** – `move_when_used_above=<percent>`: only move when the pool is fuller than X % (global or per share).
* **Verification** – after the move the script checks what is still on the source side (in use, or already present at the destination) and reports it.
* **Cleanup** – empty directories left behind by moved files are removed up to (never including) the share root.
* **Safe by default** – dry-run unless `--run`; `flock` against parallel runs; refuses to start while the stock mover is running.
* No dependencies beyond bash, findutils and coreutils.

## Installation

1. Copy `custommover_run.sh` and `setup_custommover.sh` to a folder on the array or a pool, e.g. `/mnt/user/system/scripts/custommover/`, and make them executable.
2. Run the wizard: `./setup_custommover.sh` – it writes `smart_mover.ini` **next to the scripts**.
3. Check what was discovered: `./custommover_run.sh --list-shares`
4. Dry-run: `./custommover_run.sh` (prints every file that would move; full list in the log)
5. Go live, e.g. as a User Script or cron job: `/mnt/user/system/scripts/custommover/custommover_run.sh --run`

Set the stock mover schedule to the longest interval (or disable it via Mover Tuning) – otherwise both movers work on the same shares.

## Configuration (`smart_mover.ini`)

```ini
[GLOBAL]
# empty = auto-detect
mover_bin=/usr/libexec/unraid/move
log_file=/mnt/user/system/scripts/custommover/smart_mover.log
# days; 0 = move immediately
min_age=30
# ctime | mtime
age_stat=ctime
# percent; 0 = always
move_when_used_above=0
# also bring 'prefer' shares back to the pool (like the stock mover)
move_prefer_shares=yes
# 0-3, passed as -d to the move binary (shown with CUSTOMMOVER_LOG_LEVEL=DEBUG)
mover_debug=0
# dry-run lines shown on the console
max_list=50
global_excludes=/mnt/user/system/excludes/global.txt

[Filme]
min_age=14
excludes=/mnt/user/system/scripts/embycache/embycache_exclude.txt

[Downloads]
min_age=0
move_when_used_above=80

[appdata]
skip=yes
```

Per-share keys: `min_age`, `age_stat`, `excludes` (comma separated), `move_when_used_above`, `skip=yes`. The section name is the share name; paths are never stored. Comments go on their own line (`#` or `;`), not behind a value. Values from the INI can be overridden with environment variables, see `--help`.

### Exclude file format

```
# keep metadata on the pool
*.nfo
# keep a whole folder
/mnt/user/Filme/Kids
# exact files – e.g. EmbyCache's list
/mnt/cache/Serien/Show/Season 01/Show - S01E03.mkv
# substring anywhere in the path (legacy)
Trailers
```

## Usage

| Option | Effect |
| --- | --- |
| *(none)* | Dry-run. Shows what would move, touches nothing. |
| `--run` | Move for real. |
| `--force` | Ignore the age filter and the threshold; exclude lists still apply. |
| `--force-all` | Ignore age, threshold **and** exclude lists. |
| `--share "A,B"` | Only these shares. |
| `--list-shares` | Show discovered shares, direction and effective settings. |
| `--help` | Full help including environment variables. |

Environment variables: `CUSTOMMOVER_MODE` (dry/run), `CUSTOMMOVER_FORCE` (age/all), `CUSTOMMOVER_SHARES`, `CUSTOMMOVER_INI`, `CUSTOMMOVER_LOG_LEVEL` (DEBUG shows the mover's own output), `CUSTOMMOVER_MOVER_DEBUG`, `CUSTOMMOVER_IGNORE_MOVER=1`.

Exit codes: 0 ok, 1 configuration error, 2 another Smart Mover or the stock mover is running.

## Notes

* **ctime vs mtime.** `ctime` is the inode change time – it is set when the file is created on the pool and cannot be carried over from the source, which makes it the right measure for "how long has this been on the cache". It is also reset by `chmod`/`chown` (e.g. Unraid's *New Permissions* tool or a container fixing ownership), which makes the file look new again. Use `mtime` for shares where that happens regularly.
* **`prefer` shares** are moved array → pool, exactly like the stock mover does. If you only want pool → array behaviour, set `move_prefer_shares=no`.
* **Files that stay behind** after a live run are listed as WARN: the move binary skips files that are open (`fuser`) and files that already exist at the destination. Nothing is ever deleted by this script except empty directories.
* **Together with EmbyCache:** point a share's `excludes=` at `embycache_exclude.txt` and the cached media is never moved back by this script – no Mover Tuning needed.
