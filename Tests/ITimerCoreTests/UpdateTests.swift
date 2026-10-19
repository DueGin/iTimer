import XCTest
@testable import ITimerCore

final class UpdateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("itimer-update-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testVersionsParseTagsAndCompareNumerically() throws {
        XCTAssertEqual(AppVersion("v1.11.0"), AppVersion(1, 11, 0))
        XCTAssertEqual(AppVersion(" 1.2 "), AppVersion(1, 2, 0))
        XCTAssertEqual(AppVersion("2"), AppVersion(2, 0, 0))
        XCTAssertEqual(AppVersion(1, 10, 5).description, "1.10.5")
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.9.9")), try XCTUnwrap(AppVersion("1.10.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.10.5")), try XCTUnwrap(AppVersion("v1.11.0")))
        for bad in ["", "v", "1..2", "1.2.3.4", "1.2.0-beta", "+1.0.0", "1.-2.0", "一.二.三"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    func testOfferIsNewestPublishedReleaseWithThisArchitecturesDMG() throws {
        let releases = try GitHubRelease.list(from: Data(Self.releasesJSON.utf8))
        XCTAssertEqual(releases.count, 6)

        let arm = try XCTUnwrap(UpdateCatalog.offer(in: releases, current: AppVersion(1, 11, 0), architecture: "arm64"))
        XCTAssertEqual(arm.version, AppVersion(1, 12, 1))
        XCTAssertEqual(arm.installer.name, "iTimer-1.12.1-macos-arm64.dmg")
        XCTAssertEqual(arm.installer.size, 2_900_000)
        XCTAssertEqual(arm.pageURL.absoluteString, "https://github.com/DueGin/iTimer/releases/tag/v1.12.1")
        XCTAssertEqual(arm.publishedAt, Date(timeIntervalSince1970: 1_792_400_000))
        XCTAssertNil(arm.checksums)
        // Drafts and prereleases are skipped; notes cover every newer version.
        XCTAssertEqual(arm.notes.map(\.version), [AppVersion(1, 12, 1), AppVersion(1, 12, 0), AppVersion(1, 11, 1)])

        // 1.12.1 has no Intel DMG yet: Intel Macs are offered 1.12.0.
        let intel = try XCTUnwrap(UpdateCatalog.offer(in: releases, current: AppVersion(1, 11, 0), architecture: "x86_64"))
        XCTAssertEqual(intel.version, AppVersion(1, 12, 0))
        XCTAssertEqual(intel.installer.digest, nil)
        XCTAssertEqual(intel.checksums?.name, "SHA256SUMS")
        XCTAssertEqual(intel.notes.map(\.version), [AppVersion(1, 12, 0), AppVersion(1, 11, 1)])

        XCTAssertNil(UpdateCatalog.offer(in: releases, current: AppVersion(1, 12, 1), architecture: "arm64"))
        XCTAssertNil(UpdateCatalog.offer(in: releases, current: AppVersion(1, 12, 0), architecture: "x86_64"))
        XCTAssertNil(UpdateCatalog.offer(in: releases, current: AppVersion(2, 0, 0), architecture: "arm64"))
    }

    func testChecksumsComeFromDigestOrSHA256SUMS() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(Checksum.sha256(digest: "sha256:\(hex)"), hex)
        XCTAssertEqual(Checksum.sha256(digest: "SHA256:\(hex.uppercased())"), hex)
        XCTAssertNil(Checksum.sha256(digest: nil))
        XCTAssertNil(Checksum.sha256(digest: "md5:\(hex)"))
        XCTAssertNil(Checksum.sha256(digest: "sha256:abc"))

        let other = String(repeating: "0", count: 64)
        let sums = """
        \(other)  iTimer-1.12.0-macos-arm64.dmg
        \(hex.uppercased()) *iTimer-1.12.0-macos-x86_64.dmg

        """
        XCTAssertEqual(Checksum.sha256(sums: sums, name: "iTimer-1.12.0-macos-arm64.dmg"), other)
        XCTAssertEqual(Checksum.sha256(sums: sums, name: "iTimer-1.12.0-macos-x86_64.dmg"), hex)
        XCTAssertNil(Checksum.sha256(sums: sums, name: "iTimer-1.12.0-macos.dmg"))
        XCTAssertNil(Checksum.sha256(sums: "zz  iTimer.dmg", name: "iTimer.dmg"))
    }

    func testReleaseNotesDropTheDownloadSection() {
        let body = """
        ### 新增

        - 软件更新：在设置里检查新版本。
        - 带 `代码` 的一条，
          换行接着写。

        说明文字。

        ### 下载与安装

        | Mac 芯片 | 安装包 |
        |---|---|
        """
        XCTAssertEqual(ReleaseNotes.blocks(from: body), [
            .heading("新增"),
            .item("软件更新：在设置里检查新版本。"),
            .item("带 `代码` 的一条， 换行接着写。"),
            .text("说明文字。"),
        ])
        XCTAssertEqual(ReleaseNotes.blocks(from: ""), [])
    }

    func testSHA256OfAFile() throws {
        let file = directory.appendingPathComponent("hello.txt")
        try Data("hello\n".utf8).write(to: file)
        XCTAssertEqual(try UpdateInstaller.sha256(of: file), "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    func testInPlaceProblems() throws {
        let app = directory.appendingPathComponent("iTimer.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNil(UpdateInstaller.inPlaceProblem(for: app))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.path)
        XCTAssertNotNil(UpdateInstaller.inPlaceProblem(for: app))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        XCTAssertNotNil(UpdateInstaller.inPlaceProblem(for: directory.appendingPathComponent("iTimer")))
        XCTAssertNotNil(UpdateInstaller.inPlaceProblem(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/iTimer.app")))

        let locked = directory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertNotNil(UpdateInstaller.inPlaceProblem(for: locked.appendingPathComponent("iTimer.app")))
    }

    /// The whole file-system path against a real DMG: mount, check, copy
    /// out, swap; the old bundle goes away and the new one stays signed.
    func testStageFromDMGThenSwapReplacesTheBundle() throws {
        let installed = try makeApp(version: "1.11.0", in: directory.appendingPathComponent("Applications"))
        let release = try makeApp(version: "1.12.0", in: directory.appendingPathComponent("release"))
        let dmg = directory.appendingPathComponent("iTimer-1.12.0-macos-arm64.dmg")
        try shell("/usr/bin/hdiutil", "create", "-volname", "iTimer 1.12.0", "-srcfolder", release.deletingLastPathComponent().path, "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path)

        XCTAssertThrowsError(try UpdateInstaller.stage(dmg: dmg, version: AppVersion(1, 12, 1), bundleID: Self.bundleID, replacing: installed)) {
            XCTAssertEqual($0 as? UpdateError, UpdateError("安装包里的版本不是 1.12.1。"))
        }
        XCTAssertThrowsError(try UpdateInstaller.stage(dmg: dmg, version: AppVersion(1, 12, 0), bundleID: "com.example.other", replacing: installed))

        let staged = try UpdateInstaller.stage(dmg: dmg, version: AppVersion(1, 12, 0), bundleID: Self.bundleID, replacing: installed)
        XCTAssertEqual(try version(of: staged), "1.12.0")
        try UpdateInstaller.swap(installed, with: staged)
        XCTAssertEqual(try version(of: installed), "1.12.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        try shell("/usr/bin/codesign", "--verify", "--deep", "--strict", installed.path)
        // Unmounted afterwards.
        let mounts = try shell("/usr/bin/hdiutil", "info")
        XCTAssertFalse(mounts.contains(dmg.path))
    }

    func testSwapPutsTheOldCopyBackWhenTheNewOneCannotMoveIn() throws {
        let installed = try makeApp(version: "1.11.0", in: directory.appendingPathComponent("Applications"))
        let missing = directory.appendingPathComponent("staging/iTimer.app")
        try FileManager.default.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateInstaller.swap(installed, with: missing))
        XCTAssertEqual(try version(of: installed), "1.11.0")
    }

    // MARK: fixtures

    private static let bundleID = "app.duegin.itimer.tests"

    /// A minimal ad-hoc signed app bundle.
    private func makeApp(version: String, in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent("iTimer.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": Self.bundleID,
            "CFBundleExecutable": "iTimer",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("iTimer")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try shell("/usr/bin/codesign", "--force", "--sign", "-", app.path)
        return app
    }

    private func version(of app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }

    @discardableResult
    private func shell(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
        return String(decoding: data, as: UTF8.self)
    }

    /// Trimmed to the fields the updater reads, newest first like the API.
    private static let releasesJSON = """
    [
      {
        "tag_name": "v1.14.0", "name": "iTimer 1.14.0", "body": "草稿", "draft": true, "prerelease": false,
        "html_url": "https://github.com/DueGin/iTimer/releases/tag/v1.14.0", "published_at": null,
        "assets": [{"name": "iTimer-1.14.0-macos-arm64.dmg", "size": 1, "browser_download_url": "https://example.com/a.dmg", "digest": null}]
      },
      {
        "tag_name": "v1.13.0-beta", "name": "iTimer 1.13.0 beta", "body": "预览", "draft": false, "prerelease": false,
        "html_url": "https://github.com/DueGin/iTimer/releases/tag/v1.13.0-beta", "published_at": "2026-11-01T00:00:00Z",
        "assets": [{"name": "iTimer-1.13.0-macos-arm64.dmg", "size": 1, "browser_download_url": "https://example.com/b.dmg", "digest": null}]
      },
      {
        "tag_name": "v1.12.1", "name": "iTimer 1.12.1", "body": "### 修复\\n\\n- 修了一个问题。", "draft": false, "prerelease": false,
        "html_url": "https://github.com/DueGin/iTimer/releases/tag/v1.12.1", "published_at": "2026-10-19T08:53:20Z",
        "assets": [
          {"name": "iTimer-1.12.1-macos-arm64.dmg", "size": 2900000,
           "browser_download_url": "https://github.com/DueGin/iTimer/releases/download/v1.12.1/iTimer-1.12.1-macos-arm64.dmg",
           "digest": "sha256:50a4e8ff76707e3de88cf61fd3a2f1859ea82af1a5a1cb4e3fc20cc039de7714"}
        ]
      },
      {
        "tag_name": "v1.12.0", "name": "iTimer 1.12.0", "body": "### 新增\\n\\n- 软件更新。", "draft": false, "prerelease": false,
        "html_url": "https://github.com/DueGin/iTimer/releases/tag/v1.12.0", "published_at": "2026-10-19T00:00:00Z",
        "assets": [
          {"name": "iTimer-1.12.0-macos-arm64.dmg", "size": 2800000, "browser_download_url": "https://example.com/c.dmg"},
          {"name": "iTimer-1.12.0-macos-x86_64.dmg", "size": 3000000, "browser_download_url": "https://example.com/d.dmg"},
          {"name": "SHA256SUMS", "size": 193, "browser_download_url": "https://example.com/SHA256SUMS"}
        ]
      },
      {
        "tag_name": "v1.11.1", "name": "iTimer 1.11.1", "body": null, "draft": false, "prerelease": false,
        "html_url": "https://github.com/DueGin/iTimer/releases/tag/v1.11.1", "published_at": "2026-10-18T00:00:00Z",
        "assets": []
      },
      {
        "tag_name": "v1.11.0", "name": "iTimer 1.11.0", "body": "当前版本", "draft": false, "prerelease": false,
        "html_url": "https://github.com/DueGin/iTimer/releases/tag/v1.11.0", "published_at": "2026-10-17T00:00:00Z",
        "assets": [{"name": "iTimer-1.11.0-macos-arm64.dmg", "size": 1, "browser_download_url": "https://example.com/e.dmg"}]
      }
    ]
    """
}
