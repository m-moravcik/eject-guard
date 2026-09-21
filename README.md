# TM Eject Guard

Ejects your external disks a few minutes before a meeting starts, so a spinning
USB drive is never yanked out while it is still mounted.

The problem it solves: you grab the laptop on the way to a meeting, unplug the
Time Machine drive, and only remember the eject afterwards. On an HDD that is a
bad habit.

## How it decides

Every 30 seconds the app asks three questions, and stops at the first "no":

1. **Is a guarded disk attached?** If not, nothing else happens - the calendar is
   never even touched.
2. **Is there a real meeting starting within the lead time?** (6 minutes by
   default.)
3. **Is the guard active?** Not disabled, not paused.

If all three hold, it stops a Time Machine backup that is writing to that disk,
ejects it with retries while Spotlight or `backupd` still holds it, and posts a
notification.

### What counts as a "real meeting"

A timed event, not cancelled, that you have not declined, with at least two
attendees. That last part is what separates an actual meeting from calendar
blocks like `Focus`, `Home-office` or `Batch Tasks`, without any title matching.

You can widen it to any timed event, restrict it to specific calendars, and
optionally ignore events you marked as *Free*.

## Install

```sh
./install.sh
```

Builds both targets, puts the app in `/Applications`, the CLI in `~/bin`, and
starts the app. macOS will ask for Calendar access on first launch.

Then open the menu bar icon and tick your disk under **Sledované disky**. Disks
are remembered once you plug them in, and local Time Machine destinations appear
in the list straight away.

Turn on **Spúšťať pri prihlásení** so it survives a reboot.

## Menu

| Item | What it does |
|---|---|
| Sledované disky | Which disks to guard. Attached ones are marked `● pripojený`. Detached ones can be forgotten. |
| Odpojiť teraz | Eject the guarded disks right now, ignoring the calendar. |
| Kalendáre | Which calendars to watch. Default is all of them. |
| Predstih | How long before a meeting to eject. |
| Čo je míting | Attendee threshold, and whether to ignore *Free* events. |
| Preskočiť tento míting | Ignore the next meeting once. |
| Pozastaviť | Pause for 1, 4 or 8 hours. |
| Odpojiť aj pri uspaní Macu | Also eject when the lid closes. Off by default. |

## CLI

The app is the normal way to use this. The CLI is for setup and debugging.

```sh
tm-eject-guard                  # disks, selection, next meeting
tm-eject-guard --list           # remembered disks
tm-eject-guard --watch "WD"     # guard a disk
tm-eject-guard --forget "WD"    # drop it from the remembered list
tm-eject-guard --calendars      # list calendars and the current selection
tm-eject-guard --watch-cal Calendar
tm-eject-guard --dry-run        # run a pass without ejecting
tm-eject-guard --eject-now      # eject guarded disks now
```

## Files

| Path | |
|---|---|
| `~/Library/Application Support/TMEjectGuard/config.json` | Settings, shared by the app and the CLI. |
| `~/Library/Logs/tm-eject-guard.log` | What it did and why. Rotates at 512 KB. |

## Safety notes

- Only volumes that are **external, ejectable and directly under `/Volumes`** are
  ever considered. The boot disk cannot be reached by any code path.
- Disks are identified by **volume UUID**, not by name, so another volume that
  happens to share a name is not touched.
- A Time Machine backup is stopped only when it is writing to the disk being
  ejected. A backup to a different destination keeps running.
- A failed eject is reported with the processes holding the volume, so you know
  not to pull the cable.
- Ejecting powers the drive down. To use it again, unplug and replug it.

## Build

```sh
./build.sh      # build/TM Eject Guard.app and build/tm-eject-guard
./uninstall.sh  # stop and remove, keeping config and log
```

Both binaries are ad-hoc signed. TCC identifies them by code directory hash, so
a rebuild revokes Calendar access and macOS prompts again on the next launch.

Requires macOS 14 or newer.
