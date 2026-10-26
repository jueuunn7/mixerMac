import Testing
@testable import mixerMac

struct MeterPeakHoldTests {
    @Test func transientPeakRemainsWhileSignalFallsThenReleases() {
        var peak = MeterPeakHold()
        peak.update(0.8, now: 10)
        peak.update(0.2, now: 11.49)
        #expect(peak.level == 0.8)
        peak.update(0.2, now: 12)
        #expect(peak.level < 0.8 && peak.level > 0.2)
        peak.update(0, now: 20)
        #expect(peak.level == 0)
    }

    @Test func NewHighPeakImmediatelyReplacesAndRenewsHold() {
        var peak = MeterPeakHold()
        peak.update(0.5, now: 10)
        peak.update(1, now: 11)
        #expect(peak.level == 1)
        peak.update(0, now: 12.49)
        #expect(peak.level == 1)
        peak.update(0, now: 13)
        #expect(peak.level < 1 && peak.level > 0)
    }
}
