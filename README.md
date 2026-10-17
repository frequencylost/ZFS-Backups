# ZFS Backups for Unraid

One plugin for ZFS snapshots on Unraid: scheduled snapshots with **their own retention per job**, optional
replication, automatic folder-to-dataset conversion, and waking array disks before a run, all managed from
**Settings → ZFS Backups**.

It replaces this common combination:

| You used | ZFS Backups does it with |
|---|---|
| Sanoid plugin + SpaceInvader One's *ZFS Dataset Snapshot and Replication* script | Snapshot jobs (sanoid under the hood) + optional replication |
| SpaceInvader One's *Auto Dataset Watcher & Converter* script | Dataset Conversion tab |
| ZFS Buddy Backup snapshots for media | A second snapshot job with short retention |
| A "touch a file on every disk" spin-up script | Built-in disk wake-up through Unraid's own spin-up command |

## Features

- **Jobs with their own retention.** For example, *Appdata* keeps 7 daily / 4 weekly / 3 monthly, while *Media*
  keeps 2 daily. Each job has its own schedule (daily, weekly, hourly or custom cron).
- **Child datasets handled for you.** Pick `supercache/appdata` and every container's dataset is included, and new
  ones are picked up automatically. You can exclude individual children, or use atomic `zfs snapshot -r` instead.
- **Adopts your existing snapshots.** Snapshots are named the sanoid way (`autosnap_…_daily`), so history created by
  the Sanoid plugin, SpaceInvader One's scripts or ZFS Buddy Backup is kept and pruned under the new rules. Snapshots
  with any other name, such as ones made in ZFS Master, are never touched.
- **Replication** after snapshotting, either `zfs send` via syncoid (to another pool, or another server over SSH) or
  rsync (dated hard-linked copies, or a mirror) for non-ZFS destinations. Replication runs *before* pruning, and
  syncoid keeps a bookmark, so an incremental base is never lost even with 1-day retention.
- **Folder → dataset conversion** for `appdata`, `domains` and so on. Folders are converted one at a time, and only
  the containers or VMs using that folder are stopped, then started again straight away. Copies are verified, and a
  copy that fails or runs past the time limit (20 min by default) is rolled back.
- **Array disk wake-up.** A job spins up only the array disks it needs, all at once, through Unraid's `emcmd`
  (the same thing as the GUI's spin-up button). Disks are never written to just to wake them.
- **Safe by design.** It refuses to run when two jobs would manage the same dataset, warns when another tool
  (ZFS Buddy Backup, the Sanoid plugin, old scripts) manages the same datasets, and offers a dry run and a
  read-only *Preview* for every job.
- Unraid notifications, per-job logs, and the last result of each job kept across reboots.

## Install

In Unraid: **Plugins → Install Plugin**, paste:

```
https://raw.githubusercontent.com/frequencylost/ZFS-Backups/main/zfs.backups.plg
```

Requires Unraid 6.12 or newer (native ZFS). sanoid/syncoid 2.3.0 and their Perl modules are bundled. The modules are
only installed when another plugin hasn't already installed them.

## Switching over from the scripts and plugins

Nothing changes until you create jobs, so you can install first and switch over one piece at a time.

1. **Create the jobs** under *Snapshot Jobs*, matching what you have today. Example:
   - *Appdata*: `supercache/appdata`, children one by one, keep 7 daily / 4 weekly / 3 monthly, daily 00:25
   - *Media*: `disk1/ANIME`, `disk4/MOVIES`, … keep 2 daily, daily 00:00, wake array disks on
2. Click **Preview** on each job. It shows exactly which snapshots would be taken and pruned, without changing
   anything. Expect "would take 0" right after your old tools ran tonight.
3. **Turn the old tools off.** The yellow banner on the Jobs tab lists everything that still overlaps:
   - User Scripts: set *ZFS - Snapshot and Replication*, *ZFS - Auto Convert to Dataset* and
     *ZFS - Array Disks Spin-up for Snapshot* to *Schedule Disabled*.
   - ZFS Buddy Backup: remove the media datasets from its snapshot settings (or uninstall it if you don't use its
     replication).
   - The Sanoid plugin can be uninstalled. The plugin brings its own copy.
4. Set up **Dataset Conversion** (watch `supercache/appdata`, run "at the start of any snapshot job").
5. Run each job once with **Run now** and check the log.

## How retention works

Each job writes its own sanoid config on every run (one section per dataset) and runs sanoid with its own cache
and lock directories, so jobs never block each other. Sanoid deletes a snapshot only when it is **both** older
than the window (for example 7 days for `daily = 7`) **and** there are more than that many of its kind. So a
server that was off for a week still keeps its last 7 dailies.

A run does, in order:

1. Convert new folders to datasets (if Dataset Conversion is set to run with jobs)
2. Wake the array disks the job uses
3. Take snapshots that are due
4. Replicate (if configured)
5. Prune snapshots past retention
6. Record status, notify

## Command line

```
zfsb run <job> [--dry-run]   run one job now
zfsb run-all [--dry-run]     run every enabled job
zfsb plan <job>              read-only preview of a run
zfsb convert [--dry-run]     run the folder -> dataset converter
zfsb validate                check every job's settings
zfsb conflicts               list other tools managing the same datasets
zfsb status                  last result of every job (JSON)
```

## Files

| Path | What |
|---|---|
| `/boot/config/plugins/zfs.backups/jobs/<job>.cfg` | Job settings |
| `/boot/config/plugins/zfs.backups/convert.cfg` | Dataset Conversion settings |
| `/boot/config/plugins/zfs.backups/status/` | Last result of each job (survives reboots) |
| `/var/log/zfs.backups/` | Run logs (RAM) |
| `/usr/local/emhttp/plugins/zfs.backups/` | Plugin files, including bundled sanoid/syncoid |

Uninstalling removes the plugin and its schedules but keeps your job settings and all snapshots.

## Development

```
bash tests/run-tests.sh      # 136 checks, real sanoid against a fake zfs - needs Linux, bash 5, perl deps
./build.sh [version]         # builds packages/*.txz and stamps version + MD5 into zfs.backups.plg
```

The tests put fake `zfs`, `docker`, `virsh` and `emcmd` commands first in `PATH`, and abort if the real ones would
run, so they are safe to run on a live Unraid server.

## Credits and license

- [sanoid / syncoid](https://github.com/jimsalterjrs/sanoid) by Jim Salter (GPLv3), bundled unmodified.
- Workflow based on [SpaceInvader One](https://github.com/SpaceinvaderOne)'s ZFS snapshot, replication and dataset
  converter scripts.
- Perl dependency packages as shipped by [ZFS Buddy Backup](https://github.com/Piratkopia13/unraid-buddybackup).

Licensed under the GNU GPL v3 (see `LICENSE`).
