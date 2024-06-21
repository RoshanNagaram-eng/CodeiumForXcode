import Foundation
import Terminal

public struct CodeiumInstallationManager {
    private static var isInstalling = false
    static let latestSupportedVersion = "1.8.5"
    let isEnterpriseMode = UserDefaults.shared.value(for: \.codeiumEnterpriseMode)
    let enterprisePortalUrl = UserDefaults.shared.value(for: \.codeiumPortalUrl)
    let enterpriseVersion = UserDefaults.shared.value(for: \.codeiumEnterpriseVersion)
    
    public init() {}
    
    
    public func isEnterprise() -> Bool {
        // Before doing any Enterprise Logic, enterprise mode must be set, we must have a url, and an enterpriseVersion grabbed from the URL, otherwise we default to regular user logic for checking and updating
        return isEnterpriseMode && (self.enterprisePortalUrl != "") && (self.enterpriseVersion != "")
    }
    
    public func getLatestSupportedVersion() -> String {
        if isEnterprise() {
            return enterpriseVersion;
        }
        
        return Self.latestSupportedVersion;
        
    }

    public enum InstallationStatus {
        case notInstalled
        case installed(String)
        case outdated(current: String, latest: String)
        case unsupported(current: String, latest: String)
    }

    public func checkInstallation() -> InstallationStatus {
        guard let urls = try? CodeiumSuggestionService.createFoldersIfNeeded()
        else { return .notInstalled }
        let executableFolderURL = urls.executableURL
        let binaryURL = executableFolderURL.appendingPathComponent("language_server")
        let versionFileURL = executableFolderURL.appendingPathComponent("version")

        if !FileManager.default.fileExists(atPath: binaryURL.path) {
            return .notInstalled
        }
        // For Non Enterprise Users, compare current version to the previous latestSupportedVersion
        if !isEnterprise() {
            if FileManager.default.fileExists(atPath: versionFileURL.path),
               let versionData = try? Data(contentsOf: versionFileURL),
               let version = String(data: versionData, encoding: .utf8)
            {
                switch version.compare(Self.latestSupportedVersion, options: .numeric) {
                case .orderedAscending:
                    return .outdated(current: version, latest: Self.latestSupportedVersion)
                case .orderedSame:
                    return .installed(version)
                case .orderedDescending:
                    return .unsupported(current: version, latest: Self.latestSupportedVersion)
                }
            }
            return .outdated(current: "Unknown", latest: Self.latestSupportedVersion)
        } else {
        // For Enterprise Users, fetch the enterprise version from the enterprise portal and compare it to the current version
            
            if FileManager.default.fileExists(atPath: versionFileURL.path),
               let versionData = try? Data(contentsOf: versionFileURL),
               let version = String(data: versionData, encoding: .utf8)
            {
                switch version.compare(self.enterpriseVersion, options: .numeric) {
                case .orderedAscending:
                    return .outdated(current: version, latest: self.enterpriseVersion)
                case .orderedSame:
                    return .installed(version)
                case .orderedDescending:
                    return .unsupported(current: version, latest: self.enterpriseVersion)
                }
            }
            return .outdated(current: "Unknown", latest: self.enterpriseVersion)
        }
    }
    
    public enum InstallationStep {
        case downloading
        case uninstalling
        case decompressing
        case done
    }

    public func installLatestVersion() -> AsyncThrowingStream<InstallationStep, Error> {
        AsyncThrowingStream<InstallationStep, Error> { continuation in
            Task {
                guard !CodeiumInstallationManager.isInstalling else {
                    continuation.finish(throwing: CodeiumError.languageServiceIsInstalling)
                    return
                }
                CodeiumInstallationManager.isInstalling = true
                defer { CodeiumInstallationManager.isInstalling = false }
                do {
                    continuation.yield(.downloading)
                    let urls = try CodeiumSuggestionService.createFoldersIfNeeded()
                    var urlString: String
                    if !isEnterprise() {
                        urlString =
                            "https://github.com/Exafunction/codeium/releases/download/language-server-v\(Self.latestSupportedVersion)/language_server_macos_\(isAppleSilicon() ? "arm" : "x64").gz"
                    } else {
                        urlString =
                        "\(self.enterprisePortalUrl)/language-server-v\(self.enterpriseVersion)/language_server_macos_\(isAppleSilicon() ? "arm" : "x64").gz"
                    }
  
                    guard let url = URL(string: urlString) else { return }

                    // download
                    let (fileURL, _) = try await URLSession.shared.download(from: url)
                    let targetURL = urls.executableURL.appendingPathComponent("language_server")
                        .appendingPathExtension("gz")
                    try FileManager.default.copyItem(at: fileURL, to: targetURL)
                    defer { try? FileManager.default.removeItem(at: targetURL) }

                    // uninstall
                    continuation.yield(.uninstalling)
                    try await uninstall()

                    // extract file
                    continuation.yield(.decompressing)
                    let terminal = Terminal()
                    _ = try await terminal.runCommand(
                        "/usr/bin/gunzip",
                        arguments: [targetURL.path],
                        environment: [:]
                    )

                    // update permission 755
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: targetURL.deletingPathExtension().path
                    )
                    var data: Data?
                    // create version file
                    if !isEnterprise() {
                        data = Self.latestSupportedVersion.data(using: .utf8)
                    } else {
                        data = self.enterpriseVersion.data(using: .utf8)
                    }
                    
                    FileManager.default.createFile(
                        atPath: urls.executableURL.appendingPathComponent("version").path,
                        contents: data
                    )

                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func uninstall() async throws {
        guard let urls = try? CodeiumSuggestionService.createFoldersIfNeeded()
        else { return }
        let executableFolderURL = urls.executableURL
        let binaryURL = executableFolderURL.appendingPathComponent("language_server")
        let versionFileURL = executableFolderURL.appendingPathComponent("version")
        if FileManager.default.fileExists(atPath: binaryURL.path) {
            try FileManager.default.removeItem(at: binaryURL)
        }
        if FileManager.default.fileExists(atPath: versionFileURL.path) {
            try FileManager.default.removeItem(at: versionFileURL)
        }
    }
}

func isAppleSilicon() -> Bool {
    var result = false
    #if arch(arm64)
    result = true
    #endif
    return result
}

