# Development

How Eject Guard works inside, how to build and release it, and the lessons
behind the rules the code follows. For what the app does, see the
[README](README.md).

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
unmounts it with retries while Spotlight or `backupd` still holds it, and posts
a notification.

## Reconnecting after a meeting

The guard cannot know whether the user will leave the desk. Location, network
and "is this meeting online or hybrid" were all considered and dropped: most
meetings are hybrid, and the cost of a needless unmount is small once it is
undone. So it undoes it. Before a meeting the disk is **unmounted, not
ejected** (`diskutil unmountDisk`): every volume is down and flushed, so pulling
the cable is as safe as after an eject, but the device stays attached. When the
meeting ends, a disk that is still there was never unplugged, and it is mounted
again. A Time Machine backup the guard stopped is started again straight away
rather than at the next hourly run.

- **Persisted** in `pendingReconnects`, so a restart or a sleep through the
  meeting keeps it. Its own timer, independent of guarding being on and of
  calendar access: a disk the guard took down is put back regardless.
- **Found by volume UUID** with `diskutil info`, which still answers for an
  unmounted volume and stops answering once the cable is out. Only a string
  that parses as a UUID is ever passed: diskutil also accepts volume names.
  A volume without one could never be found again, so it is ejected as
  before, and the notification only promises a reconnect when every disk of
  that pass got one.
- **The whole disk comes back.** When diskutil confirms the volume's whole
  disk is external, `diskutil mountDisk` mounts every volume on it, the ones
  the user had left unmounted included, mirroring `unmountDisk`. Only when
  the device cannot be confirmed external is just that volume mounted, by its
  UUID.
- **Not between meetings.** While a real meeting is running or starts within
  the lead time, the reconnect waits for it to end, following back-to-back
  chains (`Meetings.busyUntil`).
- **Encrypted volumes lock on unmount.** Measured on APFS: after any unmount
  the volume reads `Locked`, and `diskutil mountDisk` exits 0 and prints
  "mounted successfully" while nothing is mounted. Only reading the mount
  point back is trusted. The guard reads the volume's "Encrypted Volume
  Password" item from the login keychain (service and account both the volume
  UUID; the first read needs the user's approval) and passes it to `diskutil
  apfs unlockVolume -stdinpassphrase`. If the volume is still down and it is a
  Time Machine disk, the guard asks Time Machine to start a backup to it
  (`tmutil startbackup --destination`) and waits up to 90 s for the volume to
  appear; this was not seen to unlock a disk. Failing that, the user is told to
  replug it.
- **⌘E and eject on sleep clear everything pending whenever they run.** They
  say the user is leaving, and on a fixed USB disk the device can outlive an
  eject, so it would otherwise be found "still plugged in" and mounted again.
  `ejectGuarded` drops every entry before it ejects anything, even when it
  then finds nothing to eject. They only run with a guarded target to act on:
  eject on sleep needs a mounted guarded disk or any guarded network
  destination, ⌘E a mounted guarded disk; `eject-guard --eject-now` always
  runs. So with only a waiting disk
  and no guarded network destination nothing runs and the entry stays, and a
  disk still attached after the meeting is mounted again. That is intended:
  a waiting disk was never ejected, so its device cannot have outlived one,
  and if it is still attached after a wake the user is at the desk.
- An entry more than 12 hours past its time is dropped without acting on it.

A guarded **network** Time Machine destination counts as attached for the first
question: Time Machine reports it on every pass and a backup to it can start at
any moment. For one there is nothing to eject, only a running backup to stop.

## Network Time Machine destinations

Listed, because leaving the network mid-backup is how a sparse bundle ends up
needing a fresh backup. Plain SMB or NFS shares are not: there is no cable to
pull and macOS drops them on its own.

- **Matched by `DestinationID`, never by mount point.** While a backup to a
  share runs, `tmutil status` reports the disk image inside it
  (`/Volumes/Backups of <Mac>`) as `DestinationMountPoint`. That image is a
  disk image, so it is never offered either.
- **`tmutil stopbackup` is asynchronous for a share.** Measured: it returned 0
  within half a second, the backup sat in `Stopping`, and it took ~55 s to end.
  So the stop polls `tmutil status` for up to 120 s and only then says
  whether it worked. A stop that did not finish says "stay on this network".
- **Never on the eject path.** `Disks.attachedVolume(for:)` returns nil for a
  network destination, so `guardedVolumes` cannot contain one, and no volume
  is ever linked to it.
- **Exact identity crosses kinds, guesses do not.** Matching by name or by
  Time Machine's own volume record never folds a plugged-in disk into a share.
  A shared destination ID does, because a release older than this one, running
  at the same time, drops the `network` key it does not know.
- `tmutil destinationinfo` took 21.7 s while a backup to a share was mounting
  its disk image, past the 15 s the scan allows. That pass sees no
  destinations and the merge keeps what it had.

## Stopping and starting a backup by hand

On its own the guard stops a backup only to a guarded disk, on its way to
taking that disk off. By hand the user can stop or start one for any
destination, guarded or not: a backup slowing the Mac down is theirs to stop,
and the system menu's "Back Up Now" may be hidden because this icon already
shows the progress.

- **Stop backup** sits in the footer while Time Machine runs, and is gone
  during an eject pass, whose own row says what it does to the backup.
  `tmutil stopbackup` takes no destination: Time Machine runs one backup at a
  time. ⌘E no longer doubles as the stop for a guarded share; it ejects, and
  stops a backup to a guarded share on the way, as before.
- **Back up now** is in a row's context menu, for a destination Time Machine
  reports and, for a disk, one that is plugged in (`BackupControl.destinationToStart`).
  Not for a disk unmounted for a meeting: an encrypted one is locked again, and
  a backup to it fails. Greyed out while any backup runs. It runs `tmutil
  startbackup --destination`, without `--auto`, which is the background mode of
  a scheduled backup.
- **Not remembered.** A stop by hand never sets `stoppedBackup`, so nothing
  starts the backup again after a meeting; Time Machine carries on at its next
  scheduled backup.
- **Settled against the status polls**, not waited out on the work queue,
  which an eject pass may need meanwhile (`BackupRequest.settle`). The poll
  runs every 5 s while a request is open. A stop is done once nothing runs,
  given 120 s, since a share sat in `Stopping` for ~55 s; a start once a
  backup runs, given 30 s. Past that the popover's problem row says it did not
  take. An eject pass drops an open request: it deals with the backup itself.
- Measured on a USB disk, 2026-10-24: `tmutil startbackup --destination`
  returned 0 and `tmutil status` read `Running = 1`, `BackupPhase = Starting`
  within half a second. `tmutil stopbackup` by hand had ended the backup
  within 3 s.

## How a disk is connected

The popover names the interface DiskArbitration reports
(`kDADiskDescriptionDeviceProtocolKey`): USB, Thunderbolt (also for
`PCI-Express`, which is what an NVMe in a Thunderbolt enclosure reports), or SD
card. Anything else shows as plain "Connected" rather than a guess. Observed
values: `Apple Fabric` for the internal SSD and `Virtual Interface` for a disk
image, neither of which is ever offered. It is the same IPC call that already
tells a disk image apart, so no process is launched.

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

## The menu bar icon

The icon is Eject Guard's own symbol, the app icon in miniature: an eject
triangle over a bar. Each state has its own shape rather than a different
fill, because a fill swap is too quiet to notice during the few seconds an
eject takes, and outline against fill alone does not read at 1x.

| | |
|---|---|
| idle | Outline triangle over a thin line: no guarded disk connected. |
| armed | Solid triangle over a solid slab: a guarded disk is connected. |
| backing up | The bar fills with Time Machine's progress, with Time Machine's clock-and-arrow badge in the corner. Any destination, guarded or not, and even with guarding off. The triangle is solid only while a disk is guarded. |
| ejecting | Triangle lifted, speed lines where the bar was. |
| off | Idle with a slash through it: guarding is off or paused. |
| waiting to reconnect | Outline triangle over a dashed slot, the slab's outline drawn the way a placeholder is: the disk's place, kept for it while it is away for a meeting. Something else guarded and plugged in shows armed instead. |
| reconnecting | The slot stays while the disk is mounted again, then the settle animation plays. A locked Time Machine disk comes back through a backup to it, which shows as backing up. |

**When a disk comes back after a meeting, the icon settles**, 1.8 s: a beat,
the slot's gaps close, the slot fills from its middle while the triangle
presses down and comes up solid with the smallest overshoot. It lands on
armed, or on the empty line if nothing is guarded. It plays once the disk
list shows the disk back (`MenuBarIconAnimator.reconnectFinished`), on the same
ticker as the eject; with Reduce Motion the slot simply turns into the state.

The triangle's base, a 1.4 pt line, is centred on a device pixel row at
whatever scale it is drawn (`LiftIcon.snappedBase`): at 8.0 pt it straddled two
rows at 1x and drew as two half-grey ones. The whole triangle moves, by at most
half a pixel, so its shape is unchanged.

While a backup runs, the bar fills to the percentage Time Machine reports, or a
short segment travels left to right while it is still sizing the job up - a bar
frozen at zero reads as a stalled backup. Both forms breathe between 55% and
100% opacity, because progress can sit on one number for minutes and a still
icon in a menu bar reads as a dead one. If the badge and the bar ever compete
at 1x, the badge wins: it is what says "Time Machine".

**A `MenuBarExtra` label is rendered to a static image, so SwiftUI's own symbol
effects never run there.** That was measured rather than assumed: a throwaway
menu bar app with `.symbolEffect(.pulse, options: .repeating)` was screenshotted
twenty times over two seconds and its icon brightness did not move by a
hundredth. So every state and every animation frame is drawn in code
(`LiftIcon`) as a template `NSImage` on a fixed 22 x 16 pt canvas: crisp at
every scale, tinted by the menu bar on light, dark, highlighted and
tinted-wallpaper bars, and never wider or taller from one state to the next.
The label stays a plain `Image`, which the menu bar never scales. VibeRes and
ClipShot draw theirs the same way.

The breathing is driven by `GuardController.backupPhase`, an integer advanced
four times a second - and only while a backup is actually running.

**When the guard ejects a disk, the icon plays a two second animation**: a beat,
then the triangle crouches as the bar drains, launches out of the frame, and
drops back with a squash and a small hop onto the state it rests in: the dashed
slot after an unmount for a meeting, the empty bar after an eject. It plays only
when a disk actually came off, unmounted for a meeting or ejected (`MenuBarIconAnimator.ejectFinished`): never for a
failed eject, a backup to a share that was only stopped, or anything shown in
the preview harness. A 30 Hz timer runs while it plays and not otherwise, a
second eject restarts it rather than stacking a second timer, and with Reduce
Motion on the icon goes straight to its state. The sleep eject does not play
it: the Mac is going to sleep.

Knowing a backup is running costs one `tmutil status` every 5 s while one is,
20 s while a guarded disk is merely attached, and nothing at all when none is.
That is a deliberate exception to the event-driven rule in the rest of the app,
and it is bounded by the thing that matters: the disk being plugged in. A
guarded network destination is always "plugged in", so ticking one keeps the
20 s poll running for as long as guarding is on.

The states are hard to review in place - the icon is 22 pt wide and some of them
only appear mid-backup or mid-eject - so the preview harness renders them all
side by side, with every tenth of a second of the eject animation:

```sh
./preview.sh icons
```

Its size is pinned by tests against `externaldrive` at 15 pt, the symbol it
replaced and the size its neighbours draw at: ink 25 to 29 px tall at 2x, the
body (triangle and bar) at least as tall as the drive, the triangle as wide,
and the line as heavy as the drive's outline. A menu bar icon that comes out
smaller than its neighbours is the regression these exist for.

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
echo 1.3 > VERSION                # and write release-notes/1.3.md
./release.sh                        # sign, notarize, staple
./make-appcast.sh build/Eject-Guard-1.3.zip
git add VERSION appcast.xml release-notes && git commit -m "Release 1.3"
git push && git tag v1.3 && git push origin v1.3
gh release create v1.3 build/Eject-Guard-1.3.zip --verify-tag \
    --title v1.3 --notes-file release-notes/1.3.md
```

Push `main` before tagging: a release created with `--target main` tags
whatever GitHub's `main` is at that moment, which is not necessarily the
commit that was built.

The notes in `release-notes/<version>.md` are embedded in the appcast as HTML,
so Sparkle's update window shows only them. Paragraphs, `- ` bullets and
backtick code are the whole format.

**The repository has to be public for updates to work.** Sparkle carries no
GitHub credentials, so on a private repository both the feed on
raw.githubusercontent.com and the release asset answer 404 and every check fails
with nothing obviously wrong at either end. Measured, not guessed: with a token
both return 200 and the published archive's EdDSA signature matches the appcast.

`sparkle.sh` pins the framework by version **and** SHA-256. An updater is the
one dependency whose compromise is arbitrary code execution, so it is never
fetched as "latest".

## Layout

```
Sources/Core/     the engine: no UI, compiled into both binaries and the tests
Sources/Icon/     the menu bar icon and its animator, compiled into the app and the tests
Sources/App/      the SwiftUI menu bar app
Sources/CLI/      the command line tool
Sources/Preview/  renders the popover to PNG so the layout can be reviewed
Resources/        en, sk, cs and de translations, copied into the bundle
Tests/            unit tests over Sources/Core and Sources/Icon
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
and `Sources/Icon` as libraries so `swift test` can reach them with `@testable`. The app and CLI are
still assembled by `build.sh` from the same sources, so the shipping binaries are
unaffected by the test setup.

The suite covers the pure half of the logic, which is where every real bug in
this project has been so far:

| Area | Why it is tested |
|---|---|
| Config decoding | A key added later once wiped every setting the user had. |
| `Disks.merge` | Identity of a disk, and whether re-keying it silently unguards it. A disk made a Time Machine destination after it was remembered was listed twice; while it is unplugged, only Time Machine's own preferences (`/Library/Preferences/com.apple.TimeMachine.plist`, undocumented, so used for matching only) link the two. A disk nobody guards, and that is not a Time Machine destination, is forgotten 30 days after it was unplugged, counted from the first pass that found it gone: `lastSeen` is written only on a rescan, so it can be weeks old the moment a disk is pulled out. |
| `Disks.guardedVolumes` | An unticked disk must never become a target. |
| `Disks.isMountedVolume` | The boot volume must never be an eject candidate. |
| `Disks.mayChangeDiskList` | Time Machine's own mounts set off rescans whose `tmutil` hung past SIGKILL; a plugged-in disk must still rescan. |
| `Sanitize.oneLine` | Untrusted titles must not forge log lines or break AppleScript. |
| `BackupStatus` | `Percent: -1` means unknown, not zero. The figure is the one the Time Machine menu shows, `(1 - FractionOfProgressBar) + FractionOfProgressBar x Percent`, and only while copying. A backup to a share is matched by destination ID; its mount point is a disk image. |
| Telling disks apart | Two disks with one name show their size, or the shortest UUID prefix that differs. A size is only stored once a disk is seen, so an entry from an older file decodes without one. |
| Forgetting a disk | Takes its tick, hidden mark and waiting reconnect with it; offered only while unplugged and not for a destination Time Machine still reports, which the next scan would bring back. |
| Network destinations | Never an eject target, never folded into a plugged-in disk by name, and an entry an older release stripped of its flag is still the same destination. |
| `Disks.connection` | Only interfaces we recognise are named. |
| Reconnecting | A volume diskutil no longer knows was unplugged; an empty mount point is attached but down. Nothing is mounted while a meeting runs or is about to start, back-to-back meetings chain, a day-old entry is dropped, and only a UUID reaches diskutil. |
| `LiftIcon` | Every state and animation frame is a template image on the fixed canvas, or the menu bar cannot tint it. Its size is anchored on `externaldrive`: an icon smaller than its neighbours was the complaint before it. Idle and armed have to differ at 1x, not only at 2x. |
| `MenuBarIconAnimator` | Plays only on a disk actually ejected or mounted again, runs no timer at rest, restarts on a burst instead of stacking timers, and respects Reduce Motion. |

The tests were checked by putting two real bugs back in: removing the hand
written config decoder, and dropping the ticked-disk filter. Both were caught.
The icon tests were checked the same way: a non-template image, a narrower
triangle, a thin bar for armed, playing on an eject that ejected nothing, and
ignoring Reduce Motion were each caught.

CI runs the tests, builds the app and CLI, and enforces two rules that are
easier to state than to remember: no shell is ever invoked, and `waitUntilExit`
is banned.

## Safety notes

- Only volumes that are **external, ejectable and directly under `/Volumes`** are
  ever considered. The boot disk cannot be reached by any code path.
- Disk images (an installer `.dmg`, a sparse bundle, a scratch image a test
  tool mounts for a moment) are never offered or remembered: there is nothing
  to unplug. DiskArbitration reports their device model as `Disk Image` and a
  device path under `IOHDIXController` or `AppleDiskImagesController`
  (measured on macOS 27 with `hdiutil attach` and `diskutil image attach`);
  the volume keys alone cannot tell one from an external disk. A volume
  DiskArbitration has lost by the time the scan asks, and that is no longer
  mounted, is skipped rather than taken for a disk. The one image offered is a
  local Time Machine destination. One remembered all the same is dropped the
  next time it is mounted, guarded or not, but its tick stays: a block-level
  copy of a real disk carries that disk's UUID.
- Disks are identified by **volume UUID**, not by name, so another volume that
  happens to share a name is not touched.
- A Time Machine backup is stopped only when it is writing to the disk being
  unmounted or ejected, or to a network destination the user ticked. A
  backup to a different destination keeps running.
- A network destination is never ejected, unmounted or linked to a volume.
- A failed unmount or eject is reported with the processes holding the
  volume, so you know not to pull the cable.
- Both target the **whole physical disk**, not just the guarded volume, which
  is what Finder's eject does. Other volumes on the same disk are unmounted
  too; if one of them is busy it fails and names the process.
- A disk unmounted for a meeting is mounted again only if it is still attached
  when the meeting ends, found by its volume UUID. When diskutil confirms an
  external whole disk, `diskutil mountDisk` brings back every volume on it;
  otherwise only that volume is mounted. After ⌘E or eject on sleep, unplug
  and replug it: an encrypted Time Machine volume unlocks from the keychain
  when the disk is reattached.
- The log names your meetings, so it is created `0600`, as is the config file.
  At 512 KB it rolls over to `.log.1` rather than being deleted, because the
  entry you want is usually the one just before the rollover.
- Eject-on-sleep is best effort. macOS gives sleep observers a short window and
  stopping a running backup alone was measured at ~11 s, so it is attempted once
  on a background queue and may not finish. It never blocks sleep.

## Build

```sh
./build.sh      # build/Eject Guard.app and build/eject-guard, ad-hoc signed
./install.sh    # build, install to /Applications and ~/.local/bin, launch
./uninstall.sh  # stop and remove, keeping config and log
```

### The app icon

`App/AppIcon.icon` is an Icon Composer document and the source of truth.
`./make-icon.sh` compiles it with `actool` into `App/Icon/Assets.car`, which
macOS 26 draws, and `App/Icon/AppIcon.icns` for macOS 14 and 15. Both outputs
are checked in, so a build does not depend on which Xcode is installed. A bare
`.icns` is not enough on macOS 26: Finder shrinks it into a grey tile.

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
`App/EjectGuard.entitlements` exists.

### Contrast

The popover renders to PNG, so contrast is measured rather than guessed. Section
headers were `.tertiary`, matching the sibling apps, which measured **2.74:1**
against the dark background - under the 4.5:1 WCAG asks for at 9pt. They are
`.secondary` now, which measures 5.91:1.

### Reviewing the UI

`MenuBarExtra` popovers cannot be opened programmatically, so a harness renders
the popover straight to PNG in both appearances:

```sh
./preview.sh          # this Mac's real disks and calendar
./preview.sh demo     # invented data, the bare popover
./preview.sh update   # the demo popover with an update ready to install
./preview.sh onboarding  # the welcome tour a fresh install opens on
./preview.sh disks    # disks sharing a name, a row's context menu, the Forget alert
./preview.sh many     # ten disks: the list scrolls, and the popover's height is printed
./preview.sh hero     # the same, open under the menu bar: docs/popover-*.png
./preview.sh icons    # every menu bar icon state
./preview.sh settings # every Settings tab at the window's real size
PREVIEW_LANG=sk ./preview.sh demo
./readme-motion.sh <dir> [dark]  # the README hero animation, GIF and MP4
```

Output lands in `build/preview/`. The published screenshot always comes from
`demo`: the plain mode shows whatever is on this Mac's calendar.

Requires macOS 14 or newer.

### Menu metrics

The action rows copy a native `NSMenu`, measured on macOS 26 with `NSMenu.size`
rather than eyeballed: a 24 pt row, an 11 pt separator (5 + 1 + 5) and 5 pt at
the bottom edge. The `MenuBarExtra` panel adds no inset of its own at the
bottom, so the numbers in `DesignTokens` are the ones on screen. VibeRes uses
the same values, and the two apps are meant to feel like one family.

### Popover motion

The popover moves the way VibeRes does, with its vocabulary (`Design.Motion`)
and helpers (`PopoverMotion.swift`), and every movement has a job:

- A disk card gives under the pointer, and its checkmark swaps in and bounces
  once when the disk becomes guarded: the click was taken.
- A row that comes and goes (a problem, a banner, Stop backup, Undo skip, the
  hint, Pause and Resume, today's meeting and the line saying there is none)
  fades in only after the rows around it have made room, and fades out before
  they close up, so no text ever crosses another.
- Time Machine's percentage and the minutes to the meeting roll their digits.
  The countdown ticks with a `TimelineView`: before it, an open popover kept
  the minute it was opened on.
- The Ejecting… and Stopping backup… rows pulse their icon while it lasts.

Under Reduce Motion the rows jump and fade, the checkmark crossfades without
the bounce, the digits crossfade, a press dims instead of shrinking, and
nothing pulses. The welcome tour fades between steps instead of sliding.

Text whose digits roll is drawn without the material's vibrancy while it rolls,
so `.secondary` turns near black for most of a second, every two seconds while
a backup runs. Rolling lines use `Design.Palette.cardSubtitle`, the plain label
colour, which looks the same at rest. Rolling words only scramble them, so the
status line rolls only while it shows a percentage.

`preview.sh` and the README animation render end states only: ImageRenderer
does not animate. The motion was checked by screen recording the popover views
on demo state in a plain window, frame by frame, in both appearances and with
Reduce Motion, and the disk card in the real popover.

## The rename

Until 1.3 the app was TM Eject Guard. Everything a person sees is now Eject
Guard, including the repository, which GitHub redirects from the old name.

What deliberately did not change:

- **The bundle identifier `sk.moravcik.tmejectguard`.** Sparkle, calendar
  permission and launch at login all key on it. Changing it would make the
  update a different app.
- **The notarytool profile default in `release.sh`.** It names a keychain
  item, not the product.
- **The Swift module names** (`TMEjectGuardCore`), which nobody outside the
  code sees.

Installed copies from before 1.3 still ask the old feed URL, which only
works while the GitHub redirect does. Never create a new repository called
`tm-eject-guard` under this account: it would take over the redirect and cut
those installs off. The settings folder moves on first launch
(`ConfigStore.migrate`), and the old log is left where it was.

