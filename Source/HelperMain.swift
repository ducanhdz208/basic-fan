import Foundation
import Darwin

final class Session: NSObject, FanHelperProtocol {
    let id = UUID()
    let server: HelperServer
    init(_ server: HelperServer) { self.server = server }
    func ping(withReply reply: @escaping (String) -> Void) { reply("Basic Fan helper 1.0.0 RC3 ready") }
    func update(mode: String, percent: Double, rpm: Double, suspended: Bool, withReply reply: @escaping (String) -> Void) {
        server.queue.async {
            let status = self.server.engine.update(owner: self.id, mode: mode, percent: percent, rpm: rpm, suspended: suspended, now: Date().timeIntervalSince1970)
            self.server.scheduleWatchdog()
            reply(status)
        }
    }
}
final class HelperServer: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "local.basicfan.hardware")
    private var lastEnvironmentCheck = Date.distantPast
    private var supply = powerSupply()
    private var thermal = ProcessInfo.processInfo.thermalState
    lazy var engine = FanEngine(driver: HardwareFanDriver(), power: { [unowned self] in self.supply }, hot: { [unowned self] in
        self.thermal == .serious || self.thermal == .critical
    })
    private var powerObserver: PowerObserver?
    private var thermalObserver: NSObjectProtocol?
    var timer: DispatchSourceTimer?
    var signals: [DispatchSourceSignal] = []
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier >= 500 else { return false }
        // The OS validates every message against the exact signed app built with this helper.
        // Client PIDs and user-controlled filesystem paths are never used for authentication.
        connection.setCodeSigningRequirement(expectedAppRequirement)
        let session = Session(self)
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self] in
            self?.queue.async { self?.engine.disconnect(session.id); self?.scheduleWatchdog() }
        }
        connection.interruptionHandler = { [weak self] in
            self?.queue.async { self?.engine.disconnect(session.id); self?.scheduleWatchdog() }
        }
        connection.resume()
        return true
    }
    func scheduleWatchdog() {
        if !engine.requiresService { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2), leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastEnvironmentCheck) >= 10 {
                self.supply = powerSupply(); self.thermal = ProcessInfo.processInfo.thermalState
                self.lastEnvironmentCheck = Date()
            }
            self.engine.tick(now: Date().timeIntervalSince1970)
            self.scheduleWatchdog()
        }
        timer.resume(); self.timer = timer
    }
    private func environmentChanged() {
        let supply = powerSupply(), thermal = ProcessInfo.processInfo.thermalState
        queue.async { [weak self] in
            guard let self else { return }
            self.supply = supply; self.thermal = thermal; self.lastEnvironmentCheck = Date()
            self.engine.tick(now: Date().timeIntervalSince1970)
            self.scheduleWatchdog()
        }
    }
    func start() {
        powerObserver = PowerObserver { [weak self] in self?.environmentChanged() }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in self?.environmentChanged() }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.engine.stop(); exit(0) }
            source.resume(); signals.append(source)
        }
    }
}
@main struct HelperMain {
    static func main() {
        guard geteuid() == 0 else { fputs("Basic Fan helper must be started by the system.\n", stderr); exit(1) }
        let server = HelperServer()
        let listener = NSXPCListener(machServiceName: helperServiceName)
        listener.delegate = server
        server.start(); listener.resume()
        withExtendedLifetime(server) { RunLoop.main.run() }
    }
}
