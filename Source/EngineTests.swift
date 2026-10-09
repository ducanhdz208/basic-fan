import Foundation
final class MockDriver: FanDriver {
    var begins = 0
    var finishes = 0
    var actions: [FanAction] = []
    var failApply = false
    var failRestore = false
    func begin() throws { begins += 1 }
    func apply(_ action: FanAction) throws {
        actions.append(action)
        if failApply { throw FanFailure(message: "Fan 2 write failed") }
    }
    func finish() throws {
        finishes += 1
        if failRestore { throw FanFailure(message: "restore failed") }
    }
}
@main struct EngineTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ description: String) {
            guard value else { fatalError(description) }; count += 1
        }
        let d = MockDriver(); var supply = PowerSupply.ac; var thermal = false
        let e = FanEngine(driver: d, power: { supply }, hot: { thermal })
        let a = UUID(), b = UUID()
        check(e.update(owner: a, mode: "pluggedIn", percent: 50, suspended: false, now: 0) == "PLUGGED_IN", "AC status")
        check(d.actions.last == .rpm(2000), "Both-fan driver receives fixed RPM")
        check(e.update(owner: b, mode: "automatic", percent: 0, suspended: false, now: 1).hasPrefix("ERROR"), "Second client cannot stop owner")
        e.disconnect(b); check(d.finishes == 0, "Unrelated disconnect does not restore owner's session")
        supply = .battery; e.tick(now: 1)
        check(d.actions.last == .automatic && e.status == "BATTERY", "Unplug restores Automatic")
        supply = .ac; e.tick(now: 2)
        check(d.actions.last == .rpm(2000) && d.begins == 1, "Replug reuses authorized session")
        thermal = true; e.tick(now: 3)
        check(d.actions.last == .automatic && e.status == "THERMAL", "Hot fallback")
        thermal = false
        _ = e.update(owner: a, mode: "pluggedIn", percent: 0, suspended: true, now: 4)
        check(d.actions.last == .automatic && e.status == "PAUSED", "Sleep notification restores")
        _ = e.update(owner: a, mode: "pluggedIn", percent: 0, suspended: false, now: 5)
        check(d.actions.last == .rpm(2000), "Wake resumes")
        e.tick(now: 12)
        check(d.finishes == 1 && e.status == "AUTOMATIC", "Missing heartbeat restores")
        _ = e.update(owner: a, mode: "manual", percent: 60, suspended: false, now: 13)
        check(d.begins == 2 && d.actions.last == .percent(60), "New session after lease expiry")
        e.disconnect(a)
        check(d.finishes == 2 && e.status == "AUTOMATIC", "App quit disconnect restores")
        _ = e.update(owner: a, mode: "pluggedIn", percent: 0, suspended: false, now: 14)
        check(e.update(owner: a, mode: "arbitrary", percent: 0, suspended: false, now: 15).hasPrefix("ERROR"), "Unknown mode rejected")
        check(d.finishes == 3, "Invalid command cancels own active session")
        for invalid in [-1.0, 101, Double.nan, .infinity] {
            check(e.update(owner: a, mode: "manual", percent: invalid, suspended: false, now: 16).hasPrefix("ERROR"), "Invalid percentage rejected")
        }
        d.failApply = true
        check(e.update(owner: a, mode: "manual", percent: 50, suspended: false, now: 17).contains("Fan 2 write failed"), "Hardware error propagated")
        check(d.finishes == 4, "Partial hardware failure restores both fans through driver")
        d.failApply = false
        _ = e.update(owner: a, mode: "manual", percent: 50, suspended: false, now: 18)
        d.failRestore = true; e.disconnect(a)
        check(e.status.hasPrefix("ERROR"), "Failed restoration remains an error")
        let old = d.finishes; e.tick(now: 19)
        check(d.finishes == old + 1, "Cleanup failure retries without a client")
        d.failRestore = false; e.tick(now: 20)
        check(e.status == "AUTOMATIC", "Recovery clears pending cleanup")
        check(!e.requiresService, "Idle helper needs no timer")
        check(e.update(owner: a, mode: "pluggedIn", percent: 50, rpm: 2800, suspended: false, now: 21) == "PLUGGED_IN", "Custom target accepted")
        check(d.actions.last == .rpm(2800), "Custom target reaches driver")
        let beforeHeartbeat = d.actions.count
        _ = e.update(owner: a, mode: "pluggedIn", percent: 50, rpm: 2800, suspended: false, now: 22)
        check(d.actions.count == beforeHeartbeat, "Unchanged heartbeat does not reapply target")
        _ = e.update(owner: a, mode: "pluggedIn", percent: 50, rpm: 3100, suspended: false, now: 23)
        check(d.actions.last == .rpm(3100), "Editing RPM takes effect immediately")
        check(e.requiresService, "Active session keeps watchdog")
        check(e.update(owner: a, mode: "pluggedIn", percent: 50, rpm: .infinity, suspended: false, now: 24).hasPrefix("ERROR"), "Helper rejects nonfinite RPM")
        check(!e.requiresService, "Invalid RPM cancels session and watchdog")
        print("\(count) helper lifecycle checks passed. No hardware writes.")
    }
}
