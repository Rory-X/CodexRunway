import Testing
@testable import CodexRunwayCore

struct LoopbackPortReclaimerTests {
    @Test("pid list ignores blanks and non-numeric tokens")
    func parsePIDs() {
        #expect(LoopbackPortReclaimer.parsePIDs("2247\n1770\n") == [2247, 1770])
        #expect(LoopbackPortReclaimer.parsePIDs("  12\r\n\nabc\n") == [12])
    }

    @Test("reclaim never targets init, self, or duplicate pids")
    func pidsToStopFiltersProtectedProcesses() {
        let targets = LoopbackPortReclaimer.pidsToStop(
            listeners: [0, 1, 42, 42, 99],
            ownPID: 99)
        #expect(targets == [42])
    }
}
