import AppKit
import CoreImage
import CryptoKit

private let serverPort = 8787
private let updateRepository = "Nisss78/codex-mic-remote"
private let updateAssetName = "Codex Mic Remote.app.zip"
private let checksumAssetName = "SHA256SUMS.txt"

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
    }

    let tagName: String
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey { case tagName = "tag_name"; case prerelease, assets }
}

private struct ServiceIdentity: Decodable {
    let kind: String
    let protocolVersion: Int
    let pid: Int32?
    let instanceId: String

    enum CodingKeys: String, CodingKey {
        case kind, pid, instanceId
        case protocolVersion = "protocol"
    }
}

private struct AdminLease: Decodable {
    let kind: String
    let protocolVersion: Int
    let pid: Int32
    let instanceId: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case kind, pid, instanceId, token
        case protocolVersion = "protocol"
    }
}

@main
struct CodexMicRemoteMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = CodexMicRemoteLauncher()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class CodexMicRemoteLauncher: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusLabel = NSTextField(labelWithString: "起動準備中…")
    private var detailLabel = NSTextField(wrappingLabelWithString: "")
    private var urlLabel = NSTextField(labelWithString: "")
    private var codeLabel = NSTextField(labelWithString: "")
    private var qrView = NSImageView()
    private var startButton = NSButton(title: "Codex Mic Remote を起動", target: nil, action: nil)
    private var stopButton = NSButton(title: "停止", target: nil, action: nil)
    private var restartButton = NSButton(title: "Codex Mic Remote を再起動", target: nil, action: nil)
    private var updateButton = NSButton(title: "アップデートを確認", target: nil, action: nil)
    private var process: Process?
    private var didRequestStop = false
    private var listeningURL: String?
    private var pairingCode: String?
    private var pendingServerOutput = ""
    private var codeExpiryWork: DispatchWorkItem?
    private var verifiedAdminLease: AdminLease?

    private var adminFileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Codex Mic Remote", isDirectory: true)
        return folder.appendingPathComponent("launcher-admin.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        probeForExistingService()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Only terminate a child that this launcher created. A pre-existing server may be
        // somebody's active remote, so the launcher never attempts to stop it.
        process?.terminate()
        return .terminateNow
    }

    // Closing the window should not silently end a useful remote session. The user can
    // reopen it from the Dock to inspect its state or press Stop; Quit explicitly ends it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    private func makeWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Codex Mic Remote"
        window.center()

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let title = NSTextField(labelWithString: "Codex Mic Remote")
        title.font = .systemFont(ofSize: 25, weight: .bold)

        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        urlLabel.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        codeLabel.font = .monospacedSystemFont(ofSize: 28, weight: .bold)
        codeLabel.alignment = .center

        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.wantsLayer = true
        qrView.layer?.backgroundColor = NSColor.white.cgColor
        qrView.layer?.cornerRadius = 8
        qrView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            qrView.widthAnchor.constraint(equalToConstant: 210),
            qrView.heightAnchor.constraint(equalToConstant: 210),
        ])

        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(start)
        // Wait for the local port probe before permitting a start. This prevents a
        // race from replacing an already-active remote while its owner is using it.
        startButton.isEnabled = false
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.isEnabled = false
        restartButton.target = self
        restartButton.action = #selector(restartVerifiedService)
        restartButton.isHidden = true
        updateButton.target = self
        updateButton.action = #selector(checkForUpdate)
        updateButton.bezelStyle = .rounded

        let note = NSTextField(wrappingLabelWithString: "QRコードには10分間だけ有効な接続先とペアリングコードだけを入れます。セッショントークンは含めません。")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3

        let buttons = NSStackView(views: [startButton, stopButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let accessibilityButton = NSButton(title: "アクセシビリティ設定を開く", target: self, action: #selector(openAccessibilitySettings))
        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.toolTip = "システム設定の「プライバシーとセキュリティ > アクセシビリティ」を開きます。権限の変更は行いません。"

        let stack = NSStackView(views: [title, statusLabel, detailLabel, urlLabel, codeLabel, qrView, note, buttons, restartButton, updateButton, accessibilityButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            restartButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            updateButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accessibilityButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func openAccessibilitySettings() {
        // This only opens the relevant System Settings pane. The user remains in
        // control of granting or revoking the permission.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdate() {
        guard let url = URL(string: "https://api.github.com/repos/\(updateRepository)/releases/latest") else { return }
        updateButton.isEnabled = false
        let priorTitle = statusLabel.stringValue
        setState("アップデートを確認中…", detail: "GitHub Releases から最新版情報を確認しています。")
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Mic-Remote", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateButton.isEnabled = true
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let data,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                      !release.prerelease else {
                    self.setState("アップデートを確認できません", detail: error?.localizedDescription ?? "GitHub Releasesへ接続できませんでした。")
                    return
                }
                let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard self.isNewer(version, than: self.currentVersion) else {
                    self.setState(priorTitle, detail: "最新版です（v\(self.currentVersion)）。")
                    return
                }
                guard let archive = release.assets.first(where: { $0.name == updateAssetName }),
                      let checksums = release.assets.first(where: { $0.name == checksumAssetName }) else {
                    self.setState("アップデートを確認できません", detail: "v\(version) のアプリ本体またはチェックサムが見つかりません。")
                    return
                }
                self.confirmAndInstall(releaseVersion: version, archive: archive.browserDownloadURL, checksums: checksums.browserDownloadURL)
            }
        }.resume()
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private func confirmAndInstall(releaseVersion: String, archive: URL, checksums: URL) {
        let alert = NSAlert()
        alert.messageText = "v\(releaseVersion) をインストールしますか？"
        alert.informativeText = "GitHub Releasesからダウンロードし、SHA-256を確認してからアプリを入れ替え、再起動します。現在のアプリはバックアップとして残ります。"
        alert.addButton(withTitle: "ダウンロードして更新")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateButton.isEnabled = false
        setState("アップデートをダウンロード中…", detail: "v\(releaseVersion) を確認してからインストールします。")
        downloadUpdate(archive: archive, checksums: checksums, version: releaseVersion)
    }

    private func downloadUpdate(archive: URL, checksums: URL, version: String) {
        let group = DispatchGroup()
        var archiveData: Data?
        var checksumData: Data?
        var failure: String?
        group.enter()
        URLSession.shared.dataTask(with: archive) { data, response, error in
            if (response as? HTTPURLResponse)?.statusCode == 200 { archiveData = data }
            else { failure = error?.localizedDescription ?? "アプリ本体をダウンロードできませんでした。" }
            group.leave()
        }.resume()
        group.enter()
        URLSession.shared.dataTask(with: checksums) { data, response, error in
            if (response as? HTTPURLResponse)?.statusCode == 200 { checksumData = data }
            else { failure = error?.localizedDescription ?? "チェックサムをダウンロードできませんでした。" }
            group.leave()
        }.resume()
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard failure == nil, let archiveData, let checksumData else {
                self.updateButton.isEnabled = true
                self.setState("アップデートできません", detail: failure ?? "ダウンロード結果を確認できませんでした。")
                return
            }
            let actual = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
            let expected = String(data: checksumData, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .first(where: { $0.hasSuffix("  \(updateAssetName)") })?
                .split(separator: " ").first.map(String.init)
            guard actual.caseInsensitiveCompare(expected ?? "") == .orderedSame else {
                self.updateButton.isEnabled = true
                self.setState("アップデートを中止しました", detail: "ダウンロードしたアプリのチェックサムが一致しません。既存アプリは変更していません。")
                return
            }
            let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("Codex-Mic-Remote-v\(version)-\(UUID().uuidString).zip")
            do {
                try archiveData.write(to: archiveURL, options: .atomic)
                try self.launchUpdater(archiveURL: archiveURL)
            } catch {
                self.updateButton.isEnabled = true
                self.setState("アップデートできません", detail: error.localizedDescription)
            }
        }
    }

    private func launchUpdater(archiveURL: URL) throws {
        let appURL = Bundle.main.bundleURL
        let updaterURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-mic-remote-updater-\(UUID().uuidString).sh")
        let stageURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-mic-remote-update-\(UUID().uuidString)")
        let backupURL = appURL.deletingLastPathComponent().appendingPathComponent("\(appURL.deletingPathExtension().lastPathComponent).backup-\(Int(Date().timeIntervalSince1970)).app")
        let script = """
        #!/bin/zsh
        set -eu
        pid="$1"; archive="$2"; destination="$3"; stage="$4"; backup="$5"
        while kill -0 "$pid" 2>/dev/null; do sleep 1; done
        /usr/bin/ditto -x -k "$archive" "$stage"
        candidate="$stage/Codex Mic Remote.app"
        test -d "$candidate"
        /bin/mv "$destination" "$backup"
        if ! /bin/mv "$candidate" "$destination"; then
          /bin/mv "$backup" "$destination"
          exit 1
        fi
        /usr/bin/open "$destination"
        """
        try script.write(to: updaterURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updaterURL.path)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [updaterURL.path, String(getpid()), archiveURL.path, appURL.path, stageURL.path, backupURL.path]
        try task.run()
        setState("再起動して更新します…", detail: "v\(currentVersion) のバックアップを残して、確認済みの新版へ入れ替えます。")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    @objc private func restartVerifiedService() {
        guard let lease = verifiedAdminLease else {
            restartButton.isHidden = true
            setState("再起動できません", detail: "ランチャー管理の Codex Mic Remote が見つかりません。もう一度このアプリを開いて確認してください。")
            probeForExistingService()
            return
        }
        restartButton.isEnabled = false
        setState("再起動中…", detail: "ランチャー管理の Codex Mic Remote に、安全な終了を依頼しています。ほかのアプリは操作しません。")
        requestManagedShutdown(lease) { [weak self] success in
            guard let self else { return }
            guard success else {
                self.restartButton.isEnabled = true
                self.setState("再起動できません", detail: "管理トークンによる終了確認に失敗しました。元の起動元から停止してください。")
                return
            }
            self.waitForManagedServiceToExit(attemptsRemaining: 25)
        }
    }

    @objc private func start() {
        guard process == nil else { return }
        startButton.isEnabled = false
        setState("起動中…", detail: "ローカル補助サーバーを開始しています。")

        guard let root = Bundle.main.resourceURL?.appendingPathComponent("codex-mic-remote"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("server.mjs").path) else {
            setState("起動できません", detail: "アプリ内の Codex Mic Remote 本体が見つかりません。配布物をもう一度展開してください。")
            startButton.isEnabled = true
            return
        }
        guard let node = findNode() else {
            setState("Node.js が見つかりません", detail: "Node.js 18 以降をインストールしてから、このアプリをもう一度開いてください。")
            startButton.isEnabled = true
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = ["server.mjs"]
        task.currentDirectoryURL = root
        task.environment = ProcessInfo.processInfo.environment.merging([
            "PORT": String(serverPort),
            "CMR_ADMIN_FILE": adminFileURL.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]) { _, preferred in preferred }

        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consumeServerOutput(text) }
        }
        task.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async {
                guard let self else { return }
                output.fileHandleForReading.readabilityHandler = nil
                if self.process === completed {
                    self.process = nil
                    self.stopButton.isEnabled = false
                    self.startButton.isEnabled = true
                    self.clearConnection()
                    self.setState(self.didRequestStop ? "停止中" : "サーバーが停止しました", detail: self.didRequestStop ? "このアプリが起動したローカルサーバーを停止しました。" : "ポート \(serverPort) が他のアプリに使われている可能性があります。既存のサービスは停止していません。")
                }
            }
        }

        do {
            try task.run()
            didRequestStop = false
            process = task
            stopButton.isEnabled = true
        } catch {
            setState("起動できません", detail: error.localizedDescription)
            startButton.isEnabled = true
        }
    }

    @objc private func stop() {
        guard let process else { return }
        didRequestStop = true
        setState("停止中…", detail: "このアプリが起動したローカルサーバーだけを停止しています。")
        process.terminate()
    }

    private func probeForExistingService(startWhenVacant: Bool = false) {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/api/identity") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            let identity = ((response as? HTTPURLResponse)?.statusCode == 200)
                ? try? JSONDecoder().decode(ServiceIdentity.self, from: data ?? Data()) : nil
            DispatchQueue.main.async {
                guard let self, self.process == nil else { return }
                if let lease = self.readMatchingAdminLease(identity) {
                    self.verifiedAdminLease = lease
                    self.restartButton.isHidden = false
                    self.restartButton.isEnabled = true
                    self.setState("以前のリモートが起動中です", detail: "ランチャー管理の Codex Mic Remote を検出しました。「Codex Mic Remote を再起動」で、安全な終了APIを使って再起動できます。")
                    self.startButton.isEnabled = false
                    self.stopButton.isEnabled = false
                } else if self.portIsOccupied() {
                    self.verifiedAdminLease = nil
                    self.restartButton.isHidden = true
                    self.setState("ポート \(serverPort) を使用中です", detail: "確認できない、または旧版のプロセスがこのポートを使用しています。安全のため停止しません。元のアプリまたはターミナルから停止してから、もう一度起動してください。")
                    self.startButton.isEnabled = false
                    self.stopButton.isEnabled = false
                } else {
                    self.verifiedAdminLease = nil
                    self.restartButton.isHidden = true
                    self.stopButton.isEnabled = false
                    if startWhenVacant { self.start() }
                    else {
                        self.setState("停止中", detail: "下のボタンを一度押すだけで、ローカル補助サーバーを起動します。")
                        self.startButton.isEnabled = true
                    }
                }
            }
        }.resume()
    }

    private func readMatchingAdminLease(_ identity: ServiceIdentity?) -> AdminLease? {
        guard let identity,
              identity.kind == "codex-mic-remote",
              identity.protocolVersion == 1,
              let identityPID = identity.pid,
              let attributes = try? FileManager.default.attributesOfItem(atPath: adminFileURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: adminFileURL),
              let lease = try? JSONDecoder().decode(AdminLease.self, from: data),
              lease.kind == "codex-mic-remote-admin",
              lease.protocolVersion == 1,
              lease.pid == identityPID,
              lease.instanceId == identity.instanceId,
              !lease.token.isEmpty else { return nil }
        return lease
    }

    private func requestManagedShutdown(_ lease: AdminLease, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/api/admin/shutdown") else {
            completion(false); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(lease.token, forHTTPHeaderField: "X-CMR-Admin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["instanceId": lease.instanceId])
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async { completion((response as? HTTPURLResponse)?.statusCode == 200) }
        }.resume()
    }

    private func portIsOccupied() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/api/identity") else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var occupied = false
        URLSession.shared.dataTask(with: url) { _, response, error in
            occupied = response != nil || (error as NSError?)?.code != NSURLErrorCannotConnectToHost
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 0.5)
        return occupied
    }

    private func waitForManagedServiceToExit(attemptsRemaining: Int) {
        if !portIsOccupied() {
            verifiedAdminLease = nil
            restartButton.isHidden = true
            probeForExistingService(startWhenVacant: true)
            return
        }
        guard attemptsRemaining > 0 else {
            restartButton.isEnabled = true
            setState("再起動できません", detail: "安全な終了を待機しましたが、まだポート \(serverPort) を使用しています。元の起動元から停止してください。")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForManagedServiceToExit(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func consumeServerOutput(_ output: String) {
        pendingServerOutput += output
        while let ending = pendingServerOutput.firstIndex(of: "\n") {
            let line = String(pendingServerOutput[..<ending])
            pendingServerOutput.removeSubrange(...ending)
            consumeServerLine(line)
        }
    }

    private func consumeServerLine(_ line: String) {
        if let url = firstMatch(#"Codex Mic Remote is listening on (http://[^\s]+)"#, in: line) {
            listeningURL = url
            urlLabel.stringValue = url
        }
        if let code = firstMatch(#"Pairing code: (\d{6})"#, in: line) {
            pairingCode = code
            codeLabel.stringValue = code
            codeExpiryWork?.cancel()
            let expiry = DispatchWorkItem { [weak self] in self?.expirePairingCode(code) }
            codeExpiryWork = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 10 * 60, execute: expiry)
        }
        guard let url = listeningURL, let code = pairingCode else { return }
        setState("スマホを接続できます", detail: "同じWi-FiのスマホでQRコードを読み取るか、URLを開いてコードを入力してください。コードは10分間有効です。")
        // The fragment keeps the short-lived code out of ordinary HTTP request logs.
        // The remote page consumes it locally before calling the pairing endpoint.
        showQRCode(url: "\(url)/#pair=\(code)")
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func showQRCode(url: String) {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
        filter.setValue(Data(url.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return }
        let rendered = NSImage(size: image.extent.size)
        rendered.addRepresentation(NSCIImageRep(ciImage: image))
        qrView.image = rendered
        qrView.toolTip = url
    }

    private func expirePairingCode(_ code: String) {
        guard pairingCode == code else { return }
        pairingCode = nil
        codeLabel.stringValue = ""
        qrView.image = nil
        setState("コードの期限切れ", detail: "既存のスマホは継続して使えます。新しいスマホを接続するには、サーバーを停止してから起動してください。")
    }

    private func clearConnection() {
        codeExpiryWork?.cancel()
        listeningURL = nil
        pairingCode = nil
        urlLabel.stringValue = ""
        codeLabel.stringValue = ""
        qrView.image = nil
    }

    private func setState(_ title: String, detail: String) {
        statusLabel.stringValue = title
        detailLabel.stringValue = detail
    }

    private func findNode() -> String? {
        var candidates: [String] = []
        if let root = Bundle.main.resourceURL?.appendingPathComponent("codex-mic-remote"),
           let recorded = try? String(contentsOf: root.appendingPathComponent("node-path.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !recorded.isEmpty {
            candidates.append(recorded)
        }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
