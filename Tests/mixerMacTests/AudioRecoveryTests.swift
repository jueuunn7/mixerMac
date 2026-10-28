@testable import MixerAudio
import CoreAudio
import Foundation
import Testing
@testable import mixerMac

@MainActor
final class TestAudioCapture: AudioCapturing {
    enum Failure: Error { case unavailable }
    var startFails = false
    var processFailures = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var processUpdates: [[AudioObjectID]?] = []

    func start() throws {
        starts += 1
        if startFails { throw Failure.unavailable }
    }

    func setProcesses(_ processes: [AudioObjectID]?) throws {
        processUpdates.append(processes)
        if processFailures > 0 {
            processFailures -= 1
            throw Failure.unavailable
        }
    }

    func stop() { stops += 1 }
}

struct AudioRecoveryTests {
    @MainActor
    private func withMixer(_ test: (MixerConsoleModel, TestAudioCapture, TestChannelProcessing) throws -> Void) throws {
        let suite = "mixerMac.AudioRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = TestAudioCapture()
        let processing = TestChannelProcessing()
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults),
            sources: try processing.registry(), audioOutput: processing.output,
            discoverOwnProcesses: { processing.ownProcesses },
            makeCapture: { _, _ in capture })
        defer { model.shutdown() }
        try test(model, capture, processing)
    }

    @MainActor
    private func refresh(_ model: MixerConsoleModel, appIDs: [String]) {
        let apps = appIDs.enumerated().map { index, id in
            AudioApp(id: id, name: id, icon: nil, processes: [AudioObjectID(index + 11)], isPlaying: false)
        }
        model.refresh(apps: apps, devices: [OutputDevice(id: 42, name: "Test Output", uid: "test-output")],
            defaultOutputID: 42)
    }

    @Test @MainActor func masterMeterFailureDoesNotStopPlaybackAndCanRecover() throws {
        try withMixer { model, capture, processing in
            refresh(model, appIDs: ["first"])
            capture.processFailures = 2
            model.toggleMixing()
            let channel = try #require(model.channels.first)
            #expect(model.isMixing)
            #expect(channel.isProcessing)
            #expect(model.status.contains("Master meter could not reconnect"))

            refresh(model, appIDs: ["first"])
            #expect(model.isMixing)
            #expect(channel.isProcessing)
            #expect(model.status.contains("Master meter could not reconnect"))
            refresh(model, appIDs: ["first"])
            #expect(!model.status.contains("Master meter could not reconnect"))
            #expect(processing.starts == ["first"])
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func failedNewChannelLeavesExistingPlaybackAndErrorSurvivesUntilResolved(removeFailedApp: Bool) throws {
        try withMixer { model, _, processing in
            refresh(model, appIDs: ["first"])
            model.toggleMixing()
            processing.failingIDs = ["second"]
            refresh(model, appIDs: ["first", "second"])
            let first = try #require(model.channels.first { $0.id == "first" })
            let second = try #require(model.channels.first { $0.id == "second" })
            #expect(model.isMixing)
            #expect(first.isProcessing)
            #expect(!second.isProcessing)
            #expect(model.status.contains("Could not connect second"))

            refresh(model, appIDs: ["first", "second"])
            #expect(model.isMixing)
            #expect(model.status.contains("Could not connect second"))
            #expect(processing.starts.filter { $0 == "first" }.count == 1)
            #expect(processing.starts.filter { $0 == "second" }.count == 2)

            processing.failingIDs = []
            refresh(model, appIDs: removeFailedApp ? ["first"] : ["first", "second"])
            #expect(model.isMixing)
            #expect(first.isProcessing)
            if removeFailedApp { #expect(model.channels.count == 1) }
            else { #expect(second.isProcessing) }
            #expect(!model.status.contains("Could not connect"))
        }
    }

    @Test @MainActor func playbackStartupErrorSurvivesRefreshAndClearsOnSuccessfulStart() throws {
        try withMixer { model, _, processing in
            refresh(model, appIDs: ["first"])
            processing.failingIDs = ["first"]
            model.toggleMixing()
            #expect(!model.isMixing)
            let failure = model.status
            #expect(failure.contains("Mixer could not start"))
            refresh(model, appIDs: ["first"])
            #expect(model.status == failure)

            processing.failingIDs = []
            model.toggleMixing()
            #expect(model.isMixing)
            #expect(!model.status.contains("Mixer could not start"))
        }
    }

    @Test @MainActor func unrecoverableOutputFailureClearsLiveStateForEveryChannel() throws {
        try withMixer { model, _, processing in
            refresh(model, appIDs: ["first"])
            model.toggleMixing()
            #expect(model.isMixing)
            processing.output.failingStarts = 3
            refresh(model, appIDs: ["first", "second"])
            #expect(!model.isMixing)
            #expect(!model.playback.isRunning)
            #expect(model.channels.allSatisfy { !$0.isProcessing })
            #expect(model.status.contains("Could not connect") || model.status.contains("Could not update mixer routing"))
        }
    }

    @Test @MainActor func masterMeterErrorDoesNotHideAChannelError() throws {
        try withMixer { model, capture, processing in
            refresh(model, appIDs: ["first"])
            model.toggleMixing()
            processing.failingIDs = ["second"]
            processing.ownProcesses = [100]
            capture.processFailures = 1
            refresh(model, appIDs: ["first", "second"])
            #expect(model.isMixing)
            #expect(model.status.contains("Could not connect second"))
            #expect(model.status.contains("Master meter could not reconnect"))
            refresh(model, appIDs: ["first", "second"])
            #expect(model.status.contains("Could not connect second"))
            #expect(!model.status.contains("Master meter could not reconnect"))
            model.toggleMixing()
            #expect(!model.isMixing)
            #expect(!model.status.contains("Could not connect"))
        }
    }

    @Test @MainActor func failedMasterResetRetriesWhilePlaybackRemainsStopped() throws {
        try withMixer { model, capture, _ in
            refresh(model, appIDs: ["first"])
            model.toggleMixing()
            capture.processFailures = 1
            model.toggleMixing()
            #expect(!model.isMixing)
            #expect(model.status.contains("Master meter could not reconnect"))
            refresh(model, appIDs: ["first"])
            #expect(!model.isMixing)
            #expect(!model.status.contains("Master meter could not reconnect"))
            #expect(capture.processUpdates.count == 3)
            #expect(capture.processUpdates.last == .some(nil))
        }
    }

    @Test @MainActor func obsoleteMasterErrorClearsWhenTheOriginalRouteBecomesCurrentAgain() throws {
        try withMixer { model, capture, processing in
            refresh(model, appIDs: ["first"])
            model.toggleMixing()
            processing.ownProcesses = [100]
            capture.processFailures = 1
            refresh(model, appIDs: ["first"])
            #expect(model.status.contains("Master meter could not reconnect"))
            processing.ownProcesses = [99]
            refresh(model, appIDs: ["first"])
            #expect(model.isMixing)
            #expect(!model.status.contains("Master meter could not reconnect"))
            #expect(capture.processUpdates.count == 2)
        }
    }

    @Test @MainActor func refreshRetriesFailedMasterCaptureWithoutRestartingAnActiveCapture() throws {
        let suite = "mixerMac.AudioRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let failed = TestAudioCapture()
        failed.startFails = true
        let recovered = TestAudioCapture()
        var masterCreations = 0
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults), makeCapture: { _, processes in
            guard processes == nil else { return TestAudioCapture() }
            masterCreations += 1
            return masterCreations == 1 ? failed : recovered
        })
        defer { model.shutdown() }

        model.start()
        #expect(failed.starts == 1)
        #expect(failed.stops == 1)
        #expect(model.status == "Allow system audio access, then click Refresh")
        model.refresh()
        #expect(masterCreations == 2)
        #expect(recovered.starts == 1)
        #expect(!model.status.contains("Allow system audio access"))
        model.refresh()
        #expect(masterCreations == 2)
        #expect(recovered.starts == 1)
        model.shutdown()
        #expect(recovered.stops == 1)
        model.start()
        model.refresh()
        #expect(masterCreations == 2)
    }

    @Test(arguments: [false, true]) @MainActor
    func processUpdateRetriesTheLatestProcessesAfterFailure(changesAgain: Bool) throws {
        let suite = "mixerMac.AudioRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = TestAudioCapture()
        var app = AudioApp(id: "recovery.test", name: "Test", icon: nil, processes: [11], isPlaying: true)
        let channel = AppAudioChannel(app: app, defaults: defaults) { _, _ in capture }
        defer { channel.shutdown() }
        channel.listen()
        capture.processFailures = 1
        app.processes = [22]

        channel.update(app: app)
        #expect(channel.message == "RECONNECT NEEDED")
        #expect(capture.processUpdates.count == 1)
        if changesAgain { app.processes = [33] }
        channel.update(app: app)
        #expect(capture.processUpdates.count == 2)
        #expect(try #require(capture.processUpdates.last) == app.processes)
        #expect(channel.message == "LISTENING")
        channel.update(app: app)
        #expect(capture.processUpdates.count == 2)
    }

    @Test @MainActor func shutdownClearsProcessingState() throws {
        let suite = "mixerMac.AudioRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AudioApp(id: "shutdown.test", name: "Test", icon: nil, processes: [], isPlaying: false)
        let channel = AppAudioChannel(app: app, defaults: defaults)
        channel.isProcessing = true
        channel.shutdown()
        #expect(!channel.isProcessing)
    }
}
