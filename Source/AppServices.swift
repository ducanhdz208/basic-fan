import AppKit
import ServiceManagement

@MainActor final class AppServices: NSObject, NSMenuDelegate {
    private var busy = false
    private var timer: Timer?
    private let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let automatic = NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleChecks), keyEquivalent: "")
    private let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkNow), keyEquivalent: "")
    private let store = UpdateStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.basicfan.app/Updates", isDirectory: true))
    private var current: ReleaseVersion { ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")! }
    func menu() -> NSMenu {
        let menu = NSMenu(title: "Settings & Updates"); menu.delegate = self
        for item in [login, automatic, check] { item.target = self; menu.addItem(item) }
        return menu
    }
    func start() {
        cleanConfirmedInstallation()
        schedule()
    }
    private func cleanConfirmedInstallation() {
        guard Bundle.main.bundleURL.path == "/Applications/Basic Fan.app",
              FileManager.default.fileExists(atPath: store.receipt.path) else { return }
        let link = NSXPCConnection(machServiceName: helperServiceName, options: .privileged)
        link.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        link.setCodeSigningRequirement("identifier \"local.basicfan.helper\"")
        link.resume()
        let proxy = link.remoteObjectProxyWithErrorHandler { _ in link.invalidate() } as? FanHelperProtocol
        proxy?.ping { [weak self] reply in
            Task { @MainActor in
                defer { link.invalidate() }
                guard let self, reply == "Basic Fan helper \(self.current.text) ready" else { return }
                do { try self.store.cleanAfterSuccess(current: self.current) }
                catch { NSLog("Update cleanup: %@", error.localizedDescription) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { link.invalidate() }
    }
    func menuWillOpen(_ menu: NSMenu) {
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.title = SMAppService.mainApp.status == .requiresApproval ? "Launch at Login — Approval Needed…" : "Launch at Login"
        automatic.state = UserDefaults.standard.bool(forKey: "automaticUpdateChecks") ? .on : .off
        check.title = busy ? "Checking / Downloading…" : "Check for Updates…"
        check.isEnabled = !busy
    }
    @objc private func toggleLogin() {
        guard Bundle.main.bundleURL.path == "/Applications/Basic Fan.app" else { message("Install Basic Fan in Applications first."); return }
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { message("Could not change Launch at Login", error.localizedDescription) }
    }
    @objc private func toggleChecks() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "automaticUpdateChecks"), forKey: "automaticUpdateChecks")
        schedule()
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard UserDefaults.standard.bool(forKey: "automaticUpdateChecks") else { return }
        autoCheck()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.autoCheck() } }
        timer?.tolerance = 300
    }
    private func autoCheck() {
        guard Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastUpdateCheck") >= 86400 else { return }
        performCheck(manual: false)
    }
    @objc private func checkNow() { performCheck(manual: true) }
    private func message(_ title: String, _ detail: String = "") {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    private func performCheck(manual: Bool) {
        guard !busy else { return }; busy = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        Task {
            var interactive = manual
            defer { busy = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/ducanhdz208/basic-fan/releases/latest")!)
                request.timeoutInterval = 30
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("BasicFan/\(current.text)", forHTTPHeaderField: "User-Agent")
                let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 300
                let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { throw UpdateFailure("GitHub could not be reached or is limiting requests. Try again later.") }
                let release = try JSONDecoder().decode(UpdateRelease.self, from: data)
                let (version, asset, url, digest) = try release.package()
                guard version > current else { if manual { message("You’re up to date", "Basic Fan \(current.text)") }; return }
                let prompt = NSAlert(); prompt.messageText = "Basic Fan \(version.text) is available"
                prompt.informativeText = "Download and verify the installer, then quit Basic Fan and open macOS Installer. It replaces the app and helper in Applications and Library. Administrator approval is required. Reopen Basic Fan after installation; its temporary installer is then removed."
                prompt.addButton(withTitle: "Download Update"); prompt.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                guard prompt.runModal() == .alertFirstButtonReturn else { return }
                interactive = true
                try store.clear()
                do {
                    let (temp, result) = try await session.download(from: url)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    guard (result as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure("The installer download failed.") }
                    try verifyPackage(temp, size: asset.size, digest: digest)
                    try FileManager.default.moveItem(at: temp, to: store.package)
                    try store.record(version)
                } catch { try? store.clear(); throw error }
                let ready = NSAlert(); ready.messageText = "Update verified"
                ready.informativeText = "Basic Fan will quit and return the fans to Automatic. Complete the installer, then reopen Basic Fan from Applications. If you cancel installation, reopen your existing app to keep using it."
                ready.addButton(withTitle: "Quit & Open Installer"); ready.addButton(withTitle: "Cancel")
                guard ready.runModal() == .alertFirstButtonReturn else { try store.clear(); return }
                guard NSWorkspace.shared.open(store.package) else { try store.clear(); throw UpdateFailure("Could not open macOS Installer. Nothing was installed.") }
                NSApp.terminate(nil)
            } catch { if interactive { message("Update could not be completed", error.localizedDescription) } else { NSLog("Update check: %@", error.localizedDescription) } }
        }
    }
}
