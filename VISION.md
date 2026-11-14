# Vision

`Eject Guard` exists so that a mounted external disk is never pulled from a Mac mid-write, least of all mid-backup.
It serves one person with a laptop, a disk or network Time Machine destination on the desk, and a calendar full of meetings.
It turns that calendar into one timed, reversible action: take the guarded disks down safely just before a meeting, and put them back if nobody unplugged them.
It owns exactly one thing: the minutes between "I am about to leave the desk" and "the cable is out".

## Only what the user ticked

The guard acts only on external, ejectable disks and Time Machine destinations the user ticked.
Disks are recognised by volume UUID, never by name.
A new disk is listed, not guarded: the tick is always the user's own act, never a default they have to undo.
The startup disk, disk images and plain network shares are unreachable by any code path, not merely hidden in the UI.
A backup to a destination the user did not tick is stopped or started only on an explicit request.

## A wrong guess costs nothing

The guard cannot know whether the user will actually leave, so it does not guess from location, network, power source or meeting links.
It makes the wrong guess cheap instead: before a meeting it unmounts rather than ejects, and when the meeting ends it reconnects the disk and resumes the backup it stopped.
A meeting is a timed event with other attendees that the user has not declined; blocks such as Focus or Lunch never trigger it.
Acting without asking is the default, because the user who forgets is the one it protects; an opt-in mode that asks first is welcome, never the default.
Every automatic action has a manual escape: skip one meeting, pause, eject now.
Users who want other triggers, such as the end of the workday, wire them up themselves through the CLI, or through Shortcuts actions, which are welcome; the app does not own those triggers.

## Honest about what happened

When an unmount or eject fails, the user is told, with the app holding the disk named, so they know not to pull the cable.
The guard never forces an unmount on its own, because cutting off a write in progress is the damage it exists to prevent.
When macOS refuses something for a reason the user can fix, such as missing Full Disk Access, the message names that reason and opens the place to fix it.
README, release notes, commit messages and logs state what was measured or done, and say so when something was only inferred.
Replaced installs go to the Trash, never straight to deletion.

## Quiet, local and native

Nothing is polled: the app computes the one moment it must act, arms one timer, and wakes only when a disk, the calendar, sleep or a setting changes.
Meetings come from whatever calendars macOS Calendar already syncs, Microsoft 365, Exchange and Google included, read locally through EventKit.
The app never signs in to a calendar service itself, and its only network traffic is the update check.
The log names meetings, so it and the config are readable by the user alone, and public screenshots are rendered from invented data.
Every child process has a timeout, and the logic that decides is kept pure and tested, because that is where the real bugs here have lived.
It is a small native menu bar app that looks and moves like its sibling VibeRes and a native macOS menu, in English, Slovak, Czech, German, Spanish and French.

## Scope

Eject Guard is not a backup tool, not a Time Machine replacement and not a general disk or mount manager.
It touches Time Machine only where a backup stands between the user and a safe unplug: stopping it, resuming what it stopped, showing its progress, and stopping or starting it on request.
It never changes when Time Machine backs up on its own; a disk that comes back after being ejected or unplugged waits for Time Machine's own schedule.
It is not a calendar client and not a meeting assistant.
It ships free and MIT-licensed with no paid tier, outside the Mac App Store, signed with an Apple Developer ID, notarized and updated through Sparkle.

A change aligns when it makes an unplugged disk safer, makes an unneeded unmount cheaper to undo, or tells the user more precisely what the guard did and why.
A change should be resisted when it acts on a disk the user did not tick, guesses intent from signals beyond the calendar, forces an unmount on its own, sends anything off the Mac besides the update check, or schedules Time Machine beyond what a safe unplug needs.
