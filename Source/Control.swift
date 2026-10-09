import Foundation
import IOKit
import IOKit.ps
import Darwin

struct FanFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct FanReadback {
    let mode: Double?
    let target: Double?
    func matches(_ rpm: Double) -> Bool {
        guard mode == 1, let target, target.isFinite else { return false }
        return abs(target - rpm) < 5
    }
    var description: String {
        "mode=\(mode.map { String(format: "%.0f", $0) } ?? "unavailable"), target=\(target.map { String(format: "%.1f", $0) } ?? "unavailable")"
    }
}
// A successful SMC write is not a promise of immediate read-after-write visibility.
// Retry a bounded number of times, but never report success without readback.
func verifyFanSetting(fanID: Int, target: Double,
                      apply: () throws -> Void,
                      read: () -> FanReadback,
                      pause: () -> Void) throws {
    var samples: [String] = []
    for _ in 0..<8 {
        try apply()
        pause()
        let state = read()
        if state.matches(target) { return }
        samples.append(state.description)
    }
    throw FanFailure(message: "Fan \(fanID + 1) did not accept \(Int(target)) RPM after retries. \(samples.suffix(3).joined(separator: "; ")).")
}
enum ControlMode: String, Codable { case manual, pluggedIn }
enum PowerSupply: String { case ac = "Plugged in", battery = "Battery", unknown = "Power source unavailable" }
func powerSupply() -> PowerSupply {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return .unknown }
    if source as String == kIOPSACPowerValue { return .ac }
    if source as String == kIOPSBatteryPowerValue { return .battery }
    return .unknown
}
let gpuTemperatureKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
func gpuTemperature(_ smc: SMC) -> Double? {
    averageTemperature(gpuTemperatureKeys.compactMap { smc.getValue($0) })
}
let cpuTemperatureKeys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
func cpuTemperature(_ smc: SMC) -> Double? {
    averageTemperature(cpuTemperatureKeys.compactMap { smc.getValue($0) })
}
func averageTemperature(_ readings: [Double]) -> Double? {
    let values = readings.filter { $0.isFinite && $0 > 0 && $0 < 125 }
    return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
}
enum FanAction: Equatable { case automatic, percent(Double), rpm(Double) }
func fanAction(command: Command, power: PowerSupply, hot: Bool) -> FanAction {
    guard command.active, !command.suspended, !hot else { return .automatic }
    switch command.mode {
    case .manual: return .percent(command.percent)
    case .pluggedIn: return power == .ac ? .rpm(command.rpm) : .automatic
    }
}
struct Command: Codable {
    let percent: Double
    let timestamp: Double
    let active: Bool
    var mode: ControlMode = .manual
    var suspended: Bool = false
    var rpm: Double = 2000
    func valid(now: Double) -> Bool {
        active && percent.isFinite && (0...100).contains(percent) && rpm.isFinite && (500...15000).contains(rpm) && timestamp.isFinite && (0...6).contains(now - timestamp)
    }
}
struct FanInfo {
    let id: Int
    let minimum: Double
    let maximum: Double
    let modeKey: String
    func target(_ percent: Double) -> Double { minimum + (maximum - minimum) * min(100, max(0, percent)) / 100 }
}
func machineModel() -> String {
    var n = 0
    guard sysctlbyname("hw.model", nil, &n, nil, 0) == 0 else { return "Unknown" }
    var bytes = [CChar](repeating: 0, count: n)
    guard sysctlbyname("hw.model", &bytes, &n, nil, 0) == 0 else { return "Unknown" }
    return String(cString: bytes)
}
func fans(_ smc: SMC) throws -> [FanInfo] {
    guard let count = smc.getValue("FNum"), count == 2 else { throw FanFailure(message: "Could not read both fans on this Mac.") }
    return try (0..<2).map { i in
        let key = smc.fanModeKey(i)
        guard let lo = smc.getValue("F\(i)Mn"), let hi = smc.getValue("F\(i)Mx"),
              lo.isFinite, hi.isFinite, lo >= 500, hi > lo, hi < 15000,
              let mode = smc.getValue(key), [0.0, 1.0, 3.0].contains(mode) else {
            throw FanFailure(message: "Fan \(i + 1) does not expose the expected controls.")
        }
        return FanInfo(id: i, minimum: lo, maximum: hi, modeKey: key)
    }
}


// The active helper checks for external target changes at most every five seconds.
struct FanVerificationGate {
    private var lastAction: FanAction?
    private var lastTime = -Double.infinity
    mutating func shouldVerify(action: FanAction, now: Double) -> Bool {
        guard action != lastAction || now < lastTime || now - lastTime >= 5 else { return false }
        lastAction = action; lastTime = now; return true
    }
    mutating func reset() { lastAction = nil; lastTime = -Double.infinity }
}
func reconcileFanTarget(target: Double, read: () -> FanReadback, write: () throws -> Void) throws {
    if !read().matches(target) { try write() }
}
func sensorInterval(detailsVisible: Bool, power: PowerSupply) -> TimeInterval {
    1 // CPU menu-bar temperature stays live on both power sources.
}
