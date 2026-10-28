# Extensibility API responsibilities

This catalog explains the new methods, their production callers, and why the
responsibility belongs at that boundary rather than being repeated in callers.
Moved preference, analysis, scale and settings-codec methods retain their prior
responsibility. Constructors establish ownership before observations or audio
callbacks start; they do not start hardware unless explicitly stated below.

## Core

| Owner / method | Responsibility and caller | Reason for this boundary |
|---|---|---|
| `Parameter.Unit.init(rawValue:)` | Gives an extension its unit identifier; node constructors use it. | A new unit needs no core enum change. |
| `Parameter.init` | Defines a bounded control and normalizes its initial/default values. | Every subclass and shared UI control uses the same rules. |
| `Parameter.setValue`, `reset`, `normalized` | Apply mutation, neutral defaults and finite/step rules; editors, restores and batches call them. | Final entry points prevent copied or conflicting policy. |
| `AudioPort.init` | Defines a named directed signal/channel contract; nodes supply it. | Graph validation needs explicit port data, independent of a backend. |
| `MixerNode.init` | Owns a node's identity, ports, parameters and children and attaches observation. | Every concrete node inherits one notification implementation. |
| `setBypassed` | Publishes bypass changes; editors and restore use it. | Bypass is shared state, independent of an effect's implementation. |
| `performUpdate` | Defers parent notifications until nested updates finish; preset settings setters use it. | Observers receive one complete state instead of intermediate snapshots. |
| `resetParameters` | Resets owned and descendant parameters in a batch; callers need no concrete-type traversal. | New effect parameters inherit reset without a central switch. |
| `replaceChildren`, `observeChildren` | Update graph ownership and descendant subscriptions; the chain setter calls them. | Removed children stop notifying former owners. |
| `recordChange`, `publishChange` | Prioritize structural changes and advance revisions; parameter/child observations call them. | Batching and version rules have one implementation. |
| `encodeConfiguration`, `configurationVersion` | Supply immutable extension configuration to `NodeSnapshot`. | Numeric parameters remain generic; an extension owns its typed nonnumeric schema. |
| `validateConfiguration` | Checks a restored factory/preset object's configuration before shared restore. | Existing typed preset children must not silently ignore saved configuration. |
| `ProcessingChain.init` | Declares a serial composite with optional controls; channels, buses and presets use it. | Child composition is independent of concrete effects. |
| `setProcessingNodes` | Runs preset and graph validation before replacing children; editors and restore call it. | All child edits use one ownership and notification boundary. |
| `append`, `remove` | Express common chain edits through that setter; extension composition uses them. | They cannot bypass validation. |
| `validateProcessingNodes` | Lets a preset reject removal of required typed stages; the final setter calls it. | Preset constraints stay outside generic graph rules. |
| `Channel.init`, `MixBus.init` | Construct source-independent chains; presets and generic mixers use them. | No standard EQ/volume/device type is selected in core. |
| `Channel.audibleIDs` | Evaluates mute/solo for eligible channels; `Mixer` and the renderer call it. | A policy change propagates to model and playback. |
| `Channel.setMuted`, `setSolo` | Mutate inherited boolean parameters; UI/settings setters use them. | Boolean stepping and notification follow the same parameter policy. |
| `Mixer.init` | Accepts the caller's master and channels and observes its graph. | Master implementation is a type parameter rather than a fixed console dependency. |
| `addChannel`, `removeChannel`, `replaceChannels` | Reconcile membership/default routes and emit a complete membership event; discovery calls replacement. | Existing custom routes and object identities survive discovery. |
| `AudioGraph.init` | Creates an empty independently owned graph. | Tests, mixers and restores use the same graph class. |
| `AudioGraph.add`, `remove`, `connect`, `disconnect` | Express topology edits through `replace`; routing callers use them. | There is one atomic topology validator. |
| `AudioGraph.replace` | Validates complete nodes/edges, then commits ownership and subscriptions. | Invalid proposals cannot leave half-applied graph state. |
| `validateNodeTree`, `validateReplacement` | Detect duplicate IDs, shared ownership and invalid nested edits; graph/chain setters call them. | Child mutations obey the same global invariants as root replacement. |
| `updateOwnership` | Attaches/detaches all descendants; graph and chain mutations call it. | A detached node can be safely reused elsewhere. |
| `port`, `ordered`, `processingOrder` | Resolve endpoints and compute a stable acyclic order; validation and renderer use them. | Renderers consume validated domain connections. |
| `AudioGraph.publishChange` | Advances graph and topology revisions; graph/owned-node edits call it. | Parameter edits do not force native topology rebuilds. |
| `PortAddress.init`, `AudioConnection.init` | Define persisted connections; graph editors, presets and bindings use them. | IDs and port names remain independent of Apple node objects. |
| `NodeSnapshot.init`, `GraphSnapshot.init` | Capture the complete generic state; persistence calls them. | Adding effects does not add fields to the console's flat legacy settings. |
| `NodeRegistry.init`, `register` | Establish factories at composition time. | Extension types are registered rather than enumerated by core. |
| `makeNode`, graph `restore` | Construct detached candidates and commit only valid graphs; persistence calls them. | A failed restore preserves the current graph. |
| node `restore` | Matches required preset children, validates schema and applies parameters recursively. | Shared restore preserves the same parameter identities used by UI and DSP adapters. |

## Standard presets

| Owner / method | Responsibility and caller | Reason for this boundary |
|---|---|---|
| `GainNode`, `VolumeNode`, `PanNode`, `WidthNode` initializers | Define standard parameters and stereo ports; console presets construct them. | Concrete ranges and effects remain outside core. |
| `ParametricEQNode.init`, `updateSettings` | Define/update the standard bands; `Equalizer` uses them. | EQ shape and settings mapping stay with the effect; base batching handles notifications. |
| `Equalizer.init`, `settings`, `updateSettings` | Compose independent trim and filter stages and map the existing editor snapshot. | Disabling channel EQ still retains trim. |
| `ConsoleChannel` / `ConsoleBus` constructors, `settings`, `updateSettings` | Compose the existing console stages and legacy editor fields; app adapters/session use them. | Existing controls keep typed references without fixing generic channels to this preset. |
| preset `validateProcessingNodes` overrides | Preserve required stage identities during chain editing/restore. | An editor cannot leave typed console controls pointing at removed nodes. |
| `ConsoleMixer.init(channels:masterSettings:)` | Selects the standard master at the console boundary. | Core `Mixer` accepts any bus implementation. |
| `StandardNodeRegistry.make`, `register` | Register standard and generic chain factories; the default session uses them. | Other composition roots can append their own factories. |

## Audio adapters and runtime

| Owner / method | Responsibility and caller | Reason for this boundary |
|---|---|---|
| `AudioEndpoint.init` | Names an Apple node/bus; processors and sources supply it. | Graph IDs do not expose backend objects. |
| `AudioProcessor.init` | Declares native nodes, endpoints and bypass units; concrete adapters call it. | The renderer can attach any registered adapter without an effect-type switch. |
| `AudioProcessor.apply`, `applyParameters` | Applies common inherited bypass, then DSP-specific controls; renderer calls the final entry point. | Effect subclasses implement primitive assignments only. |
| `AudioProcessorRegistry.init`, `register`, `make` | Bind typed model factories and check their ownership/ports; composition and renderer call them. | Wrong registrations fail before native graph replacement. |
| standard processor initializers / `applyParameters` | Map gain, linear volume, EQ, balance and width models to their native implementations. | These concrete DSP details do not enter the renderer or core. |
| `StandardAudioProcessors.make`, `register` | Register the standard native adapters and stereo AU. | A different composition can supply additional implementations. |
| `StereoRenderState.init` / deinit | Allocate/free C control state retained by the render block. | The callback cannot depend on a UI object's lifetime. |
| `StereoAudioUnit.init` | Establish input/output buses and state; the AU registry constructs it. | Buffer/DSP state exists before rendering. |
| `allocateRenderResources`, `deallocateRenderResources` | Validate native format and allocate/free fallback audio buffers. | No buffer allocation occurs in the render callback. |
| `StereoAudioUnit.set`, `shouldBypassEffect` | Publish controls to C atomics; its processor/Apple wrapper call them. | Main-actor controls do not touch render-owned smoothing state. |
| `internalRenderBlock` | Pull audio, supply preallocated backing when needed, run stereo DSP. | One native render contract integrates the standalone graph stage. |
| `mixerMacStereoCreate`, `Destroy`, `Set`, `SetBypassed`, `Process` | Own atomic targets and render-owned balance/width smoothing; the AU calls them. | Stereo transforms are no longer tied to a source FIFO. |
| `AudioGraphRenderer.init` | Accepts engine, format and processor registry; playback/offline tests supply them. | There is one graph interpreter for production and tests. |
| `rebuild` | Validate adapters and endpoints, replace owned nodes, connect routes and install taps. | Invalid extensions retain the previous graph/taps. |
| `isCurrent` | Reports topology freshness to playback. | The caller does not duplicate graph identity and revision rules. |
| `apply` | Applies adapter parameters and core mute/solo policy. | Numeric changes reuse the native topology. |
| `detach`, `attach` | Release or track renderer-owned taps/nodes; rebuild/playback use them. | Native resources have a single owner. |
| `build`, `connectAll` | Compile serial composites, input sums and grouped fan-out connections. | Recursive composition and Apple bus assignment do not leak into session code. |
| `AudioSource.init` | Associates a source with its definition. | The registry preserves identity across lifecycle and bindings. |
| `AudioSource.prepare`, `activate`, `synchronize`, `stop` | Own final lifecycle transitions and partial-failure cleanup; playback calls them. | New sources cannot omit shared rollback and start ordering. |
| source resource hooks | Prepare an endpoint, activate muting, update descriptors and release resources. | Platform/device implementations supply only their resource operations. |
| `AudioSourceRegistry.init`, `register`, `make` | Bind typed input factories and validate identity. | Another input family needs registration, not changes to playback or core. |
| `ApplicationInput.init`, `update` | Adapt a discovered app/feed to a source definition; `AppAudioChannel` calls them. | Process IDs remain outside the generic mixer. |
| `ApplicationAudioSource` constructor/resource overrides | Own tap/FIFO source preparation, process updates, delayed muting and cleanup. | Application-specific capture follows the inherited source lifecycle. |
| `ApplicationAudioSources.make` | Registers the default application source. | The session can instead receive another source registry. |
| `DeviceAudioOutput.init`, `start`, `stop` | Own the output engine and Core Audio device operation; playback calls them. | Tests replace hardware output while retaining the real renderer. |
| `AudioSourceBinding.init` | Connects a source model to a graph input; session or another composition supplies it. | Input implementation and destination channel are separate objects. |
| `AudioGraphPlayback.init` | Accepts graph, destination and backend registries. | It is reusable outside the console/discovery flow. |
| `start`, `connect` | Prepare candidates, start output, then activate sources; session invokes them. | New-source failure is isolated before changing running playback. |
| `apply` | Reconciles removed bindings and topology or applies parameters; session invokes it on core events. | UI code does not own engine transitions. |
| `source` | Returns the runtime source for an adapter's binding. | The application adapter borrows status without owning playback lifetime. |
| `stop`, `removeInput` | Stop output, detach nodes and release sources; normal shutdown and rollback use them. | Every exit restores owned source resources. |
| `prepare`, `rebuild` | Allocate one input and assemble its external endpoints; lifecycle methods call them. | Start/connect/recovery use identical resource and topology rules. |
| `AppAudioChannel.sourceBinding`, `prepareForProcessing`, `setProcessingSource` | Supply the graph binding, end passive capture and reflect playback's source state. | It no longer constructs its own playback engine. |
| `MixerSession.init` | Restore a graph and compose registries/output; app and headless callers use it. | The SwiftUI model does not build the runtime. |
| `saveGraph`, `channelFeeds`, `apply` | Persist complete graph state, locate pre-fader feeds and synchronize playback. | New nodes/routes participate without adding per-effect persistence or apply calls. |
| `MixerSession.tick(updateMeters:)` | Run discovery independent of display refresh and update visible metrics. | A reusable session does not inspect windows. |
| `MixerConsoleModel.tick` | Supply the current visibility decision. | AppKit window policy remains at the UI boundary. |

Error types expose `errorDescription` to the session's existing status path. These
properties identify missing types, ports and definitions rather than presenting
opaque numeric error codes; their messages stay with the contract that failed.

## Compatibility rule

Final inherited methods are the stable common policy surface. Override hooks are
primitive contracts, not alternative lifecycle entry points. Adding a concrete
implementation means new implementation files and registration at the caller's
composition root. A breaking meaning/schema change requires a versioned migration;
it cannot be made compatible by an unused wrapper or silently ignored data.

## Channel width and presentation ordering

| Method / property | Responsibility and caller | Reason for this boundary |
|---|---|---|
| `NodeSnapshot.init(id:typeID:...)` | Constructs an explicit migrated snapshot; the standard channel migration calls it. | A migration can change a versioned node tree without mutating a live model. |
| `NodeRegistry.register(migrate:factory:)` | Associates an optional snapshot migration with a factory and applies it before construction/restore. | The generic restore path stays independent of concrete preset versions. |
| `ConsoleChannel.configurationVersion` | Identifies the version-2 preset with a required WIDTH stage. | Version-1 trees can be distinguished from malformed current trees. |
| `StandardNodeRegistry.migrateChannel` | Adds a neutral WIDTH node to version-1 channels while retaining existing stages and their order. | Older saved graphs remain playable without teaching core about WIDTH. |
| `ConsolePreferences.channelOrder`, `saveChannelOrder` | Read/write the user's stable app IDs in display order; the session uses them. | Presentation order is independent of audio routing and topology. |
| `MixerSession.moveChannel` | Moves one visible channel before/after another, preserving channel objects and remembering offline IDs. | DnD invokes one testable ordering operation rather than modifying DSP or view-local arrays. |
| `MixerSession.sortChannels` | Restores the saved order after discovery; new apps are appended stably. | Periodic discovery must not undo user reordering. |
| `ChannelDragItem.transferRepresentation` | Supplies typed channel-ID transfer data to SwiftUI draggable/drop destinations. | Audio knobs keep their own gestures, and unrelated text/file drops are not channel moves. |
| `ConsoleActionButtonStyle.makeBody` | Draws a 16-point dark action button with RESET/DETAIL beside it, matching the MUTE/SOLO ring and 24-point hit row with hover, pressed and disabled states. | RESET and DETAIL share one visual and interaction implementation. |

## Filter and CRUNCH responsibilities

| Method / property | Responsibility and caller | Reason for this boundary |
|---|---|---|
| `FilterNode.init`, `CrunchNode.init` | Own bounded filter mode/frequency/resonance and saturation amount; bank composition and registry factories call them. | UI and DSP bind to one persisted model, independent of audio frameworks. |
| `FilterRouterNode.init` | Owns the discrete dry/1/2 assignment and explicit output ports; composition and restore call it. | Live assignment does not require graph mutation or teaching core about filters. |
| `ConsoleFilterBank.init`, `validateProcessingNodes` | Construct and enforce CRUNCH → filter; composition and graph restore use them. | Filtering must follow saturation, and bank bypass must disable both together. |
| `ConsoleFilters.init` | Reuses typed saved banks or adds two disabled defaults; the session calls it after restore. | Shared bank lifetime and identity have one composition owner. |
| `ConsoleFilters.router` | Locates a channel's persisted assignment node; its dashboard header calls it. | View state is not a second routing model. |
| `ConsoleFilters.connectChannels` | Installs missing banks and replaces direct console dry routes with neutral router paths; initialization/discovery call it. | Idempotent composition preserves custom connections and existing control objects. |
| `ConsoleDocumentMigration.removingBuiltInEffects` | Removes the previous console-owned send/returns and their incident edges; session restore calls it. | Removed concrete effects do not become permanent core dependencies. |
| `GraphSnapshot.init(version:nodes:connections:)` | Constructs a complete migrated snapshot; concrete document migration uses it. | Typed migration does not rewrite opaque JSON or instantiate live nodes. |
| `StandardNodeRegistry.migrateChannel` | Retains legacy WIDTH migration and removes the owned compressor from old version-3 channels. | Existing EQ/stereo/volume and extra registered nodes survive the requested effect removal. |
| `FilterProcessor.init`, `applyParameters` | Construct and configure Apple's resonant filter from model parameters; registry/renderer call them. | Native type identifiers and bandwidth mapping remain at the audio boundary. |
| `CrunchProcessor.init`, `applyParameters` | Construct the standalone CRUNCH AU and publish amount; registry/renderer call them. | The model never owns native render resources. |
| `FilterRouterProcessor.init`, `applyParameters` | Wire input to three native gates and enable one output. | Reassignment and bypass retain topology and running source objects. |
| `AudioProcessor.connections` | Declares internal native edges; registry validates ownership/buses and renderer connects after attachment. | Router fan-out uses the same extension contract as other processors. |
| `CrunchRenderState.init`, `deinit` | Allocate/release native DSP; the AU owns this render state. | Render closure capture keeps resources alive without allocating in the callback. |
| `CrunchAudioUnit.init`, `allocateRenderResources`, `deallocateRenderResources` | Declare stereo buses, validate formats, allocate reusable backing and reset smoothing outside rendering. | Host lifecycle owns buffers and sample rate. |
| `CrunchAudioUnit.set`, `shouldBypassEffect` | Publish bounded amount/bypass atomically; the processor and host call them. | Controls never mutate render-owned smoothing state. |
| `CrunchAudioUnit.internalRenderBlock` | Pull input, supply preallocated output memory and call native DSP. | The engine receives a normal stereo AU contract. |
| `mixerMacCrunchCreate`, `Destroy`, `Reset` | Own native state; AU construction/resource lifecycle uses them. | Allocation and smoothing reset stay outside the render callback. |
| `mixerMacCrunchSet`, `Process` | Publish atomic targets and apply stereo shaping within supplied buffer bounds. | No locks/allocations occur in processing; zero/bypass preserve original PCM. |
| `ConsoleFilterStrip.body`, `ConsoleFilterBankControls.body` | Present both shared banks beside the dashboard master; the main console embeds the strip. | Filter operation is visible alongside channels without opening a separate page. |
| `ConsoleFilterKnob.position`, `lower`, `upper`, `body` | Map the existing rotary cap to linear or logarithmic model units, observe its parameter, and expose precise numeric editing. | Frequency and normalized effects reuse the established knob appearance without changing the audio model. |
| `ConsoleEQKnob.reset` | Supplies an optional parameter-specific reset callback; dashboard filter knobs pass their own reset operation. | Frequency/CRUNCH defaults differ from EQ's 0 dB default, while existing EQ callers retain their behavior. |
| `FilterAssignmentControl.body` | Draw the three-detent 1/OFF/2 knob, map label clicks/vertical dragging to existing route values, and observe external/restored changes. | Shared routing state lies outside the channel's own publication stream. |

The session and standalone channel adapter back up original version-3 records before
rewriting. The test render helper exercises production routing offline; RMS and harmonic
helpers measure its steady-state frequency response and added distortion components.

`ConsoleButton.stacked` places mode captions below their existing circular buttons
in the compact filter strip. Other callers retain horizontal labels. All strip
widths now use the same 132-point layout constant; no audio parameters or routing
contracts change.

`ConsoleEQKnob.showsScale` hides the continuous EQ scale for the discrete assignment
knob while retaining its original cap. Existing EQ/stereo/filter callers retain
their printed scales. The assignment control owns the three detents and observes
the existing router parameter; no new routing model is introduced.
