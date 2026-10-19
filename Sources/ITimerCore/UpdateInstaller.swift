import CryptoKit
import Foundation

public struct UpdateError: LocalizedError, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The file-system half of an update: check the downloaded DMG, copy the
/// app out of it, and swap it for the running bundle. Everything here
/// blocks; call it off the main thread.
public enum UpdateInstaller {
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Why `app` can't be replaced where it is, or nil when it can.
    public static func inPlaceProblem(for app: URL) -> String? {
        guard app.pathExtension == "app" else { return "iTimer 不是从应用包运行的" }
        // Gatekeeper runs a quarantined app that was never moved from a
        // read-only copy; replacing that copy would not stick.
        if app.path.contains("/AppTranslocation/") { return "iTimer 还没有拖进「应用程序」" }
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { return "没有写入「\(folder.path)」的权限" }
        // Moving a folder to another parent rewrites its `..`, so the
        // bundle itself must be writable too (another user may own it).
        guard FileManager.default.isWritableFile(atPath: app.path) else { return "没有修改「\(app.path)」的权限" }
        return nil
    }

    /// Mounts `dmg` (its SHA-256 already checked), checks the app inside is
    /// `bundleID` at `version` with an intact signature, and copies it onto
    /// `target`'s volume, so the swap is a rename. Returns the copy.
    public static func stage(dmg: URL, version: AppVersion, bundleID: String, replacing target: URL) throws -> URL {
        let mount = try attach(dmg)
        defer { detach(mount) }
        let source = mount.appendingPathComponent("iTimer.app", isDirectory: true)
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError("安装包里没有找到 iTimer。")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError("安装包里的应用不是 iTimer。")
        }
        guard (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == version else {
            throw UpdateError("安装包里的版本不是 \(version)。")
        }
        let folder = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: target,
            create: true
        )
        let staged = folder.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: source, to: staged)
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], failure: "安装包里的应用签名不完整。")
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return staged
    }

    /// Puts `staged` where `target` is. The old copy is moved aside first
    /// and put back if the new one can't take its place.
    public static func swap(_ target: URL, with staged: URL) throws {
        let files = FileManager.default
        let folder = staged.deletingLastPathComponent()
        let previous = folder.appendingPathComponent("previous-\(target.lastPathComponent)", isDirectory: true)
        do {
            try files.moveItem(at: target, to: previous)
        } catch {
            throw UpdateError("无法移走旧版本：\(error.localizedDescription)")
        }
        do {
            try files.moveItem(at: staged, to: target)
        } catch {
            try? files.moveItem(at: previous, to: target)
            throw UpdateError("无法放入新版本：\(error.localizedDescription)")
        }
        try? files.removeItem(at: folder)
    }

    /// Mounted out of sight. `-noverify` skips the image's own checksums
    /// (seconds): the caller has already checked the whole file's SHA-256.
    private static func attach(_ dmg: URL) throws -> URL {
        let output = try run(
            "/usr/bin/hdiutil",
            ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountrandom", NSTemporaryDirectory(), "-plist"],
            failure: "无法打开安装包。"
        )
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError("无法打开安装包。")
        }
        return URL(fileURLWithPath: mount, isDirectory: true)
    }

    private static func detach(_ mount: URL) {
        if (try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"], failure: "")) == nil {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"], failure: "")
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], failure: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError(failure) }
        return data
    }
}
