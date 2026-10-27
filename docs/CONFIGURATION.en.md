# VOT settings

[Русский — основной язык](CONFIGURATION.md) · **English**

Full settings: YouTube → Settings → **VOT · Перевод видео** → **Настройки VOT**.
Quick settings: hold the player icon or select VOT in the gear menu. Quick settings
contain only languages, volumes and timing offset. Use the player button to toggle translation.
The app's settings labels remain Russian.

## Audio and languages

Original and translation volumes are independent. A positive offset plays the
voice-over earlier; a negative offset plays it later, within ±5 seconds.
The local audio player supports 0.5–2× speed; translation pauses outside this range.
Pause/seek synchronization follows the video clock. Ads, Cast or AirPlay may block
translation temporarily. Not every output route has been tested.

## Automatic translation

Enable **Автоматически переводить все видео** (Automatically translate all videos).
The request begins after approximately one second of steady video-clock advancement,
rather than as soon as a video ID appears. This reduces early intervention and
unnecessary requests when switching quickly. Manual activation bypasses this wait.

Choose excluded source languages under **Не переводить автоматически с этих языков**.
Detection uses the selected audio track, then automatic captions; an explicitly
selected source language is a fallback hint. `en-US` and `en.4` normalize to `en`.
If the language remains unknown after waiting for metadata and exclusions are set,
automatic translation is skipped with an explanation. The manual button bypasses
exclusions. Turning translation off does not trigger it again every 200 ms:
the automatic decision is made once per video.

## Yandex account and lively voices

**Standard translation works without signing in.** Sign-in is needed to request
lively voices directly from Yandex. The refresh button ↻, refresh row and pull-down
gesture check the profile again. A temporary network error does not erase saved sign-in.

Select **Войти через Яндекс**, sign in on Yandex's page, copy the displayed code,
close the browser, select **Ввести код подтверждения** and paste the code.
OAuth with PKCE is used; the token is stored in Keychain. Enter your password only
on Yandex's website. Some signing configurations may prevent Keychain storage.
**Выйти из VOT** removes only this patch's token. Do not add codes/tokens to issues or logs.

## Custom Worker and proxy routes

Under **Серверы и проксирование**, enter your VOT Worker's HTTPS base address,
then select a route. A bare domain gets HTTPS automatically. User credentials,
query strings and fragments in the base address are unsupported.

| Mode | Translation API | Finished Yandex audio |
|---|---|---|
| Direct / Напрямую | Yandex or a custom compatible API | Original URL |
| API through Worker / API через Worker | Worker | Original URL |
| API + audio through Worker / API + озвучка через Worker | Worker | Worker's `/video-translation/audio-proxy/` |

Modern Workers use a binary request body and `X-VOT-Headers` containing base64 JSON
headers. Legacy mode is selected separately and uses JSON `{headers, body}`;
payloads are limited to 8 MB to reduce memory use. Prefer modern mode for large
source audio. Not every server supports both protocols and the audio-proxy endpoint.

`vot-worker.eu.cc` returned successful API responses and audio in the user's 0.3.1
log. Its availability may change; it is not a service guaranteed by this project.
API + audio mode rewrites known Yandex `/tts/prod/` URLs; unknown URL patterns are left intact.

The source-media proxy is a separate optional setting, using
`/v1/proxy/video.mp4?format=base64&force=true&url=…`. If configured, it applies
independently of Worker mode, only when a source-audio URL is available. It does
not itself fix missing URLs or SABR. YouTube video delivery and the system VPN are unchanged.

Video links/audio go to your selected servers. OAuth is sent only directly to
`api.browser.yandex.ru`; Worker and third-party API routes use the standard voice.
Your lively-voice preference takes effect again when returning to direct Yandex mode.

## Cache and maintenance

Complete audio files are cached up to 128 MB. Automatic cleanup is enabled:
24 hours from saving; playback does not renew expiry. Checks run at startup/foreground,
every minute while the process runs and during cache operations. The current file
is protected until playback stops. If iOS suspends the app, cleanup resumes on the next launch/return.

**Очистить кеш переводов** stops translation and removes downloaded tracks while
keeping sign-in and preferences. **Сбросить все настройки** also restores defaults
and removes the Yandex token, after an in-app confirmation. Logs are kept separately.

**Диагностика и запись лога** contains copy diagnostics and start/stop/export recording.
See the [logging guide](LOGGING.en.md).
