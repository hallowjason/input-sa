import Foundation
import Darwin

/// All executables here are temporary synthetic fixtures. Never launches an AI
/// CLI, reads credentials, opens a microphone, or makes a network request.
@main
struct CLITextServiceTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inputsa-cli-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            checks += 1
            if !value { throw NSError(domain: "CLI fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        }
        func fixture(_ body: String) throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        func run(_ configuration: CLIProcessConfiguration, input: String = "synthetic input",
                 cancelAfter: TimeInterval? = nil) throws -> (Result<String, Error>, CLITextRequest) {
            var response: Result<String, Error>?
            var callbackOnMain = false
            let request = CLIProcessRunner.run(configuration: configuration, input: input) {
                callbackOnMain = Thread.isMainThread
                response = $0
            }
            if let delay = cancelAfter { DispatchQueue.global().asyncAfter(deadline: .now() + delay) { request.cancel() } }
            let deadline = Date().addingTimeInterval(5)
            while response == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try check(callbackOnMain, "completion is delivered on main")
            guard let response = response else { throw NSError(domain: "fixture timeout", code: 2) }
            return (response, request)
        }

        let echo = try fixture("/bin/cat")
        var config = CLIProcessConfiguration(executable: echo, arguments: [], output: .standardOutput)
        let sensitiveFixture = "SYNTHETIC_PRIVATE_TEXT_42\n第二行 Codex Claude"
        let echoResult = try run(config, input: sensitiveFixture)
        try check(try echoResult.0.get() == sensitiveFixture, "stdin receives all Unicode text and EOF")
        config.streamLimit = 128 * 1024
        config.outputLimit = 128 * 1024
        let largeInput = String(repeating: "界", count: 30000)
        try check(try run(config, input: largeInput).0.get() == largeInput, "stdin larger than a pipe buffer is complete without blocking main")
        config.executable = try fixture("printf 'premature result'\nexit 0")
        if case .failure = try run(config, input: largeInput).0 { try check(true, "early stdin close cannot crash host or return partial-input result") }
        else { try check(false, "early stdin close must fail") }

        config.executable = try fixture("/bin/cat >/dev/null\nprintf '%s' \"$*\"")
        config.arguments = ["static-flag"]
        try check(try run(config, input: sensitiveFixture).0.get() == "static-flag", "dynamic input never enters argv")

        setenv("INPUTSA_TEST_SECRET", "SYNTHETIC_SECRET", 1)
        defer { unsetenv("INPUTSA_TEST_SECRET") }
        config.executable = try fixture("/bin/cat >/dev/null\n/usr/bin/env")
        config.arguments = []
        let environment = try run(config).0.get()
        try check(!environment.contains("INPUTSA_TEST_SECRET") && !environment.contains("OPENAI_API_KEY=")
            && !environment.contains("ANTHROPIC_API_KEY=") && !environment.contains("CODEX_HOME=")
            && !environment.contains("HTTP_PROXY="), "child does not inherit secrets, CLI state or proxy environment")
        try check(environment.contains("HOME=") && environment.contains("PATH=")
            && environment.contains("USER=") && environment.contains("LOGNAME="), "existing login can use HOME, OS username and basic PATH")

        config.executable = try fixture("/bin/cat >/dev/null\n/bin/pwd")
        let directory = try run(config).0.get()
        try check(directory.contains("inputsa-cli-") && !FileManager.default.fileExists(atPath: directory),
                  "request runs in a neutral temporary cwd and removes it")

        config.executable = try fixture("/bin/cat >/dev/null\nprintf 'RAW_SECRET_ERROR' >&2\nexit 17")
        if case .failure(let error) = try run(config).0 {
            try check(!error.localizedDescription.contains("RAW_SECRET_ERROR"), "errors omit raw stderr")
        } else { try check(false, "nonzero exit must fail") }

        config.executable = try fixture("/bin/cat >/dev/null")
        if case .failure = try run(config).0 { try check(true, "empty output fails") }
        else { try check(false, "empty output fails") }

        config.output = .file("result.txt")
        config.executable = try fixture("/bin/cat >/dev/null\nprintf 'OpenAI Codex banner'\nprintf 'final result' >result.txt")
        try check(try run(config).0.get() == "final result", "Codex result comes only from final output file")
        config.executable = try fixture("/bin/cat >/dev/null\nprintf 'OpenAI Codex banner'")
        if case .failure = try run(config).0 { try check(true, "banner-only stdout is never a result") }
        else { try check(false, "banner-only stdout is never a result") }
        config.executable = try fixture("/bin/cat >/dev/null\n/bin/ln -s /etc/hosts result.txt")
        if case .failure = try run(config).0 { try check(true, "final-output symlink is rejected") }
        else { try check(false, "final-output symlink is rejected") }
        config.outputLimit = 512
        config.executable = try fixture("while :; do printf '12345678901234567890123456789012' >>result.txt; done")
        if case .failure(let error) = try run(config).0 { try check((error as? CLITextError) == .outputTooLarge, "final output file growth is bounded during execution") }
        else { try check(false, "oversized result file must fail") }
        config.outputLimit = 64 * 1024

        config.output = .standardOutput
        config.timeout = 0.1
        config.terminationGrace = 0.05
        config.executable = try fixture("trap '' TERM\nwhile :; do :; done")
        let began = Date()
        if case .failure(let error) = try run(config).0 {
            try check((error as? CLITextError) == .timeout && Date().timeIntervalSince(began) < 2,
                      "timeout kills and reaps a child that ignores SIGTERM")
        } else { try check(false, "timeout must fail") }
        config.timeout = 3
        let cancelled = try run(config, cancelAfter: 0.05)
        if case .failure(let error) = cancelled.0 { try check((error as? URLError)?.code == .cancelled, "cancel never returns text") }
        else { try check(false, "cancel must fail") }

        config.executable = echo
        let completed = try run(config, input: "first")
        completed.1.cancel()
        try check(try run(config, input: "second").0.get() == "second", "late cancellation cannot terminate the next request")

        config.streamLimit = 1024
        config.executable = try fixture("while :; do printf '12345678901234567890123456789012'; done")
        if case .failure(let error) = try run(config).0 { try check((error as? CLITextError) == .outputTooLarge, "stdout is bounded during execution") }
        else { try check(false, "oversized stdout must fail") }
        config.executable = try fixture("while :; do printf '12345678901234567890123456789012' >&2; done")
        if case .failure(let error) = try run(config).0 { try check((error as? CLITextError) == .outputTooLarge, "stderr is bounded without retaining its text") }
        else { try check(false, "oversized stderr must fail") }
        config.executable = echo
        config.inputLimit = 4
        if case .failure(let error) = try run(config, input: "too long").0 { try check((error as? CLITextError) == .inputTooLarge, "oversized stdin is rejected") }
        else { try check(false, "oversized stdin must fail") }

        let claude = try CLITextService.configuration(provider: .claude, executable: echo)
        try check(claude.arguments.contains("--safe-mode") && claude.arguments.contains("--no-session-persistence")
            && claude.arguments.contains("--strict-mcp-config") && !claude.arguments.contains("--bare"), "Claude uses supported isolation flags without discarding OAuth")
        let catalog = Data("""
        {"models":[{"slug":"gpt-5.5","apply_patch_tool_type":"freeform","experimental_supported_tools":["shell"],"shell_type":"shell_command","tool_mode":"code","supports_search_tool":true,"context_window":32768}]}
        """.utf8)
        let codex = try CLITextService.configuration(provider: .codex, executable: echo,
            codexVersion: CLITextService.verifiedCodexVersion, codexCatalog: catalog)
        try check(codex.arguments.contains("--ignore-user-config") && codex.arguments.contains("--ignore-rules")
            && codex.arguments.contains("--ephemeral") && codex.arguments.contains("read-only")
            && codex.arguments.last == "-", "Codex uses ephemeral isolated read-only execution with stdin")
        let sanitized = try JSONSerialization.jsonObject(with: codex.supportingFiles["models.json"]!) as! [String: Any]
        let model = (sanitized["models"] as! [[String: Any]])[0]
        try check(model["apply_patch_tool_type"] is NSNull && (model["experimental_supported_tools"] as? [String]) == []
            && (model["shell_type"] as? String) == "disabled" && (model["tool_mode"] as? String) == "direct"
            && (model["supports_search_tool"] as? Bool) == false, "all model-catalog tool capabilities are cleared")
        try check((model["context_window"] as? Int) == 32768, "unrelated model transport metadata is preserved")
        do {
            _ = try CLITextService.configuration(provider: .codex, executable: echo, codexVersion: "codex-cli 9.0.0", codexCatalog: catalog)
            try check(false, "unknown Codex version must fail closed")
        } catch CLITextError.unsafeConfiguration { try check(true, "unknown Codex version fails closed") }
        for invalid in [Data("{}".utf8), Data("not json".utf8), Data("{\"models\":[{\"slug\":\"other-model\"}]}".utf8)] {
            do { _ = try CLITextService.sanitizedCodexCatalog(invalid); try check(false, "missing target model or malformed catalog must fail") }
            catch CLITextError.unsafeConfiguration { try check(true, "invalid catalog fails closed") }
        }
        try check(CLITextService.permitsUnmanagedCodex(paths: [root.appendingPathComponent("absent").path], managedPreferencePresent: false),
                  "absent system configuration passes the presence-only gate")
        try check(!CLITextService.permitsUnmanagedCodex(paths: [echo.path], managedPreferencePresent: false)
            && !CLITextService.permitsUnmanagedCodex(paths: [], managedPreferencePresent: true), "system files and managed preferences fail closed")
        try check(!CLITextService.permitsUnmanagedCodex(paths: [echo.appendingPathComponent("not-a-directory").path], managedPreferencePresent: false),
                  "configuration inspection errors are not mistaken for absence")
        for plan in ["free", "go", "plus", "pro", "prolite", "business", "enterprise", "education", "unknown"] {
            let reply = "{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\",\"planType\":\"\(plan)\"}}}"
            try check(CLITextService.permitsPersonalCodexAccount(reply) == ["free", "go", "plus", "pro", "prolite"].contains(plan),
                      "Codex plan allowlist: \(plan)")
        }
        try check(!CLITextService.permitsPersonalCodexAccount("{}")
            && !CLITextService.permitsPersonalCodexAccount("{\"id\":2,\"result\":{\"account\":{\"type\":\"apiKey\"}}}"),
                  "missing account data and API-key accounts fail closed")
        for plan in ["pro", "max", "team", "enterprise", "unknown"] {
            let reply = "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"\(plan)\"}"
            try check(CLITextService.permitsPersonalClaudeAccount(reply) == ["pro", "max"].contains(plan),
                      "Claude personal subscription allowlist: \(plan)")
        }
        try check(!CLITextService.permitsPersonalClaudeAccount("{\"loggedIn\":false,\"authMethod\":\"none\",\"subscriptionType\":null}"),
                  "logged-out Claude account fails closed")

        var metadata = CLITextService.codexAccountConfiguration(executable: try fixture("""
        IFS= read -r initialize || exit 9
        case "$initialize" in *'"method":"initialize"'*) ;; *) exit 8 ;; esac
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized || exit 7
        IFS= read -r account || exit 6
        case "$account" in *'"method":"account/read"'*'"refreshToken":false'*) ;; *) exit 5 ;; esac
        printf '%s\n' '{"method":"status","params":{}}' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"pro"}}}'
        trap '' TERM
        while :; do :; done
        """))
        metadata.terminationGrace = 0.05
        let metadataReply = try run(metadata, input: "").0.get()
        try check(CLITextService.permitsPersonalCodexAccount(metadataReply), "account metadata handshakes before requesting and reaps its process after reply")
        metadata.executable = try fixture("printf '%s\n' '{\"id\":1,\"error\":{\"message\":\"synthetic\"}}'\nwhile :; do :; done")
        if case .failure(let error) = try run(metadata, input: "").0 {
            try check((error as? CLITextError) == .invalidOutput, "failed metadata initialization cannot proceed")
        } else { try check(false, "failed metadata initialization must fail") }
        metadata.executable = try fixture("IFS= read -r first\nprintf '%s\n' '{\"id\":1,\"result\":{}}'\nwhile :; do :; done")
        metadata.timeout = 0.1
        if case .failure(let error) = try run(metadata, input: "").0 {
            try check((error as? CLITextError) == .timeout, "missing account reply times out and is reaped")
        } else { try check(false, "missing metadata reply must fail") }
        metadata.timeout = 3
        if case .failure(let error) = try run(metadata, input: "", cancelAfter: 0.05).0 {
            try check((error as? URLError)?.code == .cancelled, "metadata handshake participates in request cancellation")
        } else { try check(false, "metadata cancellation must fail") }
        var fileConfig = codex
        fileConfig.executable = try fixture("""
        /bin/cat >/dev/null
        [ -f models.json ] || exit 9
        found=no
        for arg in "$@"; do
          case "$arg" in model_catalog_json=*) found=yes ;; esac
          last="$arg"
        done
        [ "$found" = yes ] && [ "$last" = - ] || exit 8
        printf 'configured result' >result.txt
        """)
        try check(try run(fileConfig).0.get() == "configured result", "private catalog and its absolute config path reach only the owned child")

        let testCLI = try fixture("""
        case "$*" in *'auth status --json'*) printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}'; exit 0 ;; esac
        payload=$(/bin/cat)
        case "$payload" in *"這是 Input-sa 文字整理連線測試。"*) printf 'synthetic connection accepted' ;; *) exit 7 ;; esac
        """)
        let service = CLITextService(executableResolver: { _ in testCLI }, environmentValidator: { _ in true })
        var serviceResult: Result<String, Error>?
        let serviceRequest = service.checkConnection(provider: .claude) { serviceResult = $0 }
        let serviceDeadline = Date().addingTimeInterval(3)
        while serviceResult == nil, Date() < serviceDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try check(serviceRequest != nil && (try serviceResult?.get()) == "synthetic connection accepted", "connection test is cancellable and uses only its fixed synthetic sentence")

        config = CLIProcessConfiguration(executable: try fixture("trap '' TERM\nwhile :; do :; done"), arguments: [], output: .standardOutput)
        config.terminationGrace = 0.05
        var shutdownResponses = 0
        var shutdownComplete = false
        for _ in 0..<3 {
            CLIProcessRunner.run(configuration: config, input: "synthetic") { result in
                if case .failure(let error) = result, (error as? URLError)?.code == .cancelled { shutdownResponses += 1 }
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        CLIProcessRunner.shutdown { shutdownComplete = Thread.isMainThread }
        let shutdownDeadline = Date().addingTimeInterval(3)
        while (!shutdownComplete || shutdownResponses < 3), Date() < shutdownDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check(shutdownComplete && shutdownResponses == 3, "shutdown drains active and queued requests before returning on main")
        config.executable = echo
        if case .failure(let error) = try run(config).0 { try check((error as? URLError)?.code == .cancelled, "shutdown rejects new requests") }
        else { try check(false, "shutdown rejects new requests") }
        print("\(checks)/\(checks) CLI text service checks passed")
    }
}
