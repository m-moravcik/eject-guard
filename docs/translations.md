# Translations

Eject Guard speaks English, Slovak, Czech, German, Spanish and French and
follows the system language, falling back to English.

## Where they live

- `Resources/<lang>.lproj/Localizable.strings`: the interface, the
  notifications and the Shortcuts actions, keyed explicitly (`footer.ejectNow`).
  The English text also sits in the source as the fallback.
- `Resources/<lang>.lproj/Localizable.stringsdict`: plurals.
- `Resources/<lang>.lproj/InfoPlist.strings`: the Calendar permission text
  macOS shows before the app has any interface.

The log and the command line tool stay English: their output is grepped and
pasted into issues.

## Review status

| Language | Status | Reviewed by | Date |
|---|---|---|---|
| en | Source | | |
| sk | Shipped since 1.2, reviewer not recorded | | |
| cs | Shipped since 1.2, reviewer not recorded | | |
| de | Shipped since 1.2, reviewer not recorded | | |
| es | Machine-assisted draft, awaiting a native reader | | |
| fr | Machine-assisted draft, awaiting a native reader | | |

Fill in the reviewer and date when a native speaker has read a language through
in the running app.

## Conventions

- Informal address in sk, cs, de and es; `vous` in fr.
- Product names, `eject-guard`, its flags and key symbols such as ⌘E stay as they
  are.
- System terms use the wording macOS itself uses in that language: menu bar,
  Trash, Settings, Full Disk Access, Focus, Time Machine.
- A guarded disk is one the user ticked: strážený, hlídaný, überwacht, vigilado,
  surveillé.
- Non-breaking space before `: ? !` and inside guillemets in French.
- Quotation marks per language; no em dash anywhere.
- One ellipsis character `…`, never three dots.

## Checks

`swift test` runs `LocalizationTests`, which fails when:

1. a key the source asks for (`Loc.t` or `LocalizedStringResource`) is missing
   in any language, or a language carries a key nothing uses;
2. a translation is empty;
3. a translation's format specifiers differ from English;
4. a plural defines other keys or arguments than English, Slovak or Czech lack
   the "few" form, or Spanish or French lack one of "one", "many", "other".

Render the popover, the Settings tabs and the tour in a language with
`PREVIEW_LANG=fr ./preview.sh demo` (and `settings`, `onboarding`) and check for
truncation at 300 pt and 470 pt.
