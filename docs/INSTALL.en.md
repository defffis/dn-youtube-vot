# Installation and updates

[Русский — основной язык](INSTALL.md) · **English**

## Requirements

- ARM64 iPhone with iOS 16 or later. Earlier user-tested configuration:
  YouTube 21.40.5 / iOS 27.0.1. The latest prerelease also received positive user feedback.
- A working YouTube IPA that your installation tool can sign and install.
- GBox or another tool supporting dylib injection and signing of embedded code.
- `DNYouTubeVOT.dylib` from the [latest release](https://github.com/defffis/dn-youtube-vot/releases/latest).

This installation method does not require a Mac or jailbreak. The repository provides
the patch and source code, not a YouTube IPA, Apple SDK or other developers' mods.
Signing steps depend on your installation tool and certificate.

## First installation with GBox

1. Save a copy of your working original IPA and import it into GBox.
2. Open the IPA preparation/signing options and the library injection list.
3. Remove any old `DNYouTubeVOT.dylib` and `DNYouTubeVOTProbe.dylib` entries.
   Other patches are not DNVOT dependencies. Keep the original combination for comparison.
4. Add **one** current `DNYouTubeVOT.dylib`. Do not inject a ZIP or source archive:
   select the actual `.dylib` file.
5. Sign the app and every embedded library, then install the resulting IPA.
6. Launch YouTube, open a normal video and tap the video to reveal the controls.
   A waveform icon should appear in the top row.
7. Open YouTube Settings → **VOT · Перевод видео** → **Настройки VOT**.

If the app cannot launch, first verify that the same IPA works without DNVOT.
If it does, report the versions and an iOS `.ips` crash report after removing personal data.

## First translation test

The settings interface remains Russian; the labels below match the app.

1. In VOT settings, select **Напрямую** (Direct), API `https://api.browser.yandex.ru`.
2. Disable lively voices. Standard translation does not require sign-in.
3. Set the source language to automatic, target to Russian, translation volume to
   100% and original volume to 18%.
4. Open a normal foreign-language spoken video at 1× speed.
5. Tap VOT. A rotating arc means preparation; a progress ring means the finished
   audio is downloading with a known file size. You can continue watching.
6. Once ready, the voice-over starts at the current video position. Tap the active
   icon to turn it off and restore the original volume.
7. Hold the icon or select VOT in the player's gear menu for languages, volumes and offset.

In 0.4.2 the icon is an outline waveform without a filled disk: gray means disabled;
white means enabled, including while paused. Preparation replaces the waveform with
a thin arc. There is no elapsed timer in the icon. A server time estimate, when
available, stays in the status and may be inaccurate. Versions before 0.4.2 used
an elapsed timer and different circular icon shapes. [Details](PLAYER_CONTROLS.en.md).

## Updating

Prepare your working source IPA again, replacing the old DNVOT library with the new
one. Do not inject multiple versions. Settings normally remain if the app container
is retained. Removing the app or changing its signature can affect stored data and
Keychain access. Restore your preferences manually if necessary.

## Configuration and diagnostics

- [Account, Worker, volumes, automatic translation and cache](CONFIGURATION.en.md).
- [Player reloads and comparison without the patch](TROUBLESHOOTING.en.md).
- [Recording and exporting JSONL logs](LOGGING.en.md).
- [Device test checklist, Russian](DEVICE_TEST.md).
