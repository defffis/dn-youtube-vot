# Recording and exporting a log

[Русский — основной язык](LOGGING.md) · **English**

1. Open YouTube Settings → VOT → **Настройки VOT** → **Диагностика и запись лога**.
2. Tap **Начать запись лога** (Start recording), then close settings.
3. Reproduce the problem. For reloads, begin recording before opening the video page.
4. Return to the submenu → **Остановить запись** → **Экспортировать лог файлом**.
5. Choose Save to Files in the share sheet and attach the JSONL file to your report.

Recording continues outside the menu while the YouTube process runs. It cannot run
while iOS suspends or terminates the process. Limits: 15 minutes / 12 MB. You may
export a consistent snapshot without stopping. A new recording cleans older files
and exports, retaining the previous and current recording. Save important files elsewhere first.

UTF-8 JSONL: each line contains `t` (seconds since start), `event` and `fields`.
Samples are recorded around 5 Hz. Events include API/HTTP/status without payloads
or headers, downloads, prepare/decode/play/pause/seek, automatic decisions,
clock/volume/route, interruptions, cache cleanup and native player activation/state/reload.
A cancelled download has `outcome: cancelled` and is not a network failure.
Network trace is labeled with the last requested video ID, which can differ from
the current excluded or closed video.

The recorder does not save or transmit tokens, account details, cookies, media URLs,
Bluetooth device names or audio. **Video IDs are included.** Review logs before
posting publicly and remove anything you do not want to share. Never add tokens or
signed URLs manually. Average/peak dBFS indicates decoded audio, but alone does not
prove audibility on the current output device.

Since 0.4.1-test.1, `player_candidate_ignored` identifies rejected feed preview/Shorts
contexts once per object. Button `visibility` reports `top-visible`, `top-hidden`
or `reference fallback`, separately from the hierarchy's effective alpha.

Since 0.4.2-test.1, samples also include `preparation` (none/service/download),
`download_fraction` (-1 for unknown size) and `service_eta_seconds` (-1 for unknown).
ETA belongs to the last server response; it is not a guaranteed countdown or completion percentage.
