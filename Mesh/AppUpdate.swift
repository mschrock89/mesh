import AppKit
import Combine
import Foundation

enum UpdateRelation: Equatable {
    case upToDate
    case available
    case localIsNewer
    case notOnGitHub
    case different
}

enum UpdateTone {
    case muted
    case ready
    case failure
}

enum UpdateCheck {
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func short(_ commit: String) -> String {
        let commit = normalize(commit)
        if commit.isEmpty || commit == "unknown" { return "unknown" }
        return String(commit.prefix(7))
    }

    static func same(_ local: String, _ remote: String) -> Bool {
        let local = normalize(local)
        let remote = normalize(remote)
        return !local.isEmpty && local != "unknown" && local == remote
    }

    /// `compareStatus` comes from GitHub's compare of this copy...published commit.
    /// "ahead" means the published commit is ahead of this copy.
    static func relation(localCommit: String, remoteTag: String, compareStatus: String?) -> UpdateRelation {
        if same(localCommit, remoteTag) {
            return .upToDate
        }
        let local = normalize(localCommit)
        if local.isEmpty || local == "unknown" {
            return .different
        }
        switch compareStatus?.lowercased() {
        case "identical":
            return .upToDate
        case "ahead":
            return .available
        case "behind":
            return .localIsNewer
        case "diverged":
            return .different
        default:
            return .notOnGitHub
        }
    }
}

struct GitHubRelease: Decodable {
    static let meshAssetName = "Mesh.app.zip"

    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let id: Int
        let name: String
    }

    var meshAssetID: Int? {
        assets.first { $0.name == Self.meshAssetName }?.id
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubCompare: Decodable {
    let status: String
}

private struct GitHubMessage: Decodable {
    let message: String

    static func text(from data: Data) -> String? {
        try? JSONDecoder().decode(GitHubMessage.self, from: data).message
    }
}

struct UpdateError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum MeshRelease {
    static var repo: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "MeshRepo") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "mschrock89/mesh" : trimmed
    }

    static var commit: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "MeshCommit") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    static var shortCommit: String {
        UpdateCheck.short(commit)
    }
}

enum MeshSupport {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mesh", isDirectory: true)
    }

    static func prepare() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum UpdateCredential {
    static func normalize(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "bearer "
        if token.lowercased().hasPrefix(prefix) {
            token = String(token.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token
    }

    static func readFile() -> String? {
        let url = MeshSupport.directory.appendingPathComponent("github-token")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = normalize(text)
        return token.isEmpty ? nil : token
    }

    static func save(_ raw: String) throws {
        let token = normalize(raw)
        guard !token.isEmpty else {
            throw UpdateError(message: "Enter a GitHub token.")
        }
        let directory = try MeshSupport.prepare()
        let url = directory.appendingPathComponent("github-token")
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    static func readGH() async -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            let once = ResumeOnce()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                once.resume {
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let token = String(data: data, encoding: .utf8).map(normalize) ?? ""
                    if process.terminationStatus == 0, !token.isEmpty {
                        continuation.resume(returning: token)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            do {
                try process.run()
            } catch {
                once.resume { continuation.resume(returning: nil) }
            }
        }
    }
}

private enum RepoAccess {
    case allowed
    case denied
}

/// GitHub's asset host rejects the API token, so drop Authorization after leaving api.github.com.
private final class HeaderStripper: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let host = request.url?.host?.lowercased(), host != "api.github.com" else {
            return request
        }
        var copy = request
        copy.setValue(nil, forHTTPHeaderField: "Authorization")
        return copy
    }
}

private final class GitHubClient {
    let token: String
    let repo: String
    private let session: URLSession

    init(token: String, repo: String) {
        self.token = token
        self.repo = repo
        let stripper = HeaderStripper()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: stripper, delegateQueue: nil)
    }

    func finish() {
        session.finishTasksAndInvalidate()
    }

    func access() async throws -> RepoAccess {
        let (data, http) = try await send(path: "/repos/\(repo)", accept: "application/vnd.github+json")
        if http.statusCode == 200 { return .allowed }
        if isRateLimit(http, data: data) {
            throw UpdateError(message: "GitHub is limiting requests. Try again in a few minutes.")
        }
        if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 404 {
            return .denied
        }
        throw UpdateError(message: "Mesh couldn't reach GitHub.")
    }

    func latestRelease() async throws -> GitHubRelease? {
        let (data, http) = try await send(path: "/repos/\(repo)/releases/latest", accept: "application/vnd.github+json")
        if http.statusCode == 404 { return nil }
        if isRateLimit(http, data: data) {
            throw UpdateError(message: "GitHub is limiting requests. Try again in a few minutes.")
        }
        guard http.statusCode == 200 else {
            throw UpdateError(message: "Mesh couldn't read the update list.")
        }
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError(message: "Mesh couldn't read the update list.")
        }
    }

    func compareStatus(base: String, head: String) async throws -> String? {
        let path = "/repos/\(repo)/compare/\(escape(base))...\(escape(head))"
        let (data, http) = try await send(path: path, accept: "application/vnd.github+json")
        if http.statusCode == 404 { return nil }
        if isRateLimit(http, data: data) {
            throw UpdateError(message: "GitHub is limiting requests. Try again in a few minutes.")
        }
        guard http.statusCode == 200 else {
            throw UpdateError(message: "Mesh couldn't compare this copy with GitHub.")
        }
        return try? JSONDecoder().decode(GitHubCompare.self, from: data).status
    }

    func downloadAsset(_ id: Int) async throws -> URL {
        var request = makeRequest(path: "/repos/\(repo)/releases/assets/\(id)", accept: "application/octet-stream")
        request.timeoutInterval = 300
        let (fileURL, response) = try await session.download(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw UpdateError(message: "Mesh couldn't download the update.")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mesh-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }

    private func send(path: String, accept: String) async throws -> (Data, HTTPURLResponse) {
        let request = makeRequest(path: path, accept: accept)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError(message: "Mesh couldn't reach GitHub.")
        }
        return (data, http)
    }

    private func makeRequest(path: String, accept: String) -> URLRequest {
        let url = URL(string: "https://api.github.com\(path)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Mesh", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/.")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func isRateLimit(_ response: HTTPURLResponse, data: Data) -> Bool {
        if response.statusCode == 429 { return true }
        guard response.statusCode == 403 else { return false }
        let message = GitHubMessage.text(from: data)?.lowercased() ?? ""
        return message.contains("rate limit")
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !didResume
        if shouldRun { didResume = true }
        lock.unlock()
        if shouldRun { body() }
    }
}

private struct PendingUpdate {
    var tag: String
    var assetID: Int
}

private enum UpdateInstaller {
    static let label = "com.mitchellschrock.mesh.update"

    static func stage(zip: URL, expectedCommit: String) async throws -> URL {
        let support = try MeshSupport.prepare()
        let stagingRoot = support.appendingPathComponent("Staging", isDirectory: true)
        if FileManager.default.fileExists(atPath: stagingRoot.path) {
            try FileManager.default.removeItem(at: stagingRoot)
        }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, stagingRoot.path])
        let app = stagingRoot.appendingPathComponent("Mesh.app", isDirectory: true)
        let binary = app.appendingPathComponent("Contents/MacOS/Mesh")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw UpdateError(message: "The download didn't include Mesh.")
        }
        if let stamped = commit(inApp: app),
           !UpdateCheck.same(stamped, expectedCommit) {
            throw UpdateError(message: "The download doesn't match the published update.")
        }
        return app
    }

    static func scheduleReplace(stagedApp: URL, destination: URL) throws {
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard destination.lastPathComponent == "Mesh.app" else {
            throw UpdateError(message: "Mesh can only replace its own app.")
        }
        guard stagedApp.lastPathComponent == "Mesh.app",
              stagedApp.deletingLastPathComponent().lastPathComponent == "Staging" else {
            throw UpdateError(message: "Mesh couldn't prepare the update.")
        }
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError(message: "Mesh doesn't have permission to replace the app in \(parent.path).")
        }

        let support = try MeshSupport.prepare()
        let scriptURL = support.appendingPathComponent("update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)

        let agents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plistURL = agents.appendingPathComponent("\(label).plist")
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/bin/bash",
                scriptURL.path,
                String(ProcessInfo.processInfo.processIdentifier),
                stagedApp.path,
                destination.path
            ],
            "RunAtLoad": true,
            "AbandonProcessGroup": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: plistURL.path)

        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        let (status, output) = launchctl(["bootstrap", domain, plistURL.path])
        guard status == 0 else {
            try? FileManager.default.removeItem(at: plistURL)
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty {
                print("Mesh update bootstrap failed: \(detail)")
            }
            throw UpdateError(message: "Mesh couldn't schedule the relaunch.")
        }
    }

    private static var script: String {
        """
        #!/bin/bash
        set -u
        PID="$1"
        SRC="$2"
        DEST="$3"
        TMP="${DEST}.incoming"
        PLIST="$HOME/Library/LaunchAgents/\(label).plist"
        LOG="$HOME/Library/Application Support/Mesh/update.log"
        mkdir -p "$(dirname "$LOG")"
        exec >> "$LOG" 2>&1
        echo "---- $(date) updating $DEST ----"
        rm -f "$PLIST"

        recover() {
          if [[ -d "$TMP" && ! -e "$DEST" ]]; then
            mv "$TMP" "$DEST" || true
          elif [[ -d "$TMP" ]]; then
            rm -rf "$TMP"
          fi
        }
        trap recover EXIT

        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2
        done
        sleep 0.4

        rm -rf "$TMP"
        if ! ditto "$SRC" "$TMP"; then
          echo "ditto failed"
          exit 1
        fi
        rm -rf "$DEST"
        if ! mv "$TMP" "$DEST"; then
          echo "mv failed"
          exit 1
        fi
        xattr -dr com.apple.quarantine "$DEST" || true
        if ! codesign --verify --deep "$DEST" >/dev/null 2>&1; then
          codesign --force --deep --sign - "$DEST" || true
        fi
        rm -rf "$(dirname "$SRC")"
        open "$DEST" || true
        sleep 3
        if ! pgrep -x Mesh >/dev/null 2>&1; then
          /usr/bin/osascript -e 'display dialog "Mesh was updated. If it did not reopen, Control-click Mesh and choose Open." buttons {"OK"} default button "OK"' || true
        fi
        """
    }

    private static func commit(inApp app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist),
              let commit = dict["MeshCommit"] as? String else { return nil }
        let trimmed = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "unknown" { return nil }
        return trimmed
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            process.terminationHandler = { process in
                once.resume {
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: UpdateError(message: "Mesh couldn't unpack the update."))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                once.resume {
                    continuation.resume(throwing: UpdateError(message: "Mesh couldn't unpack the update."))
                }
            }
        }
    }

    private static func launchctl(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, "")
        }
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }
}

private enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(String)
    case ahead
    case notOnGitHub
    case downloading
    case failed(String)
    case needsToken
}

@MainActor
final class AppUpdateController: ObservableObject {
    @Published private(set) var askingForToken = false
    @Published var tokenDraft = ""
    @Published private(set) var isBusy = false

    private var phase: UpdatePhase = .idle
    private var pending: PendingUpdate?
    private var resolvedToken: String?
    private var didResolve = false

    var tone: UpdateTone {
        switch phase {
        case .available, .ahead, .needsToken:
            return .ready
        case .failed:
            return .failure
        default:
            return .muted
        }
    }

    var canInstall: Bool {
        if isBusy { return false }
        if case .available = phase { return pending != nil }
        return false
    }

    var isButtonDisabled: Bool {
        if isBusy { return true }
        if askingForToken { return UpdateCredential.normalize(tokenDraft).isEmpty }
        return false
    }

    var buttonTitle: String {
        if askingForToken { return "Save Token" }
        if isBusy {
            switch phase {
            case .downloading: return "Installing…"
            case .checking: return "Checking…"
            default: break
            }
        }
        if canInstall { return "Install Update" }
        return "Check for Updates"
    }

    var statusText: String {
        switch phase {
        case .idle:
            let short = MeshRelease.shortCommit
            if short == "unknown" {
                return "Ready to check for an update"
            }
            return "Installed \(short)"
        case .checking:
            return "Checking GitHub…"
        case .upToDate:
            return "Up to date · \(MeshRelease.shortCommit)"
        case .available(let remote):
            return "Update ready · \(UpdateCheck.short(remote)). Mesh will quit and reopen."
        case .ahead:
            return "Installed \(MeshRelease.shortCommit) is newer than the published update."
        case .notOnGitHub:
            return "Push this install to GitHub before it can be compared."
        case .downloading:
            return "Installing the published update…"
        case .failed(let message):
            return message
        case .needsToken:
            return "Paste a GitHub token that can read \(MeshRelease.repo). It stays on this Mac."
        }
    }

    func perform() {
        Task { await performNow() }
    }

    func refreshOnOpen() {
        guard !isBusy, !askingForToken else { return }
        Task { await check(interactive: false) }
    }

    private func performNow() async {
        if askingForToken {
            await saveAndCheck()
            return
        }
        if canInstall {
            await install()
            return
        }
        await check(interactive: true)
    }

    private func saveAndCheck() async {
        guard !isBusy else { return }
        let token = UpdateCredential.normalize(tokenDraft)
        guard !token.isEmpty else { return }
        do {
            try UpdateCredential.save(token)
        } catch let error as UpdateError {
            phase = .failed(error.message)
            askingForToken = true
            publish()
            return
        } catch {
            phase = .failed("Mesh couldn't save the token on this Mac.")
            askingForToken = true
            publish()
            return
        }
        didResolve = true
        resolvedToken = token
        await check(interactive: true)
        if !askingForToken {
            tokenDraft = ""
        }
    }

    private func check(interactive: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        let previous = phase
        if interactive {
            phase = .checking
            publish()
        }
        defer {
            isBusy = false
            publish()
        }

        guard let token = await credentialToken() else {
            if interactive {
                askingForToken = true
                phase = .needsToken
            }
            return
        }
        let client = GitHubClient(token: token, repo: MeshRelease.repo)
        defer { client.finish() }

        do {
            switch try await client.access() {
            case .denied:
                didResolve = false
                resolvedToken = nil
                askingForToken = true
                phase = .failed("GitHub rejected that token. Paste one that can read \(MeshRelease.repo).")
                return
            case .allowed:
                askingForToken = false
            }

            guard let release = try await client.latestRelease() else {
                pending = nil
                phase = interactive ? .failed("No update is published yet.") : .idle
                return
            }
            guard let assetID = release.meshAssetID else {
                pending = nil
                phase = .failed("The published update is missing Mesh.app.zip.")
                return
            }

            let local = MeshRelease.commit
            let remote = release.tagName
            let compare: String?
            if UpdateCheck.same(local, remote) || UpdateCheck.normalize(local) == "unknown" {
                compare = nil
            } else {
                compare = try await client.compareStatus(base: local, head: remote)
            }
            switch UpdateCheck.relation(localCommit: local, remoteTag: remote, compareStatus: compare) {
            case .upToDate:
                pending = nil
                phase = .upToDate
            case .available, .different:
                pending = PendingUpdate(tag: remote, assetID: assetID)
                phase = .available(remote)
            case .localIsNewer:
                pending = nil
                phase = .ahead
            case .notOnGitHub:
                pending = nil
                phase = .notOnGitHub
            }
        } catch let error as UpdateError {
            phase = interactive ? .failed(error.message) : previous
        } catch {
            phase = interactive ? .failed("Mesh couldn't reach GitHub.") : previous
        }
    }

    private func install() async {
        guard let pending, !isBusy else { return }
        guard let token = await credentialToken() else {
            askingForToken = true
            phase = .needsToken
            publish()
            return
        }
        isBusy = true
        phase = .downloading
        publish()
        let client = GitHubClient(token: token, repo: MeshRelease.repo)
        defer {
            client.finish()
            isBusy = false
            publish()
        }
        do {
            let zip = try await client.downloadAsset(pending.assetID)
            defer { try? FileManager.default.removeItem(at: zip) }
            let staged = try await UpdateInstaller.stage(zip: zip, expectedCommit: pending.tag)
            try UpdateInstaller.scheduleReplace(stagedApp: staged, destination: Bundle.main.bundleURL)
            NSApp.terminate(nil)
        } catch let error as UpdateError {
            phase = .failed(error.message)
        } catch {
            phase = .failed("Mesh couldn't install the update.")
        }
    }

    private func credentialToken() async -> String? {
        if didResolve { return resolvedToken }
        didResolve = true
        if let saved = UpdateCredential.readFile() {
            resolvedToken = saved
            return saved
        }
        let ghToken = await UpdateCredential.readGH()
        resolvedToken = ghToken
        return ghToken
    }

    private func publish() {
        objectWillChange.send()
    }
}
