# Translation button and loading

[Русский — основной язык](PLAYER_CONTROLS.md) · **English**

Version 0.4.2 uses one outline waveform without a filled disk. Gray means disabled;
white means enabled, including while the video is paused. Tap to disable or cancel
preparation; hold for quick settings. The icon no longer displays an elapsed timer.

The button sits next to native CC/Cast/menu controls. Its row size follows a
neighboring native control and its glyph center aligns with the neighbor's icon.
Its own hit region expands to 44×44 points; parent hit testing can still constrain it.
Fallback geometry is 32×32. Placement is shown in user screenshots of 0.4.2-test.1;
other devices and display modes still need coverage in the [device checklist, Russian](DEVICE_TEST.md).

## Indicator states

| Stage | Appearance | Data used |
|---|---|---|
| Request / translation generation / source retrieval | Thin rotating arc | Preparation is active; no invented percentage |
| Downloading finished audio, unknown size | Same rotating arc | Waiting for a network response/file |
| Downloading finished audio, known size | Progress ring | Received bytes / expected file size |
| File validated and audio prepared | White outline waveform | Local voice-over is ready |
| Disabled / cancelled / failed | Gray outline waveform | No preparation is running |

The download ring does not reach 100% before validation and audio preparation
succeed. Cache hits skip downloading. A partial translation does not mean the full
video is ready; existing partial-coverage behavior remains in effect.

## Service estimate

A protobuf response may include optional int32 `remainingTime` in field 5:
an approximate wait in seconds. It describes the last response and can be missing,
repeat, increase or become stale. It is neither completion percentage nor a deadline.
ETA remains in the status and does not drive a translation-generation progress ring.

Absent, zero, negative or out-of-range values mean unknown time. The polling interval
is never shown as ETA. Expiry of an estimate does not mean preparation has completed.

## Animation and accessibility

The white arc has rounded ends and no colored background. Reduce Motion uses a
static arc. Rotation stops when the button or an ancestor is hidden, the button has
no window, or the app is inactive. VoiceOver announces the state and actual download
percentage when known, while retaining the cancellation action description.
Hiding player controls also hides the indicator. [Logging](LOGGING.en.md).
