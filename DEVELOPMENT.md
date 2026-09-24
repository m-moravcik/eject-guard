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

## The menu bar icon

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
./preview.sh icons
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
./build.sh      # build/Eject Guard.app and build/eject-guard, ad-hoc signed
./install.sh    # build, install to /Applications and ~/bin, launch
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
./preview.sh hero     # the same, open under the menu bar: docs/popover-*.png
./preview.sh icons    # every menu bar icon state
PREVIEW_LANG=sk ./preview.sh demo
```

Output lands in `build/preview/`. The published screenshot always comes from
`demo`: the plain mode shows whatever is on this Mac's calendar.

Requires macOS 14 or newer.

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

