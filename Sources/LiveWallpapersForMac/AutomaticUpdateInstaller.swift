import AppKit
import CryptoKit
import Foundation

enum AutomaticUpdatePhase {
    case downloading
    case verifying
    case preparing
}

enum AutomaticUpdateError: Error {
    case dmgAssetMissing
    case downloadFailed
    case integrityInformationMissing
    case checksumMismatch
    case mountFailed
    case applicationMissing
    case invalidMetadata
    case invalidSignature
    case designatedRequirementMismatch
    case unsupportedInstallLocation
    case stagingFailed
    case installerLaunchFailed

    func message(language: AppLanguage) -> String {
        let key: String
        switch self {
        case .dmgAssetMissing:
            key = "error.noDMG"
        case .downloadFailed:
            key = "error.download"
        case .integrityInformationMissing:
            key = "error.integrityMissing"
        case .checksumMismatch:
            key = "error.checksum"
        case .mountFailed:
            key = "error.mount"
        case .applicationMissing:
            key = "error.appMissing"
        case .invalidMetadata:
            key = "error.metadata"
        case .invalidSignature:
            key = "error.signature"
        case .designatedRequirementMismatch:
            key = "error.requirement"
        case .unsupportedInstallLocation:
            key = "error.location"
        case .stagingFailed:
            key = "error.staging"
        case .installerLaunchFailed:
            key = "error.launch"
        }
        return AutomaticUpdateCopy.text(key, language: language)
    }
}

enum AutomaticUpdateCopy {
    private static let russian: [String: String] = [
        "none.title": "Обновлений нет",
        "none.message": "Установлена последняя версия %@.",
        "available.title": "Доступно обновление %@",
        "available.message": "Установлена версия %@. Обновление будет скачано, проверено и установлено автоматически.",
        "install": "Установить обновление",
        "later": "Позже",
        "progress.title": "Установка обновления %@",
        "phase.download": "Скачивание подписанного DMG…",
        "phase.verify": "Проверка контрольной суммы и подписи…",
        "phase.prepare": "Подготовка безопасной замены приложения…",
        "error.checkTitle": "Проверка обновлений не выполнена",
        "error.installTitle": "Не удалось установить обновление",
        "error.openRelease": "Открыть страницу релиза",
        "close": "Закрыть",
        "error.noDMG": "В релизе не найден установочный DMG.",
        "error.download": "Не удалось скачать пакет обновления.",
        "error.integrityMissing": "У релиза отсутствует контрольная сумма SHA-256.",
        "error.checksum": "Контрольная сумма загруженного DMG не совпадает с данными GitHub.",
        "error.mount": "Не удалось проверить или подключить DMG.",
        "error.appMissing": "В DMG не найдено приложение Live Wallpapers for Mac.app.",
        "error.metadata": "Bundle ID, executable или версия обновления не совпадают с ожидаемыми.",
        "error.signature": "Подпись приложения в обновлении недействительна.",
        "error.requirement": "Подпись обновления отличается от установленной версии. Автоустановка остановлена для сохранения разрешений macOS.",
        "error.location": "Автообновление работает только для приложения, установленного в /Applications/Live Wallpapers for Mac.app. Текущую копию нужно один раз установить туда вручную.",
        "error.staging": "Не удалось подготовить обновление в папке «Программы».",
        "error.launch": "Не удалось запустить безопасную замену приложения."
    ]

    private static let english: [String: String] = [
        "none.title": "No Updates Available",
        "none.message": "Version %@ is already up to date.",
        "available.title": "Update %@ Available",
        "available.message": "Version %@ is installed. The update will be downloaded, verified and installed automatically.",
        "install": "Install Update",
        "later": "Later",
        "progress.title": "Installing Update %@",
        "phase.download": "Downloading the signed DMG…",
        "phase.verify": "Verifying checksum and signature…",
        "phase.prepare": "Preparing a safe application replacement…",
        "error.checkTitle": "Update Check Failed",
        "error.installTitle": "Update Installation Failed",
        "error.openRelease": "Open Release Page",
        "close": "Close",
        "error.noDMG": "The release does not contain an installer DMG.",
        "error.download": "The update package could not be downloaded.",
        "error.integrityMissing": "The release does not provide a SHA-256 checksum.",
        "error.checksum": "The downloaded DMG checksum does not match GitHub.",
        "error.mount": "The DMG could not be verified or mounted.",
        "error.appMissing": "Live Wallpapers for Mac.app was not found in the DMG.",
        "error.metadata": "The update Bundle ID, executable or version is not the expected value.",
        "error.signature": "The application signature in the update is invalid.",
        "error.requirement": "The update signature differs from the installed version. Automatic installation was stopped to preserve macOS permissions.",
        "error.location": "Automatic updates require the app at /Applications/Live Wallpapers for Mac.app. Install the current copy there manually once.",
        "error.staging": "The update could not be prepared in Applications.",
        "error.launch": "The safe application replacement could not be started."
    ]

    static func text(_ key: String, language: AppLanguage) -> String {
        let table = language == .russian ? russian : english
        return table[key] ?? english[key] ?? key
    }

    static func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        String(format: text(key, language: language), locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
}

enum AutomaticUpdateInstaller {
    private static let applicationName = "Live Wallpapers for Mac.app"
    private static let expectedBundleIdentifier = "com.medusa411.LiveWallpapersForMac"
    private static let expectedExecutable = "Live Wallpapers for Mac"

    static func install(
        release: GitHubReleaseResponse,
        expectedVersion: String,
        progress: @escaping @Sendable (AutomaticUpdatePhase) -> Void
    ) async throws {
        guard let dmgAsset = release.assets.first(where: {
            $0.name.lowercased().hasSuffix(".dmg")
        }) else {
            throw AutomaticUpdateError.dmgAssetMissing
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-wallpapers-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        progress(.downloading)
        let dmgURL = try await download(asset: dmgAsset, into: temporaryRoot)
        let expectedDigest = try await resolveDigest(for: dmgAsset, release: release)
        guard sha256(of: dmgURL) == expectedDigest else {
            throw AutomaticUpdateError.checksumMismatch
        }

        progress(.verifying)
        let mountPoint = temporaryRoot.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        do {
            try runProcess(
                executable: "/usr/bin/hdiutil",
                arguments: ["attach", dmgURL.path, "-readonly", "-nobrowse", "-mountpoint", mountPoint.path]
            )
        } catch {
            throw AutomaticUpdateError.mountFailed
        }

        var isMounted = true
        defer {
            if isMounted {
                _ = try? runProcess(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", mountPoint.path, "-force"]
                )
            }
        }

        let candidateURL = mountPoint.appendingPathComponent(applicationName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            throw AutomaticUpdateError.applicationMissing
        }

        try validateMetadata(at: candidateURL, expectedVersion: expectedVersion, requireCanonicalName: true)
        try verifySignature(at: candidateURL)

        let currentURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let destinationURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(applicationName, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard currentURL == destinationURL else {
            throw AutomaticUpdateError.unsupportedInstallLocation
        }

        try verifySignature(at: currentURL)
        let currentRequirement = try designatedRequirement(at: currentURL)
        let candidateRequirement = try designatedRequirement(at: candidateURL)
        guard currentRequirement == candidateRequirement,
              !candidateRequirement.localizedCaseInsensitiveContains("cdhash") else {
            throw AutomaticUpdateError.designatedRequirementMismatch
        }

        progress(.preparing)
        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".Live Wallpapers for Mac.update-\(UUID().uuidString).app", isDirectory: true)

        do {
            try runProcess(
                executable: "/usr/bin/ditto",
                arguments: [candidateURL.path, stagingURL.path]
            )
            try validateMetadata(at: stagingURL, expectedVersion: expectedVersion, requireCanonicalName: false)
            try verifySignature(at: stagingURL)
            guard try designatedRequirement(at: stagingURL) == currentRequirement else {
                throw AutomaticUpdateError.designatedRequirementMismatch
            }
        } catch let error as AutomaticUpdateError {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw AutomaticUpdateError.stagingFailed
        }

        try runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint.path, "-force"]
        )
        isMounted = false

        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-wallpapers-self-update-\(UUID().uuidString).sh")
        let backupURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".Live Wallpapers for Mac.backup-\(UUID().uuidString).app", isDirectory: true)
        let script = installerScript(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            stagingURL: stagingURL,
            destinationURL: destinationURL,
            backupURL: backupURL,
            helperURL: helperURL,
            designatedRequirement: currentRequirement
        )

        do {
            try script.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: helperURL.path
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [helperURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: helperURL)
            throw AutomaticUpdateError.installerLaunchFailed
        }

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    private static func download(
        asset: GitHubReleaseResponse.Asset,
        into directory: URL
    ) async throws -> URL {
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(for: request(for: asset.browserDownloadURL))
            try validateHTTP(response)
            let destination = directory.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        } catch let error as AutomaticUpdateError {
            throw error
        } catch {
            throw AutomaticUpdateError.downloadFailed
        }
    }

    private static func resolveDigest(
        for dmgAsset: GitHubReleaseResponse.Asset,
        release: GitHubReleaseResponse
    ) async throws -> String {
        if let digest = normalizedDigest(dmgAsset.digest) {
            return digest
        }

        guard let checksumAsset = release.assets.first(where: {
            $0.name.lowercased() == "\(dmgAsset.name.lowercased()).sha256"
        }) else {
            throw AutomaticUpdateError.integrityInformationMissing
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request(for: checksumAsset.browserDownloadURL))
            try validateHTTP(response)
            guard let contents = String(data: data, encoding: .utf8),
                  let rawDigest = contents.split(whereSeparator: { $0.isWhitespace }).first,
                  let digest = normalizedDigest(String(rawDigest)) else {
                throw AutomaticUpdateError.integrityInformationMissing
            }
            return digest
        } catch let error as AutomaticUpdateError {
            throw error
        } catch {
            throw AutomaticUpdateError.integrityInformationMissing
        }
    }

    private static func request(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 60
        )
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("Live Wallpapers for Mac Updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw AutomaticUpdateError.downloadFailed
        }
    }

    private static func normalizedDigest(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if value.hasPrefix("sha256:") {
            value.removeFirst("sha256:".count)
        }
        guard value.count == 64,
              value.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return value
    }

    private static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return ""
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateMetadata(
        at appURL: URL,
        expectedVersion: String,
        requireCanonicalName: Bool
    ) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              info["CFBundleExecutable"] as? String == expectedExecutable,
              !requireCanonicalName || appURL.lastPathComponent == applicationName,
              let version = info["CFBundleShortVersionString"] as? String,
              normalizedVersion(version) == normalizedVersion(expectedVersion) else {
            throw AutomaticUpdateError.invalidMetadata
        }
    }

    private static func normalizedVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.drop { $0 == "v" || $0 == "V" }
        let numericPrefix = withoutPrefix.prefix { $0.isNumber || $0 == "." }
        return numericPrefix.isEmpty ? trimmed : String(numericPrefix)
    }

    private static func verifySignature(at appURL: URL) throws {
        do {
            try runProcess(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
            )
        } catch {
            throw AutomaticUpdateError.invalidSignature
        }
    }

    private static func designatedRequirement(at appURL: URL) throws -> String {
        let output: String
        do {
            output = try runProcess(
                executable: "/usr/bin/codesign",
                arguments: ["-d", "-r-", appURL.path]
            )
        } catch {
            throw AutomaticUpdateError.invalidSignature
        }

        guard let requirement = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("designated =>") }) else {
            throw AutomaticUpdateError.invalidSignature
        }
        return requirement
    }

    @discardableResult
    private static func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: AppBrand.errorDomain,
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
        return text
    }

    private static func installerScript(
        processIdentifier: Int32,
        stagingURL: URL,
        destinationURL: URL,
        backupURL: URL,
        helperURL: URL,
        designatedRequirement: String
    ) -> String {
        let staging = shellEscape(stagingURL.path)
        let destination = shellEscape(destinationURL.path)
        let backup = shellEscape(backupURL.path)
        let helper = shellEscape(helperURL.path)
        let requirement = designatedRequirement.replacingOccurrences(of: "designated => ", with: "")
        let requirementArgument = shellEscape("-R=\(requirement)")

        return """
        #!/bin/zsh
        set -u

        for _ in {1..300}; do
          if ! /bin/kill -0 \(processIdentifier) >/dev/null 2>&1; then
            break
          fi
          /bin/sleep 0.1
        done

        if /bin/kill -0 \(processIdentifier) >/dev/null 2>&1; then
          /usr/bin/open \(destination) >/dev/null 2>&1 || true
          /bin/rm -rf \(staging)
          /bin/rm -f \(helper)
          exit 20
        fi

        had_previous=0
        if [[ -e \(destination) ]]; then
          /bin/mv \(destination) \(backup) || exit 21
          had_previous=1
        fi

        if /bin/mv \(staging) \(destination) \
          && /usr/bin/codesign --verify --deep --strict \(requirementArgument) \(destination) >/dev/null 2>&1; then
          if [[ "$had_previous" == "1" ]]; then
            /bin/rm -rf \(backup)
          fi
          /usr/bin/open \(destination)
          /bin/rm -f \(helper)
          exit 0
        fi

        /bin/rm -rf \(destination)
        if [[ "$had_previous" == "1" && -e \(backup) ]]; then
          /bin/mv \(backup) \(destination)
          /usr/bin/open \(destination) >/dev/null 2>&1 || true
        fi
        /bin/rm -rf \(staging)
        /bin/rm -f \(helper)
        exit 22
        """
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
