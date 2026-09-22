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

Deciding happens on the main thread, where the event store lives. **Everything
that launches a process runs on a background queue** - scanning disks, reading
Time Machine status, and ejecting.

That last rule is not a preference. `Process.waitUntilExit()` runs the run loop
while it waits, so calling it on the main thread re-enters whatever the run loop
delivers next. A volume notification arrived during one such wait, ran the same
code again, and blocked on the config lock the first pass was still holding: a
permanent freeze with the app still showing in the menu bar. `Shell.run` no
longer uses `waitUntilExit`, every child process has a timeout, and CI fails the
build if either rule comes back.

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

Then open the menu bar icon and tick your disk under **DISKS**. Disks
are remembered once you plug them in, and local Time Machine destinations appear
in the list straight away.

Turn on **Launch at login** in Settings so it survives a reboot.

## The popover

| | |
|---|---|
| **Disks** | Every external disk seen at least once, plus local Time Machine destinations. Click one to guard it. A disk being backed up shows a spinner and the percentage. Right click to hide one you will never plug in. |
| **Next meeting** | Only what is still happening **today** - this reports what the guard will do, it is not a second calendar. The calendar name is shown next to the title, which is how you spot it counting a calendar you did not mean to include. **Skip this meeting** ignores that one event, and **Undo skip** stays on screen until the meeting is behind you. |
| **Disks ⌘1…⌘9** | The first nine disks toggle from the keyboard, and the card shows which key. |
| **Eject now** ⌘E | Names what it will act on: *Eject Time Machine WD*, or *Eject 2 disks*. It ejects the disks you **ticked** that are **connected** - not everything plugged in. |
| **Pause for 1 hour** | Suspend guarding. The row turns into **Resume guarding** while paused. |
| **Settings…** ⌘, | See below. |

Network Time Machine destinations never appear: there is nothing to eject on an
SMB share, so only `Kind = Local` destinations are listed.

Settings has three tabs:

- **General** - lead time, what counts as a meeting, ignoring *Free* events,
  how long the pause row pauses for, ejecting on sleep, launch at login,
  restoring hidden disks.
- **Calendars** - watch all of them, or tick the ones that matter.
- **About** - version, source, log and config.

### The menu bar icon

Each state has its own shape rather than a different badge, because a badge
swap is too quiet to notice during the few seconds an eject takes.

| | |
|---|---|
| `externaldrive` | No guarded disk connected. |
| `externaldrive.fill.badge.checkmark` | A guarded disk is connected and armed. |
| `externaldrive.fill.badge.timemachine` | Time Machine is writing to a guarded disk, with a progress bar under it. |
| `eject.fill` | Ejecting right now. |
| `externaldrive.badge.xmark` | Guarding is off or paused. |

While a backup runs, a 15x2 pt bar sits under the drive: filled to the
percentage Time Machine reports, or a short segment travelling left to right
while it is still sizing the job up - a bar frozen at zero reads as a stalled
backup. Both forms breathe between 55% and 100% opacity, because progress can
sit on one number for minutes and a still icon in a menu bar reads as a dead
one.

**A `MenuBarExtra` label is rendered to a static image, so SwiftUI's own symbol
effects never run there.** That was measured rather than assumed: a throwaway
menu bar app with `.symbolEffect(.pulse, options: .repeating)` was screenshotted
twenty times over two seconds and its icon brightness did not move by a
hundredth. The animation is therefore driven by `GuardController.backupPhase`,
an integer advanced four times a second - and only while a backup is actually
running.

Knowing a backup is running costs one `tmutil status` every 5 s while one is,
20 s while a guarded disk is merely attached, and nothing at all when none is.
That is a deliberate exception to the event-driven rule in the rest of the app,
and it is bounded by the thing that matters: the disk being plugged in.

The states are hard to review in place - the icon is 16 pt wide and some of them
only appear mid-backup - so the preview harness renders them all side by side:

```sh
/tmp/preview /tmp/icons.png icons
```

That is how the backing-up glyph was caught shrinking: stacking a bar under the
symbol stole its height until the size was pinned.

## Languages

English, Slovak, Czech and German; the app follows the system language and falls
back to English. Translations live in `Resources/<lang>.lproj/`, keyed
explicitly (`footer.ejectNow`) rather than by their English sentence, so
rewording the English does not silently orphan three translations.

Slovak and Czech need a separate plural form for 2-4 ("2 disky" but "5 diskov"),
which `Localizable.stringsdict` provides and `LocalizationTests` insists on.
Those tests also check that every key the source uses exists in all four
languages, that no language carries a key nothing uses, and that the format
specifiers match English - a `%@` translated as `%d` does not render wrong text,
it reads whatever happens to be at that address.

Log lines are deliberately **not** translated. A log gets grepped and pasted
into issues, so it stays English.

## Updates

The app updates itself through [Sparkle](https://sparkle-project.org). The feed
is `appcast.xml` on the main branch, and the archives are GitHub release assets.

Two independent checks have to pass before anything is installed:

- **The running copy must carry our Developer ID signature.** An ad-hoc build -
  which is what `build.sh` produces - reports "This build cannot update itself"
  and never contacts the feed. Downloading and executing a binary because an
  unsigned build asked to is remote code execution with extra steps, so the
  decision is a pure function in `UpdaterGate` with tests, not a condition
  buried in a factory.
- **The downloaded archive must carry our EdDSA signature.** The public half is
  in `Info.plist`; the private half is in the login keychain. These answer
  different questions - one says *we* are the thing running, the other says the
  thing we fetched came from us - and neither substitutes for the other.

Sparkle normally installs on quit, which for a menu bar app can mean never, so
the install-on-quit hook is captured and offered as a row in the popover
instead.

Releasing:

```sh
./release.sh                        # sign, notarize, staple
./make-appcast.sh build/TM-Eject-Guard-1.2.zip
gh release create v1.2 build/TM-Eject-Guard-1.2.zip
git add appcast.xml && git commit -m "Release 1.2" && git push
```

**The repository has to be public for updates to work.** Sparkle carries no
GitHub credentials, so on a private repository both the feed on
raw.githubusercontent.com and the release asset answer 404 and every check fails
with nothing obviously wrong at either end. Measured, not guessed: with a token
both return 200 and the published archive's EdDSA signature matches the appcast.

`sparkle.sh` pins the framework by version **and** SHA-256. An updater is the
one dependency whose compromise is arbitrary code execution, so it is never
fetched as "latest".

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

## Layout

```
Sources/Core/     the engine: no UI, compiled into both binaries and the tests
Sources/App/      the SwiftUI menu bar app
Sources/CLI/      the command line tool
Sources/Preview/  renders the popover to PNG so the layout can be reviewed
Resources/        en, sk, cs and de translations, copied into the bundle
Tests/            unit tests over Sources/Core
```

Everything is built in **Swift 6 language mode** with warnings as errors. That
is not decoration: strict concurrency checking is what names the kind of mistake
that froze this app once already, and it now refuses to compile a captured
mutable variable crossing a queue boundary.

## Tests

```sh
swift test
```

`Package.swift` exists for the tests, not for shipping: it exposes `Sources/Core`
as a library so `swift test` can reach it with `@testable`. The app and CLI are
still assembled by `build.sh` from the same sources, so the shipping binaries are
unaffected by the test setup.

The suite covers the pure half of the logic, which is where every real bug in
this project has been so far:

| Area | Why it is tested |
|---|---|
| Config decoding | A key added later once wiped every setting the user had. |
| `Disks.merge` | Identity of a disk, and whether re-keying it silently unguards it. |
| `Disks.guardedVolumes` | An unticked disk must never become a target. |
| `Disks.isMountedVolume` | The boot volume must never be an eject candidate. |
| `Sanitize.oneLine` | Untrusted titles must not forge log lines or break AppleScript. |
| `BackupStatus` | `Percent: -1` means unknown, not zero. |

The tests were checked by putting two real bugs back in: removing the hand
written config decoder, and dropping the ticked-disk filter. Both were caught.

CI runs the tests, builds the app and CLI, and enforces two rules that are
easier to state than to remember: no shell is ever invoked, and `waitUntilExit`
is banned.

## Safety notes

- Only volumes that are **external, ejectable and directly under `/Volumes`** are
  ever considered. The boot disk cannot be reached by any code path.
- Disks are identified by **volume UUID**, not by name, so another volume that
  happens to share a name is not touched.
- A Time Machine backup is stopped only when it is writing to the disk being
  ejected. A backup to a different destination keeps running.
- A failed eject is reported with the processes holding the volume, so you know
  not to pull the cable.
- The eject targets the **whole physical disk**, not just the guarded volume,
  which is what Finder's eject does. Other volumes on the same disk are
  unmounted too; if one of them is busy the eject fails and names the process.
- To use the disk again, unplug and replug it. An encrypted Time Machine volume
  cannot be remounted in software once ejected - it unlocks from the keychain
  when the disk is reattached.
- The log names your meetings, so it is created `0600`, as is the config file.
  At 512 KB it rolls over to `.log.1` rather than being deleted, because the
  entry you want is usually the one just before the rollover.
- Eject-on-sleep is best effort. macOS gives sleep observers a short window and
  stopping a running backup alone was measured at ~11 s, so it is attempted once
  on a background queue and may not finish. It never blocks sleep.

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

### Contrast

The popover renders to PNG, so contrast is measured rather than guessed. Section
headers were `.tertiary`, matching the sibling apps, which measured **2.74:1**
against the dark background - under the 4.5:1 WCAG asks for at 9pt. They are
`.secondary` now, which measures 5.91:1.

### Reviewing the UI

`MenuBarExtra` popovers cannot be opened programmatically, so there is a harness
that renders the popover straight to PNG in both appearances:

```sh
swiftc -O -swift-version 6 -target arm64-apple-macos14.0 \
    Sources/Core/*.swift Sources/App/DesignTokens.swift \
    Sources/App/GuardController.swift Sources/App/MenuContent.swift \
    Sources/App/SettingsView.swift Sources/App/UpdaterProtocol.swift \
    Sources/App/StatusIcon.swift Sources/Preview/main.swift -o /tmp/preview
/tmp/preview /tmp/menu.png     # writes menu-light.png and menu-dark.png
```

Requires macOS 14 or newer.
