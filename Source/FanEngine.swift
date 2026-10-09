import Foundation
import Darwin

protocol FanDriver: AnyObject {
    func begin() throws
    func apply(_ action: FanAction) throws
    func finish() throws
}
final class HardwareFanDriver: FanDriver {
    private lazy var smc = SMC()
    private var verificationGate = FanVerificationGate()
    private var controls: [FanInfo] = []
    private var lock: Int32 = -1
    private var dirty = false
    func begin() throws {
        guard ["MacBookPro18,1", "MacBookPro18,2"].contains(machineModel()) else { throw FanFailure(message: "Unsupported Mac model.") }
        lock = open("/var/run/local.basicfan.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw FanFailure(message: "Could not acquire fan control.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock); lock = -1
            throw FanFailure(message: "Quit the old Basic Fan version before using this update.")
        }
        do {
            controls = try fans(smc)
            guard controls.allSatisfy({ [0.0, 3.0].contains(smc.getValue($0.modeKey) ?? -1) }) else {
                throw FanFailure(message: "Restore Automatic in your other fan app first.")
            }
        } catch { close(lock); lock = -1; throw error }
    }
    func apply(_ action: FanAction) throws {
        if case .rpm(let rpm) = action {
            guard controls.allSatisfy({ rpm >= $0.minimum && rpm <= $0.maximum }) else {
                throw FanFailure(message: "Requested RPM is outside the shared range of both fans.")
            }
        }
        if action == .automatic { try restore(); verificationGate.reset(); return }
        guard verificationGate.shouldVerify(action: action, now: ProcessInfo.processInfo.systemUptime) else { return }
        for fan in controls {
            let target: Double
            switch action {
            case .rpm(let rpm): target = rpm
            case .percent(let percent): target = fan.target(percent).rounded()
            case .automatic: return
            }
            try reconcileFanTarget(target: target, read: {
                FanReadback(mode: self.smc.getValue(fan.modeKey), target: self.smc.getValue("F\(fan.id)Tg"))
            }, write: {
                self.dirty = true
                try self.smc.basicManualRPM(fan, rpm: target)
            })
        }
    }
    private func restore() throws {
        guard dirty else { return }
        var errors: [String] = []
        for fan in controls {
            do { try smc.basicAutomatic(fan) } catch { errors.append(error.localizedDescription) }
        }
        guard errors.isEmpty else { throw FanFailure(message: errors.joined(separator: " ")) }
        dirty = false
    }
    func finish() throws {
        try restore()
        if lock >= 0 { close(lock); lock = -1 }
        controls = []
        verificationGate.reset()
    }
}
// All methods run on one serial queue. Leases use server receipt time, never a client timestamp.
final class FanEngine {
    private let driver: FanDriver
    private let power: () -> PowerSupply
    private let hot: () -> Bool
    private var owner: UUID?
    private var command: Command?
    private var received: Double = 0
    private var previousTick: Double?
    private var needsCleanup = false
    private(set) var status = "AUTOMATIC"
    var requiresService: Bool { command != nil || needsCleanup }
    init(driver: FanDriver, power: @escaping () -> PowerSupply, hot: @escaping () -> Bool) {
        self.driver = driver; self.power = power; self.hot = hot
    }
    func update(owner client: UUID, mode: String, percent: Double, rpm: Double = 2000, suspended: Bool, now: Double) -> String {
        guard owner == nil || owner == client else { return "ERROR: Another Basic Fan window owns the fan session." }
        guard ["automatic", "manual", "pluggedIn"].contains(mode), percent.isFinite, (0...100).contains(percent), rpm.isFinite, (500...15000).contains(rpm) else {
            if owner == client { stop() }
            return "ERROR: Invalid fan command."
        }
        if mode == "automatic" { stop(); return status }
        if needsCleanup { stop(); if needsCleanup { return status } }
        do {
            if owner == nil { try driver.begin(); owner = client }
            let changed = command == nil || command?.mode.rawValue != mode || command?.percent != percent || command?.rpm != rpm || command?.suspended != suspended
            command = Command(percent: percent, timestamp: now, active: true, mode: ControlMode(rawValue: mode)!, suspended: suspended, rpm: rpm)
            received = now
            if changed { tick(now: now) }
        } catch { fail(error) }
        return status
    }
    func tick(now: Double) {
        if needsCleanup { stop(); return }
        guard let command else { previousTick = now; return }
        do {
            if let prior = previousTick, now - prior > 3 || now < prior { try driver.apply(.automatic) }
            previousTick = now
            guard (0...6).contains(now - received) else { stop(); return }
            let supply = power(), thermal = hot()
            let action = fanAction(command: command, power: supply, hot: thermal)
            try driver.apply(action)
            switch action {
            case .rpm: status = "PLUGGED_IN"
            case .percent: status = "MANUAL"
            case .automatic:
                status = command.suspended ? "PAUSED" : thermal ? "THERMAL" : supply == .battery ? "BATTERY" : "POWER_UNKNOWN"
            }
        } catch { fail(error) }
    }
    func disconnect(_ client: UUID) { if owner == client { stop() } }
    func stop() {
        command = nil
        do {
            try driver.finish()
            needsCleanup = false; owner = nil; status = "AUTOMATIC"
        } catch {
            needsCleanup = true
            status = "ERROR: Automatic could not be confirmed. \(error.localizedDescription) Restart the Mac if this persists."
        }
    }
    private func fail(_ error: Error) {
        stop()
        status = "ERROR: \(error.localizedDescription)\(needsCleanup ? " Automatic restoration is still being retried." : " Automatic restored.")"
    }
}
