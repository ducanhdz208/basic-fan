import Foundation

struct SensorSnapshot {
    var cpu: Double?
    var gpu: Double?
    var speeds: [String] = []
    var controls: [FanInfo] = []
    var automatic: Bool?
    var supported = false
    var failure: String?
}
// Used only on the sensor queue. Bounds and model identity do not change each second.
final class SensorReader {
    private lazy var smc = SMC()
    private lazy var supported = ["MacBookPro18,1", "MacBookPro18,2"].contains(machineModel())
    private var controls: [FanInfo] = []
    func sample(details: Bool) -> SensorSnapshot {
        var result = SensorSnapshot()
        result.cpu = cpuTemperature(smc)
        result.supported = supported
        do {
            if controls.isEmpty { controls = try fans(smc) }
            result.controls = controls
            if details {
                result.gpu = gpuTemperature(smc)
                result.speeds = controls.map { fan in
                    guard let rpm = smc.getValue("F\(fan.id)Ac"), rpm.isFinite else { return "—" }
                    return "\(Int(rpm.rounded()))"
                }
                result.automatic = controls.allSatisfy { [0.0, 3.0].contains(smc.getValue($0.modeKey) ?? -1) }
            }
        } catch { result.failure = error.localizedDescription }
        return result
    }
}
