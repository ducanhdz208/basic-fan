import Foundation
import CryptoKit
@main struct UpdateTests {
    static func main() throws {
        var count = 0
        func check(_ ok: Bool, _ label: String) { precondition(ok, label); count += 1 }
        func fails(_ label: String, _ body: () throws -> Void) { do { try body(); fatalError(label) } catch { count += 1 } }
        check(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.9")!, "numeric version ordering")
        check(ReleaseVersion("v1.1.0")! == ReleaseVersion("1.1.0")!, "tag prefix")
        for invalid in ["1.1", "1.1.0-rc.1", "1.-1.0", "1.1.0+test", "1.1.0/../../", "999999999999999999999.1.0"] { check(ReleaseVersion(invalid) == nil, "reject invalid version") }
        let payload = Data("verified package fixture".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        func release(_ url: String = "https://github.com/ducanhdz208/basic-fan/releases/download/v1.2.0/Basic.Fan.1.2.0.pkg", digest: String? = nil, pre: Bool = false, draft: Bool = false, size: Int = 24) -> UpdateRelease {
            UpdateRelease(tag_name: "v1.2.0", draft: draft, prerelease: pre, assets: [.init(name: "Basic.Fan.1.2.0.pkg", browser_download_url: url, size: size, digest: digest ?? "sha256:\(hash)")])
        }
        check(try release().package().0 == ReleaseVersion("1.2.0")!, "accept official asset")
        fails("reject prerelease") { _ = try release(pre: true).package() }
        fails("reject draft") { _ = try release(draft: true).package() }
        fails("reject missing hash") { _ = try release(digest: "").package() }
        fails("reject oversize") { _ = try release(size: 100_000_001).package() }
        for url in ["http://github.com/ducanhdz208/basic-fan/releases/download/v1.2.0/Basic.Fan.1.2.0.pkg", "https://evil.example/Basic.Fan.1.2.0.pkg", "https://github.com/other/repo/releases/download/v1.2.0/Basic.Fan.1.2.0.pkg"] { fails("reject untrusted URL") { _ = try release(url).package() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateStore(root: root.appendingPathComponent("Updates")); try store.prepare()
        try payload.write(to: store.package)
        try verifyPackage(store.package, size: payload.count, digest: hash); count += 1
        fails("hash mismatch") { try verifyPackage(store.package, size: payload.count, digest: String(repeating: "0", count: 64)) }
        fails("size mismatch") { try verifyPackage(store.package, size: 1, digest: hash) }
        try store.record(ReleaseVersion("1.2.0")!)
        try store.cleanAfterSuccess(current: ReleaseVersion("1.1.0")!)
        check(FileManager.default.fileExists(atPath: store.package.path), "retain pending installer until update confirmed")
        let unrelated = store.root.appendingPathComponent("keep.txt"); try payload.write(to: unrelated)
        try store.cleanAfterSuccess(current: ReleaseVersion("1.2.0")!)
        check(!FileManager.default.fileExists(atPath: store.package.path), "remove verified successful update cache")
        check(FileManager.default.fileExists(atPath: unrelated.path), "preserve unrelated files")
        try store.clear(); count += 1 // repeated cleanup is safe
        let outside = root.appendingPathComponent("outside.txt"); try payload.write(to: outside)
        try FileManager.default.createSymbolicLink(at: store.package, withDestinationURL: outside)
        try store.clear()
        check(FileManager.default.fileExists(atPath: outside.path), "do not follow symlink during deletion")
        try FileManager.default.createDirectory(at: store.package, withIntermediateDirectories: false)
        fails("refuse recursive directory deletion") { try store.clear() }
        let linked = root.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: store.root)
        fails("reject symlink cache root") { try UpdateStore(root: linked).prepare() }
        print("\(count) updater checks passed. No network, installation or login-item changes performed.")
    }
}
