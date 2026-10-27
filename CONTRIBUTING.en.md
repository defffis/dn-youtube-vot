# Contributing

[Русский — основной язык](CONTRIBUTING.md) · **English**

Read [STATUS.md](STATUS.md) and [ROADMAP.md](ROADMAP.md), currently in Russian.
Distinguish implementation, static checks, live service requests and real iPhone tests.

1. Run `bash build.sh` on Linux after setting up `tools/setup_toolchain.py`.
2. Run `bash test.sh`; protobuf parity requires `protobuf==6.33.0`.
3. Check protocol changes against pinned sources and live responses.
4. Check adapter changes against signatures in the targeted YouTube version.
5. Add reproducible tests for synchronization fixes.
6. Record device test results with iOS/YouTube versions, a public video link and steps.

Do not commit IPA files, SDKs, compiled libraries, certificates, provisioning profiles,
tokens, cookies, session secrets or signed media URLs. Publish builds in GitHub Releases.
Preserve upstream license notices.
