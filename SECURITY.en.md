# Privacy and bug reports

[Русский — основной язык](SECURITY.md) · **English**

The patch sends the video link and, when required, source audio to the selected API,
Worker or media proxy. Translation is performed by that service, rather than through
local speech recognition. Choose third-party servers you trust. OAuth is stored in
Keychain and sent only directly to official Yandex endpoints.

JSONL logs contain video IDs and playback state. The recorder omits OAuth, cookies,
account details, signed media URLs and audio data. Review logs and crash reports
before opening public issues. Do not publish passwords, tokens, certificates or
provisioning profiles. Resetting settings removes VOT sign-in; logs are stored separately from cache.

Public protocol HMAC constants and upstream OAuth client IDs in source code are not
user tokens. See [NOTICE](NOTICE.md) for sources and licenses. Report bugs with
sanitized steps and a minimal example. If an example requires a secret, create a
secret-free reproduction first; do not paste the secret into an issue.
Repository visibility is managed separately by the owner.
