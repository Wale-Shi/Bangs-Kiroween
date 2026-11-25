import AppKit
import BangsCore
import Security
import SwiftUI

/// Updates Bangs from its GitHub releases. A new version is installed only when it is signed exactly as the running
/// Bangs is (same certificate, same bundle id), so a tampered download is refused; being the same app to macOS, it
/// keeps its permissions. Bangs downloads it itself, so it carries no quarantine and opens without asking.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let download: URL
        let page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// A release found by the daily check, for the island to mention once.
    var onFound: (Release) -> Void = { _ in }

    /// A public repository holding only the release downloads, so the source can stay private.
    static let repository = "Wale-Shi/Bangs-releases"
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private let preferences: Preferences
    private var timer: Timer?

    init(preferences: Preferences) {
        self.preferences = preferences
        // Looked at every few hours; asks GitHub at most once a day, and only when you turned that on.
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.daily() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.daily() }
    }

    private func daily() {
        guard preferences.checkForUpdates, Date().timeIntervalSince(preferences.lastUpdateCheck) > 86_400 else { return }
        Task { await check(quietly: true) }
    }

    /// Asks GitHub for the latest release. Quietly (the daily check), a release you skipped is not offered again.
    func check(quietly: Bool = false) async {
        guard state != .checking, state != .installing else { return }
        state = .checking
        do {
            let release = try await Self.latest()
            preferences.lastUpdateCheck = Date()
            guard Version.isNewer(release.version, than: current) else { state = .upToDate; return }
            state = .available(release)
            if quietly, preferences.skippedVersion != release.version { onFound(release) }
        } catch {
            Log.write("update: check failed: \(error)")
            state = quietly ? .idle : .failed("检查更新失败：\(error.localizedDescription)")
        }
    }

    func skip(_ release: Release) {
        preferences.skippedVersion = release.version
    }

    /// Downloads the release, checks it, and swaps it in once Bangs has quit; then opens it.
    func install(_ release: Release) async {
        state = .installing
        do {
            let (zip, response) = try await URLSession.shared.download(from: release.download)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure("下载安装包失败（HTTP \(status)）") }
            try Self.install(zip: zip, expecting: release.version)
        } catch {
            Log.write("update: install failed: \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Steps


    /// The latest release. Its version comes from where github.com/…/releases/latest redirects (the newest tag), which
    /// the API's hourly limit for anonymous requests does not touch; on a shared proxy that limit runs out quickly.
    /// The API is asked only for the release notes, and the update goes ahead without them.
    static func latest() async throws -> Release {
        let page = URL(string: "https://github.com/\(repository)/releases/latest")!
        var request = URLRequest(url: page)
        request.httpMethod = "HEAD"
        request.setValue("Bangs", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let final = response.url, final.pathComponents.dropLast().last == "tag", let tag = final.pathComponents.last else {
            Log.write("update: releases/latest answered \(status) at \(response.url?.absoluteString ?? "-")")
            throw Failure(status == 404 ? "GitHub 上还没有发布的版本" : "GitHub 没有返回最新版本（HTTP \(status)）")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let download = URL(string: "https://github.com/\(repository)/releases/download/\(tag)/Bangs-\(version)-arm64.zip")!
        return Release(version: version, notes: (try? await notes(for: tag)) ?? "", download: download, page: final)
    }

    private static func notes(for tag: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/tags/\(tag)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bangs", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "" }
        return (try JSONDecoder().decode(ReleaseNotes.self, from: data)).body ?? ""
    }

    private struct ReleaseNotes: Decodable { let body: String? }

    /// Unpacks `zip` beside the running app, makes sure it is Bangs `version` signed like this one, and hands the swap to
    /// a script that waits for Bangs to quit.
    static func install(zip: URL, expecting version: String) throws {
        let target = Bundle.main.bundleURL
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw Failure("没有权限写入 \(folder.path)，请手动下载安装") }
        // Unpacked next to the app, so the swap is a rename on the same volume.
        let staging = folder.appendingPathComponent(".Bangs-update-\(version)")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        let fresh = staging.appendingPathComponent("Bangs.app")
        do {
            try verify(fresh, version: version)
            // Downloaded by Bangs it carries no quarantine; make sure, so it opens without asking.
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", fresh.path])
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        Log.write("update: installing \(version) over \(target.path)")
        let script = """
        while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
        rm -rf "$1.old"
        if mv "$1" "$1.old" && mv "$2" "$1"; then rm -rf "$1.old"; else rm -rf "$1"; mv "$1.old" "$1"; fi
        rm -rf "$3"
        /usr/bin/open "$1"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, String(getpid()), target.path, fresh.path, staging.path]
        try task.run()
        NSApp?.terminate(nil)
    }

    /// The new app must be this app's bundle at `version`, signed to satisfy this app's own designated requirement.
    static func verify(_ app: URL, version: String) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure("下载的不是 Bangs") }
        guard info?["CFBundleShortVersionString"] as? String == version else { throw Failure("下载的版本号不对") }
        var me: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, theirs: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure("读不到当前 Bangs 的签名")
        }
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs else { throw Failure("读不到新版本的签名") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(theirs, flags, requirement)
        guard status == errSecSuccess else {
            Log.write("update: signature check failed (\(status))")
            throw Failure("新版本的签名和当前 Bangs 不一致，已拒绝安装")
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw Failure("\((tool as NSString).lastPathComponent) 失败") }
        return task.terminationStatus
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// The island after the daily check finds a new version.
struct UpdateView: View {
    let release: Updater.Release
    @ObservedObject var model: NotchModel
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Bangs \(release.version) 可以更新了").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("当前 \(updater.current)").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            if let line = release.notes.split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                Text(line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-* ")))
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(2).padding(.top, 6)
            }
            if case .failed(let message) = updater.state {
                Text(message).font(.system(size: 11.5)).foregroundStyle(Palette.danger).padding(.top, 6)
            }
            HStack(spacing: 6) {
                Spacer()
                PillButton(title: "跳过这个版本", style: .plain) {
                    updater.skip(release)
                    model.go(.collapsed)
                }
                PillButton(title: "稍后", style: .plain) { model.go(.collapsed) }
                PillButton(title: updater.state == .installing ? "正在更新…" : "更新并重启", style: .primary) {
                    Task { await updater.install(release) }
                }
            }
            .padding(.top, 12)
        }
    }
}
