import AppKit
import ITimerCore
import SwiftUI

/// 设置 › 软件更新: this version, the daily check, and — when GitHub has a
/// newer release — what changed and the button that installs it.
struct UpdateSection: View {
    var updater: Updater
    @AppStorage(Preferences.autoUpdateCheck) private var autoCheck = true

    var body: some View {
        Section {
            LabeledContent("当前版本", value: "\(updater.currentVersion)（build \(updater.build)）")
            Toggle("自动检查更新", isOn: $autoCheck)
            if let offer = updater.offer {
                offerHeader(offer)
                ReleaseNotesView(notes: offer.notes)
                installRow
                if let message = offerMessage {
                    Text(message.text)
                        .font(.caption)
                        .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("update-message")
                }
            } else {
                statusRow
            }
        } header: {
            Text("软件更新")
        } footer: {
            Text("每天查一次 GitHub 上的新版本，只读取版本信息。安装前会校验安装包的 SHA-256，装好后 iTimer 自动重新打开，计时不受影响。")
        }
    }

    // MARK: nothing to install

    private var statusRow: some View {
        let status = self.status
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("update-status")
            Spacer()
            if updater.activity == .checking {
                ProgressView()
                    .controlSize(.small)
            }
            Button("检查更新") {
                Task { await updater.check() }
            }
            .buttonStyle(PillButtonStyle(tint: .accentColor))
            .disabled(updater.isBusy || updater.awaitsRelaunch)
            .accessibilityIdentifier("update-check")
        }
    }

    private var status: (title: String, detail: String?, isError: Bool) {
        let checked = updater.lastChecked.map { "上次检查：\($0.formatted(.relative(presentation: .named)))" }
        if updater.activity == .checking { return ("正在检查…", checked, false) }
        switch updater.outcome {
        case .checkFailed(let reason)?: return ("检查更新失败", reason, true)
        case .installed(let version)?: return ("已安装 \(version)", "退出 iTimer 再打开就是新版本。", false)
        default: break
        }
        guard updater.lastChecked != nil else { return ("还没有检查过", nil, false) }
        return ("已是最新版本", checked, false)
    }

    // MARK: a newer release

    private func offerHeader(_ offer: UpdateOffer) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("发现新版本 \(offer.version.description)")
                    .font(.headline)
                Text(detail(offer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(offer.pageURL)
            } label: {
                Label("发布页", systemImage: "arrow.up.right")
            }
            .buttonStyle(PillButtonStyle(tint: .accentColor))
            .help(offer.pageURL.absoluteString)
        }
        .accessibilityIdentifier("update-offer")
    }

    private func detail(_ offer: UpdateOffer) -> String {
        var parts: [String] = []
        if let published = offer.publishedAt {
            parts.append("\(published.formatted(.dateTime.year().month().day())) 发布")
        }
        parts.append(Self.bytes(offer.installer.size))
        if offer.notes.count > 1 {
            parts.append("包含 \(offer.notes.count) 个版本的更新")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var installRow: some View {
        switch updater.activity {
        case .downloading(let received, let total):
            HStack(spacing: 10) {
                ProgressView(value: Double(min(received, total)), total: Double(max(total, 1)))
                Text("\(Self.bytes(received)) / \(Self.bytes(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("取消") { updater.cancelInstall() }
                    .buttonStyle(PillButtonStyle(tint: .secondary))
                    .accessibilityIdentifier("update-cancel")
            }
            .accessibilityIdentifier("update-progress")
        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在校验并安装…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("update-installing")
        case .idle, .checking:
            HStack(spacing: 10) {
                Button {
                    updater.install()
                } label: {
                    Label("下载并安装", systemImage: "arrow.down")
                }
                .buttonStyle(ActionButtonStyle(prominent: true, tint: .accentColor))
                .disabled(updater.isBusy)
                .accessibilityIdentifier("update-install")
                Spacer()
                Text("安装后 iTimer 会重新打开")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var offerMessage: (text: String, isError: Bool)? {
        switch updater.outcome {
        case .installFailed(let reason)?: ("更新失败：\(reason)", true)
        case .checkFailed(let reason)?: ("检查更新失败：\(reason)", true)
        case .manual(let text)?: (text, false)
        default: nil
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// What changed, newest version first, in a box that scrolls once it
/// passes about a dozen lines.
private struct ReleaseNotesView: View {
    var notes: [ReleaseNotes]
    @State private var contentHeight: CGFloat = 0
    private let maxHeight: CGFloat = 220

    var body: some View {
        let scrolls = contentHeight > maxHeight
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(scrolls ? .automatic : .never)
        .scrollDisabled(!scrolls)
        .frame(height: min(max(contentHeight, 24), maxHeight))
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("update-notes")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes, id: \.version) { release in
                VStack(alignment: .leading, spacing: 4) {
                    if notes.count > 1 {
                        Text(release.version.description)
                            .font(.callout.weight(.semibold))
                    }
                    if release.blocks.isEmpty {
                        Text("这个版本没有写更新说明。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(release.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNotes.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        case .item(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(Self.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .text(let text):
            Text(Self.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `代码` and **粗体** inside a line.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// iTimer › 检查更新…: opens 设置, where the answer shows.
struct UpdateCommands: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("检查更新…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            Task { await Updater.shared.check() }
        }
    }
}
