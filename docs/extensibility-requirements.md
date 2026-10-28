# Extensible mixer requirements

This work continues from `2c91c0e`. The GUI must not be launched and no branch is
to be pushed during development.

## Required final behavior

1. Shared state rules belong to base classes with final mutation methods. Concrete
   channel/effect/source implementations provide their own definition or primitive
   operation, not copies of normalization, batching, notification or lifecycle rules.
2. The generic core has no knowledge of EQ band counts, application capture, device
   APIs, concrete effect types, console widgets or preference keys.
3. Nodes expose typed audio ports and owned parameters. Connections are explicit,
   validated and removable; invalid edits leave the graph unchanged.
4. Channels and buses compose processing nodes. Adding an effect does not require
   editing Channel, Mixer, the graph validator, or existing effect implementations.
5. Source and processor implementations are registered at the composition boundary.
   A new implementation does not require a central switch or a new core enum case.
6. Playback start, stop, recovery, application of controls and resource ownership
   belong to a reusable audio runtime, not a SwiftUI model.
7. The real application uses these contracts. Example-only abstractions alongside
   the old execution path do not satisfy the requirement.
8. Standard console behavior, saved settings migration, mute/solo, EQ, stereo
   behavior and the fixed bugs remain covered by meaningful tests.
9. Extension tests define concrete implementations outside the core module. They
   exercise inherited common behavior and add source/effect/routing behavior without
   modifying core or existing implementations.
10. The core builds alone, headless suites and a release build pass, and production
    dependencies/documentation match the resulting architecture.

## Scope and contract limits

The supported domain is an audio mixer with numeric controls and explicit audio
routing. Stable contracts permit common policy changes and new implementations.
An incompatible change to a contract's meaning cannot promise compatibility with
every existing implementation. Contract versioning and migration are explicit when
such a change is necessary; runtime casts, ignored connections or compatibility
wrappers must not hide a broken contract.

## Completion evidence

Record the generic-core dependency check, separate extension-module tests, rendered
PCM routing tests, lifecycle/failure tests, persistence/migration tests and release
build results. Hardware and visible UI behavior remain outside headless verification.

## Final implementation evidence

- Generic core: seven state/graph source files plus localized contract errors;
  only Foundation/Combine imports. `swift build --target MixerCore` succeeds in
  a separate scratch build with no audio or UI compilation.
- Actual application: `MixerConsoleModel` delegates to `MixerSession`, which
  constructs `AudioGraphPlayback` using the core graph. The former hardcoded
  `AppChannelProcessor` is removed. The master processes one shared sum.
- Extension proof: core fixtures import only core; audio fixtures are a separate
  module. A new source/effect is registered into the production playback runtime
  without editing core, standard nodes or existing processors.
- 99 Swift tests pass, including routing branches, sum, live stage insertion,
  parameter changes without rebuild, invalid-extension recovery, source lifecycle,
  44.1/48 kHz conversion, neutral PCM, balance/bypass/width, legacy EQ behavior,
  sticky errors and graph/session persistence with unavailable-extension retention.
- Plain native `BridgeTests` and `BridgeQualityTests` pass. They cover buffer
  ownership, silence, separation, wraparound, underrun, bit-exact equal-clock
  PCM and drift correction. These runs are not sanitizer results; the host's
  previously diagnosed sanitizer-runtime initialization issue remains separate.
- A release executable build and whitespace/diff checks pass. No GUI was launched,
  no hardware output/tap validation was claimed and no branch was pushed.
- `architecture.md` describes boundaries and supported formats;
  `extensibility-api.md` records new method responsibilities and callers.
