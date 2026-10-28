# Mixer architecture

The package has three Swift modules and a native DSP target:

```text
mixerMac (SwiftUI and application coordination)
  ├── MixerCore (channel, bus and parameter state)
  └── MixerAudio (capture, playback and analysis)
        ├── MixerCore
        └── mixerMacDSP (native FIFO and sample processing)
```

## MixerCore

`Mixer` owns source-independent `Channel` instances and one master `MixBus`.
It manages channel membership and the mute/solo policy. A channel owns an
`Equalizer`, volume and pan. The master owns an `Equalizer`, pan and width.
The equalizers share the same band and parameter implementation.
Membership changes go through `addChannel`, `removeChannel` or `replaceChannels`;
the application uses replacement when discovery changes. These methods also
attach and detach channel subscriptions so removed objects stop notifying the mixer.

`Parameter` owns its value, range, unit and neutral value. `setValue` clamps
the value and publishes a change after the value has been updated. `reset`
uses the neutral value. Controls can hold the same parameter instance.

`ChannelSettings` and `BusEQSettings` are serializable snapshots. Applying a
snapshot updates the existing parameters, preserves their identities and emits
one owner change after the complete update. Their existing JSON keys and legacy
decoding are retained so saved user settings continue to load.
`Equalizer.updateSettings`, `Channel.updateSettings` and `MixBus.updateSettings`
provide this complete-update boundary for numeric and multi-field editing.

The core imports Foundation and Combine for serialization, numeric helpers and
change notifications. It does not import SwiftUI, AppKit, Core Audio or AVFAudio,
create audio objects, discover applications, persist preferences or open devices.
Core objects are confined to the main actor; they are not render-callback objects.

## MixerAudio

`AppAudioChannel` adapts an application's processes to a core `Channel`. It owns
capture/playback resources, channel metering and the existing channel preference
storage. Its settings property delegates to the core channel; it does not store a
second copy. Its change subscription saves settings and invalidates its observable
presentation state.
`AppAudioChannel.apply` is the coordinator's playback entry point; the UI cannot
access its processor or directly assign its processing state.

`AppChannelProcessor`, `SystemAudioCapture` and `DriverAudioBridge` keep their
existing DSP graph, capture and buffering behavior. `AudioEQ` translates core
settings to Apple audio units. Spectrum and waveform analysis also live here.

This step introduces a logical master bus that owns the master parameters.
Playback still uses the existing per-application engines and repeated master EQ.
A shared output engine and editable source/port routing are separate changes;
this refactor does not change latency or resampling.

## Application and UI

`MixerConsoleModel` coordinates discovery, output selection, start/stop, recovery
and the audio adapters. It registers each adapter's core channel with its `Mixer`.
A core change triggers master preference persistence when needed and playback
application for the current channels. UI visibility decisions stay in this module.

The console uses `Parameter.binding` to connect knobs and faders to their core
parameters. Detail editors write settings snapshots to those same owners. Views
do not call playback `apply` when settings change. Their local change handlers
only refresh presentation data such as an EQ response plot.

## Headless verification

```sh
swift build --target MixerCore
./script/test.sh --filter MixerCoreTests
./script/test.sh
swift build -c release
```

Core tests exercise parameter ownership, complete-update notifications, channel
independence, mute/solo, membership, legacy decoding and subscription lifetime.
Integration tests verify that parameters and detail snapshots reach persistence
and existing audio units without a mounted view or an explicit UI `apply` call.
Offline PCM and recovery tests continue to cover the existing audio behavior.

No command above launches the GUI. Offline audio-unit tests still require access
to macOS Audio Unit services. Hardware routing, device transitions and visual
behavior need separate verification on the running application.
