# Optional virtual audio driver

mixerMacAudio is an experimental Core Audio Audio Server Plug-in. It exposes a virtual stereo input/output device and loops output audio back to its input through a timestamped ring buffer.

The main mixerMac console uses Core Audio process taps and does not require this driver. Building or running the application does not install it, and the console does not provide driver routing controls.

## Implementation

- Stereo Float32 audio at 44.1 or 48 kHz.
- A 2,048-frame loopback delay.
- Silence for missing or stale frames.
- Input/output volume and mute controls.
- Output from multiple clients is mixed by HAL before the driver receives it.

The implementation derives from Apple's Audio Server Plug-in sample. Its original MIT notice is preserved in [LICENSE.txt](LICENSE.txt).

## Build and test

From the repository root, on macOS with Apple Command Line Tools or Xcode installed:

```sh
./script/build_driver.sh
```

This creates `outputs/mixerMacAudio.driver` for arm64 and x86_64, applies an ad hoc signature, validates the bundle, and runs the native driver and audio bridge tests with AddressSanitizer and UndefinedBehaviorSanitizer. It does not install the driver.

To create a local installer package:

```sh
./script/package_driver.sh
```

The package is written to `outputs/mixerMacAudio.pkg`, with these instructions copied to `outputs/DRIVER_INSTALL.md`. The package is a development artifact and is not notarized.

## Installation and removal

Open the generated installer package and follow the administrator authorization prompts. It installs the bundle at `/Library/Audio/Plug-Ins/HAL/mixerMacAudio.driver`. Restart macOS to load the device, then select it explicitly in the audio software you are testing.

To remove it, first select a physical output device in your audio settings. Remove only `/Library/Audio/Plug-Ins/HAL/mixerMacAudio.driver` with administrator authorization and restart macOS.

Synthetic tests do not cover every hardware setup, device transition, or long-running session. Keep this optional driver separate from the application mixer when investigating routing issues.
