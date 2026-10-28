# Mixer architecture

The production app uses a shared audio graph and one output engine. The core
contains no EQ band count, application process, audio device or console widget.

```text
mixerMac                       SwiftUI, bindings and window visibility
  └─ MixerSession              discovery, console preferences, recovery and meters
       ├─ MixerStandardNodes   standard console preset and legacy settings codecs
       │    └─ MixerCore       parameters, nodes, chains, membership, graph, snapshots
       └─ AudioGraphPlayback   source lifetime and output transitions
            ├─ AudioSourceRegistry      new input implementations
            ├─ AudioGraphRenderer       serial composition, fan-in and fan-out
            └─ AudioProcessorRegistry   new effect implementations
                 └─ Apple audio units / mixerMacDSP
```

`MixerCore` imports only Foundation and Combine. Its state objects run on the
main actor. The realtime callbacks never read those objects or use Combine.
`MixerAudio` implements the macOS backend; `MixerStandardNodes` supplies the
existing ten-band console as a preset. Both are outside the generic core.

## Shared policy and inheritance

`Parameter.setValue` and `reset` are final. Clamping, finite-value fallback,
stepping and notifications are implemented once. A knob, slider and numeric
editor hold the same parameter instance. A parameter subclass supplies its
range, unit, neutral value and step, rather than overriding mutation policy.

`MixerNode` owns its parameters and children. Its final mutation methods implement
revision tracking, nested update batching, reset and change propagation.
`ProcessingChain` supplies serial composition. `Channel` adds common mute/solo
parameters; `MixBus` adds no concrete effect. `Channel.audibleIDs` is the single
mute/solo policy used by both the model and the audio renderer. The renderer
passes the channels reachable from live inputs so an offline solo does not
silence an unrelated live source.

`ConsoleChannel` and `ConsoleBus` compose standard EQ, gain, pan, volume and width
nodes. They retain typed references for the existing console controls and protect
those required stages from removal. Additional stages may be inserted or reordered.
A bare `Channel` or `MixBus` has no required preset stages. EQ-specific ranges,
band counts and legacy JSON belong to `MixerStandardNodes`, not to core classes.

`Mixer<Master>` owns a master bus supplied by its caller and derives channel
membership from its graph, so direct graph edits cannot leave a stale second list.
Membership changes add default channel-to-master routes for new channels and
preserve manually configured existing routes. The graph itself validates IDs,
ports, channel/signal compatibility, ownership and acyclic connections before
publishing changes. Rejected edits leave its topology and revision unchanged.

## Extension contract

A new effect consists of a `MixerNode` subclass and an `AudioProcessor` subclass.
The model registers parameters and ports with its base initializer. The processor
supplies native nodes and named endpoints, then overrides `applyParameters` for
its DSP-specific assignments. Register its type ID with `NodeRegistry` for saved
state and with `AudioProcessorRegistry` for execution at the composition boundary.
There is no effect-type switch in the core or renderer. Existing implementations
are not edited when another implementation is registered.

A new input consists of a model and an `AudioSource` subclass, registered in
`AudioSourceRegistry`. Bind its output to a graph input with `AudioSourceBinding`.
The final `prepare`, `activate`, `synchronize` and `stop` methods own the lifecycle;
subclasses override resource primitives. Preparation failure releases partially
created resources. Activation happens only after the output engine starts, so
application capture is muted only after replacement playback is ready. Callers
use lifecycle entry points; Swift has no protected access modifier for override
hooks exposed to another module.

`AudioOutput` provides the output engine and the device-specific start/stop
operations. `DeviceAudioOutput` selects a real Core Audio output. Tests supply an
offline output with the same renderer and source lifecycle; no GUI or audio
hardware is required for those tests.

`Tests/ExtensionFixtures` imports only the core. `Tests/AudioExtensionFixtures`
defines a new input, effect and processor in another module. Contract tests use
these modules to exercise inherited policy, source failures, live stage insertion,
parameter application, native-rate conversion and rendered routing branches.

## Runtime and resource ownership

`MixerConsoleModel` is a thin visibility adapter over `MixerSession`. The session
owns application discovery, output choice, run restoration, persistence and error
presentation. It does not construct a hardcoded per-application DSP graph.
`AppAudioChannel` adapts a discovered application to its `ConsoleChannel`, passive
analysis and meters. It borrows the active source from playback.

`AudioGraphPlayback` owns active sources and the output transition. A failed new
source is cleaned up before touching the running engine. Failed graph validation
retains the previous renderer and taps. Existing mute/solo and parameter changes
continue to apply to that retained renderer while the topology error is reported. Source activation failure removes the
candidate source and restores the existing inputs when the output remains
available. An unrecoverable output failure stops owned sources and restores their
native application playback.

`AudioGraphRenderer` interprets serial composites and explicit root connections.
Every processor input receives a summing mixer. Outputs connect to all requested
destinations in one operation, preserving fan-out. The master processes the actual
sum once. Parameter edits reuse adapters; topology edits rebuild the native graph
while the output is stopped and retain existing capture sources. Rebuilds can
briefly interrupt output; seamless topology switching is not claimed.

The renderer owns its native nodes and metering taps. Channel meters tap the EQ
chain output before the fader. Master analysis retains its existing separate
system capture and error isolation. The stereo audio unit moves balance/width
out of the source FIFO into explicit effect stages; its callback uses a
preallocated buffer and C atomic controls. The source FIFO retains clock-drift
buffering, with neutral stereo controls in this path.

## Persistence and unavailable extensions

`NodeSnapshot` stores type, structure, ports, configuration/version, parameter
values, bypass and children. `GraphSnapshot` adds connections and a document
version. `NodeRegistry` builds a detached candidate tree and applies shared
parameter rules before committing a graph replacement. Required preset stages
retain their object identities. Missing newly introduced parameters use their
defaults; unknown saved parameter keys require an explicit migration.

Immutable nonnumeric configuration is encoded and semantically validated by the
node. Its factory decodes that configuration before construction. Validation is
also performed on preset-owned children, avoiding silently ignored child config.
Use a deterministic encoding when snapshot byte equality is meaningful.

The session saves the complete graph in `mixer.graph.v1`. It retains configured
channels and routes when an application disappears; source bindings are transient
and recreated by discovery. Standalone application adapters also save node trees
under `channel.nodes.<id>`. Existing flat channel/master settings remain readable
for migration and the existing numeric editors. Missing extensions or unsupported
documents are surfaced and the saved graph is preserved, rather than overwritten
with a guessed replacement. Device selection and running intent retain their
existing stable-UID and restart behavior.

## Boundaries

The generic graph can describe other channel counts and signal types. The current
macOS renderer supports stereo float audio and rejects unsupported ports before
replacing the native graph. Another backend or richer hardware I/O mapping can
consume the same graph contract; that backend still needs implementation and tests.
The current app discovers application inputs. A future device-source picker or
canvas editor is a new presentation/composition feature, not implemented here.

A compatible base-policy change propagates through inherited final methods.
Incompatible contract meanings, configuration schemas or DSP formats require
explicit versioning/migration; no architecture can guarantee all semantic changes
will preserve arbitrary existing extensions.

## Verification

Use `script/test.sh` for the headless Swift suites and `swift build -c release`
for the release build. Do not use `build_and_run.sh` for headless work: it launches
the app. The core can be built separately with `swift build --target MixerCore`.
Apple audio units require a test process outside the agent's filesystem sandbox,
even in offline rendering mode. Tests cover the previous bugs and standard DSP
behavior through the production graph. Hardware tap permissions, output devices
and visible UI behavior still require a separate manual check.

See `extensibility-api.md` for the responsibility and caller of the new entry
points and internal policy helpers.

## Channel WIDTH and drag ordering

Standard channels now use preset configuration version 2: EQ → WIDTH → PAN →
volume. The WIDTH stage reuses the master's model and audio processor, with a
neutral value of 100%. Both the console and detail editor update the same owned
parameter. Legacy flat settings default missing width to 100%; registry migration
adds that neutral stage to version-1 node trees without losing existing effects.
RESET retains its existing EQ-gain reset scope; width still resets to 100% by
double-clicking its knob or the detail width reset.

Channel header drags carry typed channel IDs. Dropping on the left/right half of
another strip moves before/after it. The master remains fixed. The session stores
display order separately in preferences; its channel observer reconciles core
membership only when model identities change. Display reordering therefore does
not rebuild the audio graph, restart output or recreate captures. Discovery,
disappearance/reappearance and session recreation preserve the remembered order.

## EQ, shared filters and CRUNCH

The console retains ten-band EQ and the version-2 channel preset (EQ → WIDTH →
PAN → volume). Its optional post-fader assignment is a separate `FilterRouterNode`
with dry/filter1/filter2 outputs and a persisted 0/1/2 selection. A native mixer gate
enables exactly one branch; assignment is a parameter edit rather than a topology
change. Router bypass selects dry. Each `ConsoleFilterBank` contains CRUNCH followed
by the filter; disabling the bank bypasses both stages and preserves the assigned
signal. Selected bank outputs feed the master input, where master EQ/stereo controls
process the combined result. The channel's gate already applies mute/solo upstream.

`ConsoleFilters` composes and reuses these banks and routers after graph restoration.
It replaces only a console channel's direct-to-master edge. Custom routes are retained
and no filter assignment control is offered for those channels. New sources get a
neutral assignment. Membership/route installation is batched by the session before
apply/save so an intermediate topology is not rebuilt.

`FilterProcessor` uses Apple resonant low/high-pass or band-pass EQ, mapping resonance
to bandwidth 2…0.1 octaves and clamping cutoff below 0.45 times the native sample rate.
CRUNCH is a stereo native AU with an allocation-free C render loop, atomic controls,
10 ms amount smoothing, exact dry behavior at zero/bypass and normalized tanh soft
saturation. It is not an analogue circuit model and does not oversample. The explicit
processor-internal connections support the router's fan-out without special-casing
its type in the renderer.

No compressor, reverb, delay or external-effects endpoint is installed. Concrete
document migration removes only the previous console-owned send/returns; the standard
registry strips its owned compressor from version-3 channel snapshots back to the
version-2 schema. Raw original graph/channel-node records are copied once under
`backup.beforeFilterOnly.<originalKey>`. Generic graph snapshots expose a raw-value
initializer so concrete migrations remain outside core; unknown extensions still
fail restoration without overwriting the saved document.

### Dashboard controls

Channel headers expose the persisted assignment with a three-position 1/OFF/2 rotary selector using the existing console knob cap. The pointer snaps to left/up/right; vertical drags and label clicks keep the original assignment values. Clicks and dragging map to the same saved 1/0/2 values. A fixed 132-point
FILTERS strip beside MASTER contains both banks, with LPF/BPF/HPF and enabled buttons,
existing console-style rotary caps and numeric frequency/resonance/CRUNCH controls.
DETAIL is again the EQ editor; no separate filter page or tab exists. The new strip
shares the existing dashboard height; application channels continue scrolling
horizontally. The effect graph, parameter identities and DSP are unchanged.

The compact dashboard uses 132-point app/master/filter strips (previously 150-point
channels and a 180-point filter strip), an 860-point opening width and an 800-point
minimum width. Fader and stereo-control sizes are retained; channels scroll when
the window cannot show them all.

The app header is 55 points high to fit the 28-point selector knob and its labels;
its fader region is 170 points high, preserving the total strip height. Master
header/fader geometry and compact horizontal dimensions stay unchanged.
