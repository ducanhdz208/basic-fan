import AppKit
import SwiftUI
import Combine

final class FanModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    var temperature: Double?
    var gpu: Double?
    var power = powerSupply()
    var selectedMode: ControlMode = .manual
    var percent: Double = 50
    var fixedRPM: Double = 2000
    var rpmRange: ClosedRange<Double> {
        guard controls.count == 2 else { return 1499...5348 }
        return (controls.map { $0.minimum }.max()!)...(controls.map { $0.maximum }.min()!)
    }
    var speeds = ["—", "—"]
    var ranges = ["Reading…", "Reading…"]
    var message = "Reading fans…"
    var running = false
    var requested = false
    var available = false
    var error = false
    var onUpdate: (() -> Void)?
    private var suspended = false
    private var activity: NSObjectProtocol?
    private var monitoringActivity: NSObjectProtocol?
    private let sensorQueue = DispatchQueue(label: "local.basicfan.sensors", qos: .utility)
    private let reader = SensorReader()
    private var reading = false
    private var fullRefreshPending = false
    private var controls: [FanInfo] = []
    private var sensorTimer: Timer?
    private var heartbeatTimer: Timer?
    private var menuVisible = false
    private var windowVisible = false
    private var connection: NSXPCConnection?
    private var inFlight = false
    private var requestStarted = Date.distantPast
    private var queued = false
    private var observers: [NSObjectProtocol] = []
    private var powerObserver: PowerObserver?
    var detailsVisible: Bool { menuVisible || windowVisible }

    init() {
        monitoringActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Refresh the visible menu-bar CPU temperature every second")
        if let saved = UserDefaults.standard.object(forKey: "fixedRPM") as? Double, saved.isFinite, (500...15000).contains(saved) { fixedRPM = saved }
        scheduleSensors(); refresh(details: true)
        powerObserver = PowerObserver { [weak self] in
            guard let self else { return }
            self.power = powerSupply(); self.scheduleSensors()
            if self.running { self.writeRequest() }
            self.onUpdate?()
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspended = true; self?.sensorTimer?.invalidate(); self?.writeRequest()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.suspended = false; self.power = powerSupply(); self.scheduleSensors()
            self.writeRequest(); self.refresh(details: self.detailsVisible)
        })
    }
    func visibility(menu: Bool? = nil, window: Bool? = nil) {
        let old = detailsVisible
        if let menu { menuVisible = menu }
        if let window { windowVisible = window }
        if old != detailsVisible { scheduleSensors() }
        if detailsVisible { refresh(details: true) }
    }
    private func scheduleSensors() {
        sensorTimer?.invalidate()
        guard !suspended else { return }
        let interval = sensorInterval(detailsVisible: detailsVisible, power: power)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }; self.refresh(details: self.detailsVisible)
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common); sensorTimer = timer
    }
    func refresh(details: Bool) {
        guard !suspended else { return }
        if reading { fullRefreshPending = fullRefreshPending || details; return }
        reading = true
        sensorQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.reader.sample(details: details)
            DispatchQueue.main.async {
                self.reading = false; self.temperature = snapshot.cpu
                self.controls = snapshot.controls
                if !snapshot.controls.isEmpty { self.fixedRPM = min(self.rpmRange.upperBound, max(self.rpmRange.lowerBound, self.fixedRPM)) }
                self.available = snapshot.supported && snapshot.failure == nil
                for fan in snapshot.controls { self.ranges[fan.id] = "\(Int(fan.minimum))–\(Int(fan.maximum)) RPM" }
                if details { self.gpu = snapshot.gpu; if snapshot.speeds.count == 2 { self.speeds = snapshot.speeds } }
                if !self.running && !self.error {
                    if let failure = snapshot.failure { self.message = "Fan sensors unavailable. \(failure)" }
                    else if !snapshot.supported { self.message = "This build supports 16-inch M1 Pro / Max MacBook Pro." }
                    else if let automatic = snapshot.automatic {
                        self.message = automatic ? "Automatic · macOS controls cooling" : "Another fan session is active. Restore Automatic there first."
                    }
                }
                self.onUpdate?()
                if self.fullRefreshPending { self.fullRefreshPending = false; self.refresh(details: true) }
            }
        }
    }
    func targetText(_ index: Int) -> String {
        guard controls.indices.contains(index) else { return "—" }
        return "\(Int(controls[index].target(percent).rounded())) RPM"
    }
    func setPercent(_ value: Double) {
        percent = value
        if running && requested && selectedMode == .manual { writeRequest() }
        onUpdate?()
    }
    func setFixedRPM(_ value: Double) {
        guard value.isFinite, rpmRange.contains(value) else { return }
        guard value.rounded() != fixedRPM else { return }
        fixedRPM = value.rounded()
        UserDefaults.standard.set(fixedRPM, forKey: "fixedRPM")
        if running && requested && selectedMode == .pluggedIn { writeRequest() }
        onUpdate?()
    }
    private func connect() {
        guard connection == nil else { return }
        let link = NSXPCConnection(machServiceName: helperServiceName, options: .privileged)
        link.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        link.setCodeSigningRequirement("identifier \"local.basicfan.helper\"")
        link.invalidationHandler = { [weak self, weak link] in
            DispatchQueue.main.async {
                guard let self, let link, self.connection === link else { return }
                self.connection = nil; if self.running { self.connectionFailed() }
            }
        }
        link.interruptionHandler = { [weak self, weak link] in
            DispatchQueue.main.async {
                guard let self, let link, self.connection === link else { return }
                self.connectionFailed()
            }
        }
        connection = link; link.resume()
    }
    private func maintainSession() {
        guard heartbeatTimer == nil else { return }
        // Prevent timer suspension only while this app owns a fan-control session.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Maintain the fan-control safety heartbeat")
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.inFlight && Date().timeIntervalSince(self.requestStarted) > 8 { self.connectionFailed(); return }
            self.writeRequest()
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common); heartbeatTimer = timer
    }
    private func endSession() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func connectionFailed() {
        requested = false; running = false; inFlight = false; queued = false; error = true
        endSession()
        message = "Helper unavailable. Install the matching Basic Fan.pkg, then reopen Basic Fan from Applications."
        let old = connection; connection = nil; old?.invalidate(); onUpdate?()
    }
    private func writeRequest() {
        guard running else { return }
        if inFlight { queued = true; return }
        connect(); guard let connection else { return }
        inFlight = true; requestStarted = Date()
        let mode = requested ? selectedMode.rawValue : "automatic"
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }; self.connectionFailed()
            }
        } as? FanHelperProtocol
        guard let proxy else { connectionFailed(); return }
        proxy.update(mode: mode, percent: percent, rpm: fixedRPM, suspended: suspended) { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.connection === connection else { return }
                self.inFlight = false
                if status.hasPrefix("ERROR:") {
                    self.error = true; self.requested = false; self.running = false; self.endSession()
                    self.message = String(status.dropFirst(7))
                    let old = self.connection; self.connection = nil; old?.invalidate()
                } else if mode == "automatic" {
                    self.running = false; self.requested = false; self.endSession(); self.message = "Automatic · macOS controls cooling"
                } else if self.requested {
                    switch status {
                    case "MANUAL": self.message = "Manual · both fans"
                    case "PLUGGED_IN": self.message = "Plugged in · both fans set to \(Int(self.fixedRPM)) RPM"
                    case "BATTERY": self.message = "On battery · Automatic cooling"
                    case "THERMAL": self.message = "Mac is hot · Automatic cooling until it cools down"
                    case "PAUSED": self.message = "Sleep transition · Automatic cooling"
                    case "POWER_UNKNOWN": self.message = "Power source unavailable · Automatic cooling"
                    default: self.message = "Automatic · macOS controls cooling"
                    }
                }
                if self.queued { self.queued = false; self.writeRequest() }
                self.onUpdate?()
            }
        }
    }
    func manual() { start(.manual) }
    func pluggedInMode() { start(.pluggedIn) }
    func start(_ mode: ControlMode) {
        guard available, !running || requested else { return }
        error = false; selectedMode = mode; requested = true; running = true
        maintainSession(); message = "Applying fan mode…"; writeRequest(); onUpdate?()
    }
    func automatic() {
        requested = false
        if running { message = "Returning to Automatic…"; writeRequest() }
        else { error = false; refresh(details: true) }
        onUpdate?()
    }
    func shutdown() {
        sensorTimer?.invalidate(); automatic()
        let limit = Date().addingTimeInterval(2)
        while running && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        connection?.invalidate(); connection = nil; endSession()
        if let monitoringActivity { ProcessInfo.processInfo.endActivity(monitoringActivity); self.monitoringActivity = nil }
    }
}

private typealias ViewState<Value> = SwiftUI.State<Value>

struct FanView: View {
    @ObservedObject var model: FanModel
    @ViewState private var rpmText = ""
    @ViewState private var rpmError: String?
    @FocusState private var editingRPM: Bool
    private func commitRPM() {
        guard let value = Double(rpmText), value.isFinite, value.rounded() == value, model.rpmRange.contains(value) else {
            rpmError = "Enter \(Int(model.rpmRange.lowerBound))–\(Int(model.rpmRange.upperBound)) RPM."
            return
        }
        rpmError = nil; model.setFixedRPM(value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "fanblades.fill").font(.system(size: 34)).foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Basic Fan").font(.system(size: 25, weight: .semibold))
                    Text("MacBook Pro · M1 Max").font(.subheadline).foregroundColor(.secondary)
                    Text("CPU \(model.temperature.map { String(format: "%.0f°C", $0) } ?? "—") · GPU \(model.gpu.map { String(format: "%.0f°C", $0) } ?? "—")")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                ForEach(0..<2) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FAN \(i + 1)").font(.caption.weight(.medium)).foregroundColor(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(model.speeds[i]).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                            Text("RPM").font(.caption).foregroundColor(.secondary)
                        }
                        Text(model.ranges[i]).font(.caption).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(Color.primary.opacity(0.045)).cornerRadius(14)
                }
            }
            Toggle("\(Int(model.fixedRPM)) RPM when plugged in", isOn: Binding(
                get: { model.running && model.requested && model.selectedMode == .pluggedIn },
                set: { $0 ? model.pluggedInMode() : model.automatic() }
            )).toggleStyle(.switch).disabled(!model.available || (model.running && !model.requested))
            Text("Both fans at \(Int(model.fixedRPM)) RPM on power. Automatic on battery.")
                .font(.caption).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Plugged-in speed").font(.subheadline)
                    Spacer()
                    TextField("RPM", text: $rpmText)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .frame(width: 76).focused($editingRPM).onSubmit { commitRPM() }
                        .accessibilityLabel("Plugged-in fan speed in RPM")
                    Text("RPM").font(.caption).foregroundColor(.secondary)
                    Stepper("", value: Binding(get: { model.fixedRPM }, set: { model.setFixedRPM($0) }), in: model.rpmRange, step: 100)
                        .labelsHidden().fixedSize().accessibilityLabel("Adjust plugged-in RPM")
                }
                Text(rpmError ?? "\(Int(model.rpmRange.lowerBound))–\(Int(model.rpmRange.upperBound)) RPM · saved automatically")
                    .font(.caption).foregroundColor(rpmError == nil ? .secondary : .orange)
            }.disabled(!model.available)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Manual speed").font(.headline); Spacer(); Text("\(Int(model.percent))%").monospacedDigit().foregroundColor(.secondary) }
                Slider(value: Binding(get: { model.percent }, set: { model.setPercent($0) }), in: 0...100, step: 1).disabled(!model.available || (model.running && (!model.requested || model.selectedMode == .pluggedIn)))
                    .accessibilityLabel("Fan speed between hardware minimum and maximum")
                HStack { Text("Minimum"); Spacer(); Text("Maximum") }.font(.caption).foregroundColor(.secondary)
                Text("Manual targets: \(model.targetText(0)) · \(model.targetText(1))").font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button("Automatic") { model.automatic() }.buttonStyle(.bordered).controlSize(.large)
                    .disabled(model.running && !model.requested)
                Button(model.running && model.selectedMode == .manual ? "Manual active" : "Apply manual speed") { model.manual() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.available || (model.running && (!model.requested || model.selectedMode == .manual)))
            }.frame(maxWidth: .infinity)
            Text(model.message).font(.callout).foregroundColor(model.error ? .orange : .secondary).fixedSize(horizontal: false, vertical: true).frame(minHeight: 38, alignment: .topLeading)
            if model.error {
                Button("Copy error details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.message, forType: .string)
                }
            }
            Text("Closing this window keeps the app in the menu bar. Quit restores Automatic. CPU and GPU show average sensor temperatures.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(26).frame(width: 440)
            .onAppear { rpmText = String(Int(model.fixedRPM)) }
            .onChange(of: editingRPM) { editing in if !editing { commitRPM() } }
            .onChange(of: model.fixedRPM) { value in
                if !editingRPM { rpmText = String(Int(value)); rpmError = nil }
            }
    }
}

final class FanWindow: NSWindowController, NSWindowDelegate {
    private let model: FanModel
    private var lastState = ""
    init(model: FanModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 492, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Basic Fan 1.0.0 RC3"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: FanView(model: model))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func update() {
        guard window?.isVisible == true else { return }
        let state = "\(formatTemp(model.temperature))|\(formatTemp(model.gpu))|\(model.power)|\(model.speeds)|\(model.ranges)|\(model.percent)|\(model.fixedRPM)|\(model.running)|\(model.requested)|\(model.selectedMode)|\(model.available)|\(model.error)|\(model.message)"
        if state != lastState { lastState = state; model.objectWillChange.send() }
    }
    func windowWillClose(_ notification: Notification) {
        model.visibility(window: false)
        NSApplication.shared.setActivationPolicy(.accessory)
    }
    func windowDidMiniaturize(_ notification: Notification) { model.visibility(window: false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.visibility(window: true) }
}
func formatTemp(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))°C" } ?? "—°C" }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: FanModel!
    private var windowController: FanWindow?
    private var statusItem: NSStatusItem!
    private var menuVisible = false
    private let cpuItem = NSMenuItem(title: "Average CPU: —", action: nil, keyEquivalent: "")
    private let gpuItem = NSMenuItem(title: "Average GPU: —", action: nil, keyEquivalent: "")
    private let powerItem = NSMenuItem(title: "Power: —", action: nil, keyEquivalent: "")
    private let leftItem = NSMenuItem(title: "Left fan: — RPM", action: nil, keyEquivalent: "")
    private let rightItem = NSMenuItem(title: "Right fan: — RPM", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "Reading fans…", action: nil, keyEquivalent: "")
    private let modeItem = NSMenuItem(title: "2000 RPM when plugged in", action: #selector(powerMode), keyEquivalent: "")
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "BasicFanIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApplication.shared.applicationIconImage = icon }
        model = FanModel()
        let main = NSMenu(), root = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Basic Fan", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Open Basic Fan…", action: #selector(showWindow), keyEquivalent: "o").target = self
        appMenu.addItem(withTitle: "Quit Basic Fan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu; main.addItem(root)
        let fileItem = NSMenuItem(), fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu; main.addItem(fileItem)
        NSApplication.shared.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.toolTip = "Average CPU temperature · Click for fan status"
        let menu = NSMenu(); menu.delegate = self
        for item in [cpuItem, gpuItem, powerItem, .separator(), leftItem, rightItem, stateItem, .separator()] { menu.addItem(item) }
        modeItem.target = self; menu.addItem(modeItem)
        menu.addItem(withTitle: "Automatic", action: #selector(automaticMode), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Basic Fan…", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Basic Fan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        model.onUpdate = { [weak self] in self?.update() }
        update()
        if CommandLine.arguments.contains("--benchmark") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { NSApplication.shared.terminate(nil) }
        }
    }
    private func set(_ item: NSMenuItem, _ title: String) { if item.title != title { item.title = title } }
    func update() {
        let title = "CPU \(formatTemp(model.temperature))"
        if statusItem.button?.title != title { statusItem.button?.title = title }
        if menuVisible {
            set(cpuItem, "Average CPU: \(formatTemp(model.temperature))")
            set(gpuItem, "Average GPU: \(formatTemp(model.gpu))")
            set(powerItem, "Power: \(model.power.rawValue)")
            set(leftItem, "Left fan: \(model.speeds[0]) RPM")
            set(rightItem, "Right fan: \(model.speeds[1]) RPM")
            set(stateItem, model.message)
            set(modeItem, "\(Int(model.fixedRPM)) RPM when plugged in")
            modeItem.state = model.running && model.requested && model.selectedMode == .pluggedIn ? .on : .off
        }
        windowController?.update()
    }
    func menuWillOpen(_ menu: NSMenu) { menuVisible = true; model.visibility(menu: true); update() }
    func menuDidClose(_ menu: NSMenu) { menuVisible = false; model.visibility(menu: false) }
    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let channel = Bundle.main.object(forInfoDictionaryKey: "BasicFanReleaseChannel") as? String ?? ""
        let displayVersion = [version, channel].filter { !$0.isEmpty }.joined(separator: " ")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Basic Fan",
            .applicationVersion: displayVersion,
            .version: "",
            .credits: NSAttributedString(string: "❤️ Made with love by Jimmy Truong", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ])
        ])
    }
    @objc func showWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        if windowController == nil { windowController = FanWindow(model: model) }
        windowController?.window?.deminiaturize(nil)
        windowController?.showWindow(nil); model.visibility(window: true)
        windowController?.update(); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func powerMode() {
        if model.running && model.requested && model.selectedMode == .pluggedIn { model.automatic() } else { model.pluggedInMode() }
    }
    @objc func automaticMode() { model.automatic() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}
@main struct BasicFan {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--helper-check") {
            let link = NSXPCConnection(machServiceName: helperServiceName, options: .privileged)
            link.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            link.setCodeSigningRequirement("identifier \"local.basicfan.helper\"")
            let done = DispatchSemaphore(value: 0); var ok = false
            link.resume()
            let proxy = link.remoteObjectProxyWithErrorHandler { err in fputs("Helper unavailable: \(err.localizedDescription)\n", stderr); done.signal() } as? FanHelperProtocol
            proxy?.ping { reply in print(reply); ok = true; done.signal() }
            _ = done.wait(timeout: .now() + 5); link.invalidate(); exit(ok ? 0 : 1)
        }
        if args.contains("--probe") {
            let smc = SMC()
            print("Model: \(machineModel()); power: \(powerSupply().rawValue)")
            print("CPU: \(formatTemp(cpuTemperature(smc))); GPU: \(formatTemp(gpuTemperature(smc)))")
            do { for fan in try fans(smc) { print("Fan \(fan.id + 1): \(smc.getValue("F\(fan.id)Ac") ?? -1) RPM; mode \(smc.getValue(fan.modeKey) ?? -1)") } }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }; return
        }
        guard geteuid() != 0 else { exit(1) }
        let app = NSApplication.shared, delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
