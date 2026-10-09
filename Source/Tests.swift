import Foundation
@main struct Tests {
    static func main() {
        var count = 0
        func check(_ result: Bool, _ description: String) {
            guard result else { fatalError(description) }; count += 1
        }
        let now = 1000.0
        check(Command(percent: 50, timestamp: 999, active: true).valid(now: now), "Fresh command")
        check(!Command(percent: 50, timestamp: 993, active: true).valid(now: now), "Dead UI expires")
        check(!Command(percent: 50, timestamp: 1001, active: true).valid(now: now), "Future timestamps rejected")
        check(!Command(percent: 50, timestamp: 999, active: false).valid(now: now), "Automatic request stops helper")
        for percent in [-1.0, 101, Double.nan, Double.infinity] {
            check(!Command(percent: percent, timestamp: 999, active: true).valid(now: now), "Invalid speed rejected")
        }
        let fan = FanInfo(id: 0, minimum: 1499, maximum: 5348, modeKey: "F0Md")
        check(fan.target(0) == 1499, "Minimum is not zero RPM")
        check(fan.target(100) == 5348, "Maximum matches hardware")
        check(fan.target(50) == 3423.5, "Speed interpolation")
        check(fan.target(-100) == 1499, "Lower clamp")
        check(fan.target(1000) == 5348, "Upper clamp")
        check(MemoryLayout<SMCKeyData_t>.stride == 80, "SMC ABI layout")
        check(!Command(percent: 50, timestamp: .nan, active: true).valid(now: now), "Invalid time")
        var policy = Command(percent: 0, timestamp: 999, active: true, mode: .pluggedIn)
        let sequence: [PowerSupply] = [.battery, .ac, .ac, .battery, .ac, .unknown]
        let expected: [FanAction] = [.automatic, .rpm(2000), .rpm(2000), .automatic, .rpm(2000), .automatic]
        for (power, action) in zip(sequence, expected) {
            check(fanAction(command: policy, power: power, hot: false) == action, "AC / battery / reconnect / unknown transition")
        }
        policy = Command(percent: 100, timestamp: 999, active: true, mode: .pluggedIn)
        check(fanAction(command: policy, power: .ac, hot: false) == .rpm(2000), "AC speed is exactly 2000, independent of slider")
        check(fanAction(command: policy, power: .ac, hot: true) == .automatic, "Thermal pressure overrides fixed speed")
        policy.suspended = true
        check(fanAction(command: policy, power: .ac, hot: false) == .automatic, "Sleep gives control to macOS")
        policy.suspended = false
        check(fanAction(command: policy, power: .ac, hot: false) == .rpm(2000), "Wake resumes power policy")
        policy.mode = .manual
        check(fanAction(command: policy, power: .battery, hot: false) == .percent(100), "Explicit manual mode is independent of AC policy")
        let encoded = try! JSONEncoder().encode(policy)
        let decoded = try! JSONDecoder().decode(Command.self, from: encoded)
        check(decoded.mode == .manual && decoded.percent == 100 && !decoded.suspended, "Command serialization")
        check(averageTemperature([40, 60]) == 50, "CPU average")
        check(averageTemperature([0, 256, .nan, .infinity, -1, 50]) == 50, "Invalid sensor readings excluded")
        check(averageTemperature([]) == nil, "Unavailable temperature is not zero")
        check(averageTemperature([0, 256]) == nil, "All invalid sensors show unavailable")
        var reads = 0
        var writes = 0
        var waits = 0
        do {
            try verifyFanSetting(fanID: 0, target: 2000, apply: { writes += 1 }, read: {
                reads += 1
                return FanReadback(mode: reads < 3 ? 0 : 1, target: reads < 3 ? 1499 : 2000)
            }, pause: { waits += 1 })
            check(reads == 3 && writes == 3 && waits == 3, "Delayed readback converges after retries")
        } catch { fatalError("Delayed readback should succeed") }
        reads = 0
        do {
            try verifyFanSetting(fanID: 1, target: 2000, apply: {}, read: {
                reads += 1; return FanReadback(mode: 3, target: 2000)
            }, pause: {})
            fatalError("System mode must never be accepted as manual")
        } catch {
            check(reads == 8, "Retries are bounded")
            check(error.localizedDescription.contains("Fan 2") && error.localizedDescription.contains("mode=3"), "Failure reports actual fan and mode")
        }
        check(!FanReadback(mode: 1, target: nil).matches(2000), "Missing target fails verification")
        check(!FanReadback(mode: 1, target: 1499).matches(2000), "Wrong target fails verification")
        check(!FanReadback(mode: 1, target: .nan).matches(2000), "Nonfinite target fails verification")
        check(FanReadback(mode: 1, target: 2000).matches(2000), "Matching requested target passes")
        var readAfterWriteError = false
        do {
            try verifyFanSetting(fanID: 0, target: 2000, apply: { throw FanFailure(message: "write rejected") }, read: {
                readAfterWriteError = true; return FanReadback(mode: 1, target: 2000)
            }, pause: {})
            fatalError("Rejected writes cannot succeed")
        } catch { check(!readAfterWriteError, "Write rejection propagates without false success") }
        var gate = FanVerificationGate()
        check(gate.shouldVerify(action: .rpm(2000), now: 0), "First target is verified")
        check(!gate.shouldVerify(action: .rpm(2000), now: 2), "Stable target avoids repeated writes/checks")
        check(gate.shouldVerify(action: .rpm(2000), now: 5), "Periodic readback catches external changes")
        check(gate.shouldVerify(action: .rpm(2500), now: 6), "Changed RPM is immediate")
        gate.reset()
        check(gate.shouldVerify(action: .rpm(2500), now: 7), "Automatic/wake resets target cache")
        var hardwareWrites = 0
        try! reconcileFanTarget(target: 2000, read: { FanReadback(mode: 1, target: 2000) }, write: { hardwareWrites += 1 })
        check(hardwareWrites == 0, "Matching hardware state performs no write")
        try! reconcileFanTarget(target: 2000, read: { FanReadback(mode: 0, target: 1499) }, write: { hardwareWrites += 1 })
        check(hardwareWrites == 1, "External reset is reconciled")
        let custom = Command(percent: 50, timestamp: 999, active: true, mode: .pluggedIn, rpm: 2700)
        check(fanAction(command: custom, power: .ac, hot: false) == .rpm(2700), "Custom plugged-in target")
        check(fanAction(command: custom, power: .battery, hot: false) == .automatic, "Custom target still gives Automatic on battery")
        check((try! JSONDecoder().decode(Command.self, from: JSONEncoder().encode(custom))).rpm == 2700, "Custom RPM serialization")
        check(!Command(percent: 50, timestamp: 999, active: true, rpm: .nan).valid(now: now), "Invalid RPM rejected")
        check(sensorInterval(detailsVisible: false, power: .ac) == 1, "Background AC stays live")
        check(sensorInterval(detailsVisible: false, power: .battery) == 1, "Background battery stays live")
        check(sensorInterval(detailsVisible: true, power: .battery) == 1, "Open details stay live")
        print("\(count) checks passed. No hardware writes performed.")
    }
}
