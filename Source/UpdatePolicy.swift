import Foundation
import CryptoKit

struct ReleaseVersion: Comparable {
    let parts: [Int]
    init?(_ text: String) {
        let raw = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              components.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = components.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    var text: String { parts.map(String.init).joined(separator: ".") }
}
struct UpdateRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int
        let digest: String?
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    func package() throws -> (ReleaseVersion, Asset, URL, String) {
        guard !draft, !prerelease, let version = ReleaseVersion(tag_name) else { throw UpdateFailure("The release is not a supported stable version.") }
        let name = "Basic.Fan.\(version.text).pkg"
        guard let asset = assets.first(where: { $0.name == name }), asset.size > 0, asset.size <= 100_000_000,
              let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/ducanhdz208/basic-fan/releases/download/\(tag_name)/\(name)",
              let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw UpdateFailure("This release is missing a valid installer or SHA-256 checksum.")
        }
        return (version, asset, url, String(digest.dropFirst(7)))
    }
}
struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func verifyPackage(_ file: URL, size: Int, digest: String) throws {
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    guard data.count == size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
        throw UpdateFailure("The installer failed verification. Nothing was installed.")
    }
}

// This store owns only two files. It never deletes app bundles, Downloads, or arbitrary paths.
struct UpdateStore {
    let root: URL
    var package: URL { root.appendingPathComponent("Update.pkg") }
    var receipt: URL { root.appendingPathComponent("Target.json") }
    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else { throw UpdateFailure("The update folder must not be a symbolic link.") }
    }
    func clear() throws {
        try prepare()
        for file in [package, receipt] where FileManager.default.fileExists(atPath: file.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType != .typeDirectory else { throw UpdateFailure("Unexpected directory in the update cache; cleanup stopped.") }
            // Removing a symlink removes only the link; never follow it during cleanup.
            try FileManager.default.removeItem(at: file)
        }
    }
    func record(_ version: ReleaseVersion) throws { try JSONEncoder().encode(version.text).write(to: receipt, options: .atomic) }
    func cleanAfterSuccess(current: ReleaseVersion) throws {
        try prepare()
        guard let data = try? Data(contentsOf: receipt), let value = try? JSONDecoder().decode(String.self, from: data),
              let target = ReleaseVersion(value), current >= target else { return }
        try clear()
    }
}
