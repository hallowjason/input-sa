import Foundation
import Darwin

/// Independent CLI invocation per utterance; no sessions or warm conversation.
final class CLITextService {
    static let shared = CLITextService()
    private let executableResolver: (APIKeyStore.PolishProvider) -> URL?
    private let environmentValidator: (APIKeyStore.PolishProvider) -> Bool

    init(executableResolver: @escaping (APIKeyStore.PolishProvider) -> URL? = CLITextService.executable,
         environmentValidator: @escaping (APIKeyStore.PolishProvider) -> Bool = CLITextService.environmentIsUnmanaged) {
        self.executableResolver = executableResolver
        self.environmentValidator = environmentValidator
    }

    static func isAvailable(provider: APIKeyStore.PolishProvider) -> Bool {
        executable(provider: provider) != nil
    }

    @discardableResult
    func enhance(text: String, mode: TranscriptionMode, provider: APIKeyStore.PolishProvider,
                 priorContext: String? = nil,
                 completion: @escaping (Result<String, Error>) -> Void) -> CLITextRequest? {
        run(prompt: mode.systemPrompt(transcript: text, priorContext: priorContext),
            provider: provider, completion: completion)
    }

    @discardableResult
    func checkConnection(provider: APIKeyStore.PolishProvider,
                         completion: @escaping (Result<String, Error>) -> Void) -> CLITextRequest? {
        // Explicit terms bypass private user vocabulary. No history is supplied.
        let prompt = TranscriptionMode.standard.systemPrompt(transcript: "這是 Input-sa 文字整理連線測試。",
            vocabularyTerms: SpeechRecognitionHints.builtInTerms)
        return run(prompt: prompt, provider: provider, completion: completion)
    }

    private func run(prompt: String, provider: APIKeyStore.PolishProvider,
                     completion: @escaping (Result<String, Error>) -> Void) -> CLITextRequest? {
        do {
            guard let executable = executableResolver(provider) else { throw CLITextError.unavailable }
            guard environmentValidator(provider) else { throw CLITextError.managedConfiguration }
            if provider == .codex {
                return CLIProcessRunner.run(input: prompt, prepare: { request in
                    var versionCommand = CLIProcessConfiguration(executable: executable, arguments: ["--version"], output: .standardOutput)
                    versionCommand.timeout = 4
                    let version = try CLIProcessRunner.captureMetadata(versionCommand, request: request)
                    guard version == Self.verifiedCodexVersion else { throw CLITextError.unsafeConfiguration }
                    let account = try CLIProcessRunner.captureMetadata(Self.codexAccountConfiguration(executable: executable), request: request)
                    guard Self.permitsPersonalCodexAccount(account) else { throw CLITextError.managedConfiguration }
                    // This exact command reads only the CLI's compiled-in public
                    // model catalog, not account credentials or user configuration.
                    var catalogCommand = CLIProcessConfiguration(executable: executable,
                        arguments: ["debug", "models", "--bundled"], output: .standardOutput)
                    catalogCommand.timeout = 8
                    catalogCommand.streamLimit = 2 * 1024 * 1024
                    catalogCommand.outputLimit = 2 * 1024 * 1024
                    let catalog = try CLIProcessRunner.captureMetadata(catalogCommand, request: request)
                    guard self.environmentValidator(provider) else { throw CLITextError.managedConfiguration }
                    return try Self.configuration(provider: provider, executable: executable,
                        codexVersion: version, codexCatalog: Data(catalog.utf8))
                }, completion: completion)
            }
            return CLIProcessRunner.run(input: prompt, prepare: { request in
                guard provider == .claude else { throw CLITextError.unsupportedProvider }
                var accountCommand = CLIProcessConfiguration(executable: executable, arguments: [
                    "--safe-mode", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
                    "auth", "status", "--json"
                ], output: .standardOutput)
                accountCommand.timeout = 8
                let account = try CLIProcessRunner.captureMetadata(accountCommand, request: request)
                guard Self.permitsPersonalClaudeAccount(account), self.environmentValidator(provider)
                else { throw CLITextError.managedConfiguration }
                return try Self.configuration(provider: provider, executable: executable)
            }, completion: completion)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return nil
        }
    }

    static func executable(provider: APIKeyStore.PolishProvider) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL]
        switch provider {
        case .claude:
            candidates = [home.appendingPathComponent(".local/bin/claude"),
                          URL(fileURLWithPath: "/usr/local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude")]
        case .codex:
            candidates = [URL(fileURLWithPath: "/usr/local/bin/codex"), URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                          URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")]
        default: return nil
        }
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            let resolved = candidate.resolvingSymlinksInPath()
            if isNativeExecutable(resolved) { return resolved }
            // The npm launcher spawns a native child. Own that native process
            // directly so SIGKILL cannot leave it behind after killing Node.
            if provider == .codex, resolved.lastPathComponent == "codex.js",
               resolved.deletingLastPathComponent().lastPathComponent == "bin" {
                let package = resolved.deletingLastPathComponent().deletingLastPathComponent()
                guard package.lastPathComponent == "codex", package.deletingLastPathComponent().lastPathComponent == "@openai" else { continue }
                #if arch(arm64)
                let platform = "darwin-arm64", triple = "aarch64-apple-darwin"
                #else
                let platform = "darwin-x64", triple = "x86_64-apple-darwin"
                #endif
                let relative = "vendor/\(triple)/bin/codex"
                let nativeCandidates = [package.appendingPathComponent("node_modules/@openai/codex-\(platform)/\(relative)"),
                    package.appendingPathComponent(relative),
                    package.deletingLastPathComponent().appendingPathComponent("codex-\(platform)/\(relative)")]
                if let native = nativeCandidates.first(where: isNativeExecutable) { return native.resolvingSymlinksInPath() }
            }
        }
        return nil
    }

    private static func isNativeExecutable(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return false }
        return [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
                [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
                [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]].contains(Array(header))
    }

    static let verifiedCodexVersion = "codex-cli 0.154.0"
    static let codexModel = "gpt-5.5"

    static func environmentIsUnmanaged(provider: APIKeyStore.PolishProvider) -> Bool {
        if provider == .claude {
            // Any managed preference is conservatively rejected. Inspect only
            // key presence, across all macOS user/host scopes, never values.
            for user in [kCFPreferencesCurrentUser, kCFPreferencesAnyUser] {
                for host in [kCFPreferencesCurrentHost, kCFPreferencesAnyHost] {
                    if let keys = CFPreferencesCopyKeyList("com.anthropic.claudecode" as CFString, user, host), CFArrayGetCount(keys) > 0 {
                        return false
                    }
                }
            }
            let system = "/Library/Application Support/ClaudeCode/"
            return permitsUnmanagedCodex(paths: [system + "managed-settings.json", system + "managed-settings.d",
                system + "managed-mcp.json", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/remote-settings.json").path],
                managedPreferencePresent: false)
        }
        guard provider == .codex else { return false }
        let managedKeys = ["config_toml_base64", "requirements_toml_base64"]
        let hasManagedPreference = managedKeys.contains {
            CFPreferencesCopyAppValue($0 as CFString, "com.openai.codex" as CFString) != nil
        }
        return permitsUnmanagedCodex(paths: ["/etc/codex/config.toml", "/etc/codex/managed_config.toml",
            "/etc/codex/requirements.toml"], managedPreferencePresent: hasManagedPreference)
    }

    /// Inspect presence only; never read system configuration or embedded secrets.
    static func permitsUnmanagedCodex(paths: [String], managedPreferencePresent: Bool) -> Bool {
        guard !managedPreferencePresent else { return false }
        for path in paths {
            var attributes = stat()
            if lstat(path, &attributes) == 0 || errno != ENOENT { return false }
        }
        return true
    }

    /// account/read (refreshToken=false) contains plan metadata, not tokens.
    /// Managed/unknown plans are rejected because they may add cloud MCP config.
    static func permitsPersonalCodexAccount(_ response: String) -> Bool {
        guard let data = response.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (reply["id"] as? Int) == 2, reply["error"] == nil,
              let result = reply["result"] as? [String: Any],
              let account = result["account"] as? [String: Any],
              (account["type"] as? String) == "chatgpt",
              let plan = account["planType"] as? String else { return false }
        return ["free", "go", "plus", "pro", "prolite"].contains(plan)
    }

    static func permitsPersonalClaudeAccount(_ response: String) -> Bool {
        guard let data = response.data(using: .utf8),
              let account = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (account["loggedIn"] as? Bool) == true,
              (account["authMethod"] as? String) == "claude.ai",
              (account["apiProvider"] as? String) == "firstParty",
              let plan = account["subscriptionType"] as? String else { return false }
        return ["pro", "max"].contains(plan)
    }

    static func codexAccountConfiguration(executable: URL) -> CLIProcessConfiguration {
        var arguments = ["app-server", "--listen", "stdio://", "--strict-config"]
        for setting in ["features.hooks=false", "features.plugins=false", "features.remote_plugin=false",
            "features.apps=false", "features.skip_host_skill_discovery=true", "notify=[]",
            "project_doc_max_bytes=0", "skills.include_instructions=false", "skills.bundled.enabled=false",
            "check_for_update_on_startup=false"] { arguments += ["-c", setting] }
        var configuration = CLIProcessConfiguration(executable: executable, arguments: arguments, output: .standardOutput)
        configuration.timeout = 10
        configuration.jsonRPCHandshake = CLIJSONRPCHandshake(
            initialize: "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"inputsa-safety-check\",\"version\":\"1.0\"}}}\n",
            afterInitialization: "{\"method\":\"initialized\",\"params\":{}}\n{\"id\":2,\"method\":\"account/read\",\"params\":{\"refreshToken\":false}}\n")
        return configuration
    }

    /// Kept pure so security flags are reviewable without launching a real CLI.
    static func configuration(provider: APIKeyStore.PolishProvider, executable: URL,
                              codexVersion: String? = nil, codexCatalog: Data? = nil) throws -> CLIProcessConfiguration {
        switch provider {
        case .claude:
            return CLIProcessConfiguration(executable: executable, arguments: [
                "-p", "--safe-mode", "--tools", "", "--strict-mcp-config",
                "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence", "--no-chrome",
                "--output-format", "text", "--setting-sources", "", "--disable-slash-commands",
                "--settings", "{\"disableAllHooks\":true}"
            ], output: .standardOutput)
        case .codex:
            guard codexVersion == verifiedCodexVersion, let raw = codexCatalog else { throw CLITextError.unsafeConfiguration }
            let catalog = try sanitizedCodexCatalog(raw)
            var arguments = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--strict-config",
                "--skip-git-repo-check", "--color", "never", "-s", "read-only", "-m", codexModel,
                "--output-last-message", "result.txt"]
            let settings = [
                "web_search=\"disabled\"", "agents.enabled=false", "tools.experimental_request_user_input.enabled=false",
                "tools.update_plan.enabled=false", "orchestrator.skills.enabled=false", "orchestrator.mcp.enabled=false",
                "skills.include_instructions=false", "skills.bundled.enabled=false", "project_doc_max_bytes=0",
                "include_environment_context=false", "include_apps_instructions=false", "check_for_update_on_startup=false",
                "history.persistence=\"none\"", "approval_policy=\"never\"", "features.skip_host_skill_discovery=true", "notify=[]"
            ]
            let disabledFeatures = ["shell_tool", "view_image", "apps", "plugins", "remote_plugin", "multi_agent",
                "multi_agent_v2", "goals", "image_generation", "sleep_tool", "request_permissions_tool", "token_budget",
                "current_time_reminder", "deferred_executor", "code_mode", "code_mode_only", "code_mode_host",
                "browser_use", "computer_use", "in_app_browser", "memories", "memory_tool", "skill_search",
                "executor_capability_discovery", "hooks", "shell_snapshot"]
            for setting in settings + disabledFeatures.map({ "features.\($0)=false" }) { arguments += ["-c", setting] }
            arguments.append("-")
            var configuration = CLIProcessConfiguration(executable: executable, arguments: arguments, output: .file("result.txt"))
            configuration.supportingFiles = ["models.json": catalog]
            configuration.fileConfigurations = ["model_catalog_json": "models.json"]
            return configuration
        default: throw CLITextError.unsupportedProvider
        }
    }

    /// 0.154.0 registers some tools from model metadata even with feature flags
    /// disabled. Remove those capabilities from every bundled model, preserving
    /// the rest of the version-matched transport metadata. Unknown shapes fail closed.
    static func sanitizedCodexCatalog(_ data: Data) throws -> Data {
        guard data.count <= 2 * 1024 * 1024,
              var catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var models = catalog["models"] as? [[String: Any]], !models.isEmpty,
              models.contains(where: { ($0["slug"] as? String) == codexModel }) else { throw CLITextError.unsafeConfiguration }
        var seen = Set<String>()
        for index in models.indices {
            guard let slug = models[index]["slug"] as? String, !slug.isEmpty, seen.insert(slug).inserted else { throw CLITextError.unsafeConfiguration }
            models[index]["apply_patch_tool_type"] = NSNull()
            models[index]["experimental_supported_tools"] = [String]()
            models[index]["shell_type"] = "disabled"
            models[index]["tool_mode"] = "direct"
            models[index]["supports_search_tool"] = false
        }
        catalog["models"] = models
        guard let sanitized = try? JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]) else { throw CLITextError.unsafeConfiguration }
        return sanitized
    }
}
