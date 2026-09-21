# TM Eject Guard

Ejects your external disks a few minutes before a meeting starts, so a spinning
USB drive is never yanked out while it is still mounted.

The problem it solves: you grab the laptop on the way to a meeting, unplug the
Time Machine drive, and only remember the eject afterwards. On an HDD that is a
bad habit.

## How it decides

Nothing is polled. The app works out the single moment it needs to act on, arms
one timer for it, and then does nothing until something actually changes:

- a volume mounts or unmounts (`NSWorkspace`)
- the calendar changes (`EKEventStoreChanged` - EventKit is already the local
  replica that the sync daemons maintain, so there is no second cache to keep)
- the Mac wakes, and every timer that should have fired while it slept did not
- a setting changes

A five minute heartbeat is kept purely as a backstop for a notification that
never arrives.

When the timer fires, three questions are re-asked, stopping at the first "no":

1. **Is a guarded disk attached?**
2. **Is there still a real meeting starting within the lead time?** (5 minutes
   by default - the meeting may have been cancelled since the timer was armed.)
   The scheduler looks a full day ahead so that at 08:55 it already knows about
   the 09:00 meeting; the popover only ever shows today.
3. **Is the guard active?** Not disabled, not paused.

If all three hold, it stops a Time Machine backup that is writing to that disk,
ejects it with retries while Spotlight or `backupd` still holds it, and posts a
notification.

Deciding happens on the main thread, where the event store lives; only the
ejecting is handed to a background queue, because it can block for over a minute
on a busy volume and needs no EventKit at all.

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

## The popover

| | |
|---|---|
| **Disks** | Every external disk seen at least once, plus local Time Machine destinations. Click one to guard it. A disk being backed up shows a spinner and the percentage. Right click to hide one you will never plug in. |
| **Next meeting** | Only what is still happening **today** - this reports what the guard will do, it is not a second calendar. The calendar name is shown next to the title, which is how you spot it counting a calendar you did not mean to include. **Skip this meeting** ignores that one event, and **Undo skip** stays on screen until the meeting is behind you. |
| **Eject now** ⌘E | Names what it will act on: *Eject Time Machine WD*, or *Eject 2 disks*. It ejects the disks you **ticked** that are **connected** - not everything plugged in. |
| **Pause for 1 hour** | Suspend guarding. The row turns into **Resume guarding** while paused. |
| **Settings…** ⌘, | See below. |

Network Time Machine destinations never appear: there is nothing to eject on an
SMB share, so only `Kind = Local` destinations are listed.

Settings has three tabs:

- **General** - lead time, what counts as a meeting, ignoring *Free* events,
  ejecting on sleep, launch at login, restoring hidden disks.
- **Calendars** - watch all of them, or tick the ones that matter.
- **About** - version, source, log and config.

### The menu bar icon

Each state has its own shape rather than a different badge, because a badge
swap is too quiet to notice during the few seconds an eject takes.

| | |
|---|---|
| `externaldrive` | No guarded disk connected. |
| `externaldrive.fill.badge.checkmark` | A guarded disk is connected and armed. |
| `eject.fill` | Ejecting right now. |
| `externaldrive.badge.xmark` | Guarding is off or paused. |

## CLI

The app is the normal way to use this. The CLI is for setup and debugging.

```sh
tm-eject-guard                  # disks, selection, next meeting
tm-eject-guard --list           # remembered disks
tm-eject-guard --watch "WD"     # guard a disk
tm-eject-guard --forget "WD"    # hide it from the list
tm-eject-guard --unhide         # bring every hidden disk back
tm-eject-guard --calendars      # list calendars and the current selection
tm-eject-guard --watch-cal Calendar
tm-eject-guard --unskip         # undo the most recent skipped meeting
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
./build.sh      # build/TM Eject Guard.app and build/tm-eject-guard, ad-hoc signed
./install.sh    # build, install to /Applications and ~/bin, launch
./uninstall.sh  # stop and remove, keeping config and log
```

### Signing and notarization

```sh
SKIP_NOTARIZE=1 ./release.sh   # sign only, to check the certificate resolves
./release.sh                   # sign, notarize, staple
./install.sh --no-build        # install it without re-signing over the ticket
```

This matters for more than distribution. An ad-hoc signature is identified by
the binary's code directory hash, so **every rebuild looks like a different
program to TCC** and macOS asks for Calendar access again. A Developer ID
signature is a stable identity, so the permission is granted once and stays.

Under the hardened runtime EventKit needs an explicit entitlement
(`com.apple.security.personal-information.calendars`), which is why
`App/TMEjectGuard.entitlements` exists.

### Reviewing the UI

`MenuBarExtra` popovers cannot be opened programmatically, so there is a harness
that renders the popover straight to PNG in both appearances:

```sh
swiftc -O -target arm64-apple-macos14.0 \
    Sources/Core/Guard.swift Sources/App/DesignTokens.swift \
    Sources/App/GuardController.swift Sources/App/MenuContent.swift \
    Sources/App/SettingsView.swift Sources/Preview/main.swift -o /tmp/preview
/tmp/preview /tmp/menu.png     # writes menu-light.png and menu-dark.png
```

Requires macOS 14 or newer.
