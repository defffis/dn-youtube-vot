# Video page or player reloads

[Русский — основной язык](TROUBLESHOOTING.md) · **English**

## Findings from the 0.3.1 log

The player returned to loading states before the first VOT audio play command.
A similar transition occurred on an excluded Russian video, with translation off
and no VOT audio object. Starting the voice-over is therefore not required for
this behavior. That recording contained no network/decode failures; some requests
were waiting for preparation (`status 6 → 2`) rather than failing.

Player-state samples do not prove that the entire watch page reloaded. The old log
lacked instance IDs, reload reasons and player lifecycle events. It cannot establish
whether YouTube, another mod, DNVOT UI integration or their interaction caused it.
No initiating YouTube reload, navigation, play or pause calls were found in DNVOT.
Its own AVAudioPlayer controls and original-volume updates are separate from native observers.

## Changes introduced in 0.4.0

Automatic translation waits for steady video-clock movement. Diagnostics record
`native_player_appeared`, `native_video_activation`, `native_player_reload` when a
compatible method exists, `player_attachment`, `native_state_transition` and
`original_volume_command`. Instance identifiers are local class counters, without
memory addresses or context descriptions. Observers preserve the original method
call; DNVOT does not request a YouTube reload.

This reduces early intervention and improves diagnostics. It is not proof that
the earlier reload issue was fixed. Positive feedback on 0.4.2-test.1 does not
replace the controlled comparison below.

## Compare the patch with YouTube and other mods

Use the same IPA, account, network, other mod settings and videos. Change only:

1. **DNVOT installed, automatic translation off.** Start recording before opening
   the problem video. Do not tap VOT. Wait for the reload.
2. **DNVOT installed, automatic translation on.** Repeat and export a second log.
3. **The same IPA without DNVOT.** Remove only the DNVOT library and repeat the same videos.

If step 3 reproduces it, DNVOT is not required for the issue. If it happens only
with DNVOT installed, the patch or its interaction with other code is implicated,
even with automatic translation off. If it occurs only with automatic translation,
compare native activation, automatic decision, download, prepare, play and reload events.
Keep app data consistent where the installer permits: clearing data itself changes the experiment.

Include [logs](LOGGING.en.md), versions and exact steps. Review files before posting:
they contain watched video IDs. Do not publish passwords, OAuth, cookies, signed URLs
or personal crash-report fields.
