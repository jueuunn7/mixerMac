# Contributing

Small, focused changes are welcome. Describe the problem, the resulting behavior, and how you checked the change.

## Local checks

Use macOS 14.2 or later with a Swift 6 toolchain:

```sh
swift build -c release
./script/test.sh
./script/test_audio_bridge.sh
```

For interface changes, launch the app with `./script/build_and_run.sh --verify` and check the console and Detail views at their supported window sizes. Include before-and-after screenshots when useful.

For audio changes, check the neutral settings as well as the affected controls. Preserve channel ordering and silence behavior, avoid allocations and blocking work in audio callbacks, and keep visualization work away from the real-time processing path. Add tests for meaningful changes in DSP or persisted settings.

The optional driver has a separate build and test path, documented in [Driver/README.md](Driver/README.md). Installing it is not required for application development.

## Reporting a problem

Include the macOS version, hardware, output device and sample rate, steps to reproduce, expected behavior, and actual behavior. For audio issues, mention the source application, EQ and stereo settings, and whether the problem occurs with POWER off. Remove personal data from logs and screenshots before sharing them.

Keep generated builds, local settings, recordings, and scratch files out of source changes. Preserve third-party license notices.
