import AppKit
import ITimerCore
import Observation

/// Looks for a newer iTimer on GitHub Releases, downloads the DMG for this
/// Mac, checks its SHA-256, swaps the app bundle in place and reopens it.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    static let releasesPage = URL(string: "https://github.com/DueGin/iTimer/releases")!
    private static let releasesAPI = URL(string: "https://api.github.com/repos/DueGin/iTimer/releases?per_page=20")!
    /// Automatic checks: once at launch, then whenever this much has passed.
    private static let checkInterval: TimeInterval = 24 * 3600

    enum Activity: Equatable {
        case idle
        case checking
        case downloading(received: Int64, total: Int64)
        case installing
    }

    /// How the last check or install ended, for 设置 to say.
    enum Outcome: Equatable {
        case upToDate
        case checkFailed(String)
        case installFailed(String)
        /// Downloaded and checked, but this copy can't be replaced where it
        /// is; the DMG was opened for a drag-install.
        case manual(String)
        /// In place; takes effect when iTimer opens again.
        case installed(AppVersion)
    }

    private(set) var offer: UpdateOffer?
    private(set) var activity: Activity = .idle
    private(set) var outcome: Outcome?
    private(set) var lastChecked: Date?

    let currentVersion: AppVersion
    let build: String
    /// `ITIMER_UPDATE_FEED` points the updater at another releases JSON
    /// (`file://` works) for testing; such a feed may serve `file://` assets.
    let feedOverridden: Bool
    private let feedURL: URL

    /// Runs once the new bundle is in place. Self-test swaps it out.
    var finishInstall: @MainActor (URL) throws -> Void = { try Updater.relaunch($0) }

    private var installWork: Task<Void, Never>?
    private var schedule: Task<Void, Never>?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        currentVersion = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) ?? AppVersion(0, 0, 0)
        build = info["CFBundleVersion"] as? String ?? "?"
        if let override = ProcessInfo.processInfo.environment["ITIMER_UPDATE_FEED"], let url = URL(string: override), !override.isEmpty {
            feedURL = url
            feedOverridden = true
        } else {
            feedURL = Self.releasesAPI
            feedOverridden = false
        }
        lastChecked = UserDefaults.standard.object(forKey: Preferences.updateLastChecked) as? Date
    }

    var isBusy: Bool { activity != .idle }

    /// A new version is already in place; this process still reports the
    /// old one, so checking again would offer the same release.
    var awaitsRelaunch: Bool {
        if case .installed? = outcome { return true }
        return false
    }

    // MARK: checking

    /// Checks at launch and then daily, while 自动检查更新 is on.
    func startAutomaticChecks() {
        guard schedule == nil else { return }
        schedule = Task {
            // Let launch settle first.
            try? await Task.sleep(for: .seconds(5))
            var first = true
            while !Task.isCancelled {
                let due = first || lastChecked.map { Date().timeIntervalSince($0) >= Self.checkInterval } ?? true
                if due, Preferences.enabled(Preferences.autoUpdateCheck) {
                    await check(userInitiated: false)
                }
                first = false
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// A background check keeps quiet when it fails: being offline is normal.
    func check(userInitiated: Bool = true) async {
        guard activity == .idle, !awaitsRelaunch else { return }
        activity = .checking
        if userInitiated { outcome = nil }
        defer { activity = .idle }
        do {
            var request = URLRequest(url: feedURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("iTimer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            try Self.requireSuccess(response)
            let releases = try GitHubRelease.list(from: data)
            offer = UpdateCatalog.offer(in: releases, current: currentVersion, architecture: Self.architecture)
            if offer == nil {
                outcome = .upToDate
            } else if case .upToDate? = outcome {
                outcome = nil
            }
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Preferences.updateLastChecked)
        } catch {
            if userInitiated { outcome = .checkFailed(Self.describe(error)) }
        }
    }

    // MARK: installing

    func install() {
        guard let offer, activity == .idle else { return }
        outcome = nil
        activity = .downloading(received: 0, total: offer.installer.size)
        installWork = Task {
            do {
                try await install(offer)
            } catch is CancellationError {
                activity = .idle
            } catch let error as URLError where error.code == .cancelled {
                activity = .idle
            } catch {
                activity = .idle
                outcome = .installFailed(Self.describe(error))
            }
        }
    }

    func cancelInstall() {
        guard case .downloading = activity else { return }
        installWork?.cancel()
    }

    private func install(_ offer: UpdateOffer) async throws {
        // The checksum first: without one there is no point downloading.
        let expected = try await checksum(for: offer)
        let dmg = try await download(offer.installer)
        activity = .installing
        let target = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let problem = try await Task.detached {
            guard try UpdateInstaller.sha256(of: dmg) == expected else {
                try? FileManager.default.removeItem(at: dmg)
                throw UpdateError("下载的安装包校验不通过，已删除，请重试。")
            }
            return UpdateInstaller.inPlaceProblem(for: target)
        }.value
        if let problem {
            installByHand(dmg, because: problem)
            return
        }
        let staged = try await Task.detached {
            try UpdateInstaller.stage(dmg: dmg, version: offer.version, bundleID: bundleID, replacing: target)
        }.value
        do {
            try await Task.detached {
                try UpdateInstaller.swap(target, with: staged)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            installByHand(dmg, because: Self.describe(error))
            return
        }
        try? FileManager.default.removeItem(at: dmg)
        self.offer = nil
        activity = .idle
        outcome = .installed(offer.version)
        // If reopening fails, 设置 says to reopen by hand.
        try? finishInstall(target)
    }

    /// The DMG is fine but this copy can't be swapped: open it for a
    /// drag-install, which asks for a password where needed.
    private func installByHand(_ dmg: URL, because problem: String) {
        NSWorkspace.shared.open(dmg)
        activity = .idle
        let reason = problem.hasSuffix("。") ? String(problem.dropLast()) : problem
        outcome = .manual("\(reason)，无法直接替换。已打开下载好的安装包，把 iTimer 拖到「应用程序」替换旧版本即可。")
    }

    private func checksum(for offer: UpdateOffer) async throws -> String {
        if let digest = Checksum.sha256(digest: offer.installer.digest) { return digest }
        guard let sums = offer.checksums else {
            throw UpdateError("这个版本没有提供校验值，无法确认安装包完整，请到发布页手动下载。")
        }
        try requireAllowed(sums.downloadURL)
        let (data, response) = try await session.data(from: sums.downloadURL)
        try Self.requireSuccess(response)
        guard let hex = Checksum.sha256(sums: String(decoding: data, as: UTF8.self), name: offer.installer.name) else {
            throw UpdateError("SHA256SUMS 里没有这个安装包，请到发布页手动下载。")
        }
        return hex
    }

    /// Into Caches, replacing earlier downloads. Kept when the install
    /// falls back to a drag-install.
    private func download(_ asset: GitHubRelease.Asset) async throws -> URL {
        try requireAllowed(asset.downloadURL)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "iTimer")/Updates", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fallbackTotal = asset.size
        return try await FileDownload.run(asset.downloadURL, to: folder.appendingPathComponent(asset.name)) { received, expected in
            Task { @MainActor in
                let updater = Updater.shared
                guard case .downloading = updater.activity else { return }
                updater.activity = .downloading(received: received, total: expected > 0 ? expected : fallbackTotal)
            }
        }
    }

    /// GitHub serves everything over HTTPS; only a test feed may hand out
    /// local files.
    private func requireAllowed(_ url: URL) throws {
        guard url.scheme == "https" || (feedOverridden && url.isFileURL) else {
            throw UpdateError("下载地址不安全：\(url.absoluteString)")
        }
    }

    /// Waits for this process to exit, then opens `app`, so the new copy
    /// starts fresh rather than alongside the old one.
    static func spawnRelaunch(of app: URL) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
            String(ProcessInfo.processInfo.processIdentifier),
            app.path,
        ]
        try helper.run()
    }

    static func relaunch(_ app: URL) throws {
        try spawnRelaunch(of: app)
        NSApp.terminate(nil)
    }

    // MARK: helpers

    /// This Mac's chip rather than this build's: an Intel copy running
    /// under Rosetta moves to the Apple Silicon DMG.
    nonisolated static var architecture: String {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 {
            return "arm64"
        }
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Local files answer without a status code.
    nonisolated static func requireSuccess(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 403, 429: throw UpdateError("GitHub 暂时限制了访问次数，过一会儿再试")
        default: throw UpdateError("服务器返回 \(http.statusCode)")
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? UpdateError { return error.message }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "没有网络连接"
            case .timedOut: return "连接超时"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "连不上 GitHub"
            default: break
            }
        }
        if error is DecodingError { return "发布信息的格式无法识别" }
        return error.localizedDescription
    }
}

/// One URLSession download with progress, as a single async call.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    // Delegate callbacks arrive one at a time on the session's queue; the
    // continuation is set before the task is resumed.
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var moved: Result<URL, Error>?

    private init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func run(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let delegate = FileDownload(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted as soon as this returns.
        moved = Result {
            try Updater.requireSuccess(downloadTask.response)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            return destination
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = error.map { .failure($0) } ?? moved ?? .failure(UpdateError("下载没有完成"))
        continuation?.resume(with: result)
        continuation = nil
    }
}
