import Foundation

/// An app version, `x.y.z`. Release tags carry a leading `v`; anything
/// after the numbers (a `-beta` suffix) is not a release.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "1.11.0", "v1.11.0"; a missing minor or patch counts as 0.
    public init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// One entry of GitHub's releases API, only the fields the updater reads.
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        public var size: Int64
        public var downloadURL: URL
        /// `sha256:<hex>`. GitHub fills it for assets uploaded since 2025;
        /// older ones only have the release's SHA256SUMS.
        public var digest: String?

        private enum CodingKeys: String, CodingKey {
            case name, size, digest
            case downloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var name: String?
    public var body: String?
    public var pageURL: URL
    public var draft: Bool
    public var prerelease: Bool
    public var publishedAt: Date?
    public var assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case pageURL = "html_url"
        case publishedAt = "published_at"
    }

    /// The array `GET /repos/{owner}/{repo}/releases` returns.
    public static func list(from data: Data) throws -> [GitHubRelease] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    }
}

/// A newer release the running app can install.
public struct UpdateOffer: Equatable, Sendable {
    public var version: AppVersion
    public var pageURL: URL
    public var publishedAt: Date?
    /// The DMG for this Mac's architecture.
    public var installer: GitHubRelease.Asset
    /// The release's `SHA256SUMS`, for when the DMG carries no digest.
    public var checksums: GitHubRelease.Asset?
    /// What changed: one entry per version newer than the running one,
    /// newest first.
    public var notes: [ReleaseNotes]
}

public enum UpdateCatalog {
    /// Matches `scripts/build-dmg.sh`.
    public static func installerName(version: AppVersion, architecture: String) -> String {
        "iTimer-\(version)-macos-\(architecture).dmg"
    }

    /// The newest published release above `current` that has a DMG for
    /// `architecture`, or nil when there is nothing to install.
    public static func offer(in releases: [GitHubRelease], current: AppVersion, architecture: String) -> UpdateOffer? {
        let newer = releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release in AppVersion(release.tagName).map { (version: $0, release: release) } }
            .filter { $0.version > current }
            .sorted { $0.version > $1.version }
        for (version, release) in newer {
            let name = installerName(version: version, architecture: architecture)
            guard let installer = release.assets.first(where: { $0.name == name }) else { continue }
            return UpdateOffer(
                version: version,
                pageURL: release.pageURL,
                publishedAt: release.publishedAt,
                installer: installer,
                checksums: release.assets.first { $0.name == "SHA256SUMS" },
                notes: newer.filter { $0.version <= version }.map {
                    ReleaseNotes(version: $0.version, markdown: $0.release.body ?? "")
                }
            )
        }
        return nil
    }
}

public enum Checksum {
    /// The hex out of GitHub's `sha256:<hex>`.
    public static func sha256(digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        return normalized(String(digest.dropFirst("sha256:".count)))
    }

    /// The line for `name` in `sha256sum` output (`<hex>  <name>`, or
    /// `<hex> *<name>` in binary mode).
    public static func sha256(sums: String, name: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            var file = fields[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            if file == name { return normalized(String(fields[0])) }
        }
        return nil
    }

    private static func normalized(_ hex: String) -> String? {
        let hex = hex.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }
}

/// A release's notes as the app shows them: headings, list items and
/// plain lines, without the download instructions every release ends with.
public struct ReleaseNotes: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case item(String)
        case text(String)
    }

    public var version: AppVersion
    public var blocks: [Block]

    public init(version: AppVersion, markdown: String) {
        self.version = version
        self.blocks = Self.blocks(from: markdown)
    }

    /// The heading `scripts/prepare-release.py` appends to every release.
    /// It is about picking a DMG, which the updater does by itself.
    static let installHeading = "下载与安装"

    public static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if title == installHeading { break }
                if !title.isEmpty { blocks.append(.heading(title)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.item(line.dropFirst(2).trimmingCharacters(in: .whitespaces)))
            } else if raw.first?.isWhitespace == true, case .item(let previous)? = blocks.last {
                // A list item wrapped onto an indented line.
                blocks[blocks.count - 1] = .item(previous + " " + line)
            } else {
                blocks.append(.text(line))
            }
        }
        return blocks
    }
}
