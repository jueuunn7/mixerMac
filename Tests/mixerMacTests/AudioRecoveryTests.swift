import CoreAudio
import Foundation
import Testing
@testable import mixerMac

@MainActor
private final class TestAudioCapture: AudioCapturing {
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
    @Test @MainActor func refreshRetriesFailedMasterCaptureWithoutRestartingAnActiveCapture() throws {
        let suite = "mixerMac.AudioRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let failed = TestAudioCapture()
        failed.startFails = true
        let recovered = TestAudioCapture()
        var masterCreations = 0
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults)) { _, processes in
            guard processes == nil else { return TestAudioCapture() }
            masterCreations += 1
            return masterCreations == 1 ? failed : recovered
        }
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
