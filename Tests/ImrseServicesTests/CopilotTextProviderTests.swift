#if os(macOS)
import Foundation
import ImrseCore
import XCTest
@testable import ImrseServices

final class CopilotTextProviderTests: XCTestCase {
    func testOfficialRuntimeAuthenticatesAfterVerifiedPrivacyPreflight() async throws {
        let fixture = try RuntimeFixture(scenario: .complete)
        let provider = makeProvider(
            runtime: CopilotProcessRuntime(executableURL: fixture.executableURL),
            expiresAt: Date().addingTimeInterval(7_200)
        )

        let output = try await collect(provider)
        XCTAssertEqual(output, "Fixture result.")

        let trace = try fixture.trace()
        XCTAssertEqual(trace["methods"] as? [String], [
            "connect", "sessionFs.setProvider", "session.create", "session.options.update",
            "session.gitHubAuth.login", "session.send", "session.detach", "session.delete", "runtime.shutdown"
        ])
        XCTAssertEqual(trace["static_auth_verified"] as? Bool, true)
        XCTAssertEqual(trace["session_fs_configured"] as? Bool, true)
        XCTAssertEqual(trace["session_fs_round_trip"] as? Bool, true)
        XCTAssertEqual(trace["safe_create"] as? Bool, true)
        XCTAssertEqual(trace["safe_options"] as? Bool, true)
        XCTAssertEqual(trace["prompt_is_expected"] as? Bool, true)
        XCTAssertEqual(trace["ambient_auth_present"] as? Bool, false)
        XCTAssertEqual(trace["isolated_home"] as? Bool, true)
        XCTAssertEqual(trace["keytar_disabled"] as? Bool, true)
        XCTAssertEqual(trace["sensitive_data_on_disk"] as? Bool, false)
        XCTAssertEqual(trace["args"] as? [String], CopilotProcessRuntime.launchArguments)
        XCTAssertEqual(trace["token_in_args"] as? Bool, false)
    }

    func testNonExpiringAccountTokenUsesTransientSessionAuthentication() async throws {
        let fixture = try RuntimeFixture(scenario: .complete)
        let provider = makeProvider(
            runtime: CopilotProcessRuntime(executableURL: fixture.executableURL),
            expiresAt: nil
        )

        let output = try await collect(provider)
        XCTAssertEqual(output, "Fixture result.")
        let trace = try fixture.trace()
        XCTAssertEqual(trace["static_auth_verified"] as? Bool, true)
        XCTAssertEqual(trace["session_fs_configured"] as? Bool, true)
        XCTAssertEqual(trace["session_fs_round_trip"] as? Bool, true)
        XCTAssertEqual(trace["sensitive_data_on_disk"] as? Bool, false)
        XCTAssertEqual(trace["methods"] as? [String], [
            "connect", "sessionFs.setProvider", "session.create", "session.options.update",
            "session.gitHubAuth.login", "session.send", "session.detach", "session.delete", "runtime.shutdown"
        ])
        XCTAssertEqual(trace["safe_create"] as? Bool, true)
        XCTAssertEqual(trace["ambient_auth_present"] as? Bool, false)
        XCTAssertEqual(trace["token_in_args"] as? Bool, false)
        XCTAssertFalse(try fixture.traceContains("selected"))
    }

    func testUnavailableRuntimeMapsToActionableImrseError() async {
        let provider = makeProvider(
            runtime: CopilotProcessRuntime(executableURL: URL(fileURLWithPath: "/missing/copilot-runtime")),
            expiresAt: Date().addingTimeInterval(7_200)
        )
        await assertProviderError(.copilotRuntimeUnavailable) { _ = try await collect(provider) }
    }

    func testPeerExitDuringHandshakeFailsWithoutTerminatingTheHostProcess() async throws {
        let fixture = try RuntimeFixture(scenario: .peerExit)
        let provider = makeProvider(
            runtime: CopilotProcessRuntime(executableURL: fixture.executableURL),
            expiresAt: Date().addingTimeInterval(7_200)
        )
        do {
            _ = try await collect(provider)
            XCTFail("A closed runtime cannot complete a transformation")
        } catch let error as ImrseError {
            XCTAssertTrue([ImrseError.server, .interruptedStream].contains(error))
        }
        let trace = try fixture.trace()
        XCTAssertEqual(trace["methods"] as? [String], ["connect"])
        XCTAssertEqual(trace["static_auth_verified"] as? Bool, false)
        XCTAssertEqual(trace["prompt_is_expected"] as? Bool, false)
    }

    func testUnsupportedProtocolAndRejectedSafetyOptionsFailBeforeSendingText() async throws {
        let protocolFixture = try RuntimeFixture(scenario: .protocolMismatch)
        let protocolProvider = makeProvider(
            runtime: CopilotProcessRuntime(executableURL: protocolFixture.executableURL),
            expiresAt: Date().addingTimeInterval(7_200)
        )
        let routedProtocolProvider = RoutedTextProvider(primary: protocolProvider)
        await assertProviderError(.copilotRuntimeIncompatible) { _ = try await collect(routedProtocolProvider) }
        let protocolTrace = try await protocolFixture.waitForTrace { $0["terminated"] as? Bool == true }
        XCTAssertEqual(protocolTrace["methods"] as? [String], ["connect"])
        XCTAssertEqual(protocolTrace["static_auth_verified"] as? Bool, false)
        XCTAssertEqual(protocolTrace["prompt_is_expected"] as? Bool, false)

        let optionsFixture = try RuntimeFixture(scenario: .rejectOptions)
        let optionsProvider = makeProvider(
            runtime: CopilotProcessRuntime(executableURL: optionsFixture.executableURL),
            expiresAt: Date().addingTimeInterval(7_200)
        )
        await assertProviderError(.copilotRuntimeIncompatible) { _ = try await collect(optionsProvider) }
        let optionsTrace = try await optionsFixture.waitForTrace { $0["terminated"] as? Bool == true }
        XCTAssertEqual(optionsTrace["methods"] as? [String], [
            "connect", "sessionFs.setProvider", "session.create", "session.options.update"
        ])
        XCTAssertEqual(optionsTrace["prompt_is_expected"] as? Bool, false)
        XCTAssertEqual(optionsTrace["static_auth_verified"] as? Bool, false)
    }

    func testProtocolThreeRuntimeBelowVerifiedPrivacyBaselineGetsNoCredentialOrPrompt() async throws {
        let fixture = try RuntimeFixture(scenario: .unsupportedBaseline)
        let provider = makeProvider(
            runtime: CopilotProcessRuntime(executableURL: fixture.executableURL),
            expiresAt: Date().addingTimeInterval(7_200)
        )

        await assertProviderError(.copilotRuntimeIncompatible) { _ = try await collect(provider) }
        let trace = try await fixture.waitForTrace { $0["terminated"] as? Bool == true }
        XCTAssertEqual(trace["methods"] as? [String], ["connect"])
        XCTAssertEqual(trace["static_auth_verified"] as? Bool, false)
        XCTAssertEqual(trace["prompt_is_expected"] as? Bool, false)
    }

    func testPermissionAndExternalToolRequestsAreDenied() async throws {
        for (scenario, expectedError, expectedDecision) in [
            (RuntimeFixture.Scenario.permission, ImrseError.copilotPermissionDenied, "reject"),
            (RuntimeFixture.Scenario.tool, ImrseError.copilotToolDenied, "tool-error")
        ] {
            let fixture = try RuntimeFixture(scenario: scenario)
            let provider = makeProvider(
                runtime: CopilotProcessRuntime(executableURL: fixture.executableURL),
                expiresAt: Date().addingTimeInterval(7_200)
            )
            await assertProviderError(expectedError) { _ = try await collect(provider) }
            let trace = try await fixture.waitForTrace { $0["terminated"] as? Bool == true }
            XCTAssertEqual(trace["denial_response"] as? String, expectedDecision)
            XCTAssertTrue((trace["methods"] as? [String] ?? []).contains("session.send"))
        }
    }

    func testOversizedRuntimeOutputIsRejected() async throws {
        let fixture = try RuntimeFixture(scenario: .oversized)
        let provider = makeProvider(
            runtime: CopilotProcessRuntime(executableURL: fixture.executableURL, maximumOutputBytes: 8),
            expiresAt: Date().addingTimeInterval(7_200),
            maximumOutputBytes: 8
        )

        await assertProviderError(.outputTooLarge) { _ = try await collect(provider) }
        let trace = try await fixture.waitForTrace { $0["terminated"] as? Bool == true }
        XCTAssertTrue((trace["methods"] as? [String] ?? []).contains("session.send"))
    }

    func testPartialOutputWithLengthFilterOrMissingUsageMetadataIsRejected() async throws {
        for scenario in [RuntimeFixture.Scenario.length, .contentFilter, .missingUsage] {
            let fixture = try RuntimeFixture(scenario: scenario)
            let provider = makeProvider(
                runtime: CopilotProcessRuntime(executableURL: fixture.executableURL),
                expiresAt: Date().addingTimeInterval(7_200)
            )

            await assertProviderError(.interruptedStream) { _ = try await collect(provider) }
            let trace = try await fixture.waitForTrace { $0["terminated"] as? Bool == true }
            XCTAssertTrue((trace["methods"] as? [String] ?? []).contains("session.send"))
        }
    }

    func testUsageMetadataMustContainFinishAndFilterFields() async throws {
        for scenario in [RuntimeFixture.Scenario.missingFinishReason, .missingContentFilter] {
            let fixture = try RuntimeFixture(scenario: scenario)
            let provider = makeProvider(
                runtime: CopilotProcessRuntime(executableURL: fixture.executableURL),
                expiresAt: Date().addingTimeInterval(7_200)
            )

            await assertProviderError(.malformedResponse) { _ = try await collect(provider) }
            let trace = try await fixture.waitForTrace { $0["terminated"] as? Bool == true }
            XCTAssertTrue((trace["methods"] as? [String] ?? []).contains("session.send"))
        }
    }

    func testCancellationTerminatesRuntimeProcess() async throws {
        let fixture = try RuntimeFixture(scenario: .hold)
        let provider = makeProvider(
            runtime: CopilotProcessRuntime(executableURL: fixture.executableURL),
            expiresAt: Date().addingTimeInterval(7_200)
        )
        let stream = try await provider.stream(request())
        let consumer = Task {
            do {
                for try await _ in stream {}
                return Task.isCancelled
            } catch let error as ImrseError {
                return error == .cancelled
            } catch {
                return false
            }
        }

        _ = try await fixture.waitForTrace { ($0["methods"] as? [String] ?? []).contains("session.send") }
        consumer.cancel()
        let wasCancelled = await consumer.value
        XCTAssertTrue(wasCancelled)
        let trace = try await fixture.waitForTrace { $0["terminated"] as? Bool == true }
        XCTAssertEqual(trace["terminated"] as? Bool, true)
    }

    func testExpiringTokenMustExceedStaticAuthenticationWindow() async throws {
        let runtime = CountingRuntime()
        let shortLifetime = makeProvider(runtime: runtime, expiresAt: Date().addingTimeInterval(60))
        await assertProviderError(.copilotAuthentication) { _ = try await collect(shortLifetime) }
        let invocationCount = await runtime.count()
        XCTAssertEqual(invocationCount, 0)
    }

    func testLocalOnlyRequestsNeverLaunchTheRuntime() async throws {
        let runtime = CountingRuntime()
        let provider = makeProvider(runtime: runtime, expiresAt: Date().addingTimeInterval(7_200))
        do {
            _ = try await provider.stream(TransformationRequest(
                text: "selected",
                instruction: "rewrite",
                provider: copilotConfiguration(),
                localOnly: true
            ))
            XCTFail("Expected local-only rejection")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .providerUnavailable)
        }
        let invocationCount = await runtime.count()
        XCTAssertEqual(invocationCount, 0)
    }

    private func makeProvider(
        runtime: any CopilotRuntime,
        expiresAt: Date?,
        maximumOutputBytes: Int = 1_048_576
    ) -> CopilotTextProvider {
        CopilotTextProvider(
            accountClient: OfficialAccountClient(
                credentials: MemoryCredentials(expiresAt: expiresAt),
                transport: NeverTransport()
            ),
            runtime: runtime,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private func request() -> TransformationRequest {
        TransformationRequest(text: "selected", instruction: "rewrite", provider: copilotConfiguration())
    }

    private func collect(_ provider: any TextProvider) async throws -> String {
        let stream = try await provider.stream(request())
        var output = ""
        for try await piece in stream { output += piece }
        return output
    }

    private func assertProviderError(
        _ expected: ImrseError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as ImrseError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

private func copilotConfiguration() -> ProviderConfiguration {
    ProviderConfiguration(
        id: "copilot-test",
        name: "GitHub Copilot",
        kind: .githubCopilot,
        endpoint: CopilotTextProvider.endpoint,
        model: "fixture-model",
        oauthClientID: "synthetic-public-client"
    )
}

private actor MemoryCredentials: CredentialStore {
    private let record: String

    init(expiresAt: Date?) {
        var fields: [String: Any] = [
            "providerID": "copilot-test",
            "kind": "githubCopilot",
            "clientID": "synthetic-public-client",
            "accessToken": "synthetic-github-token",
            "accountLabel": "synthetic-user",
            "scopes": ["read:user"]
        ]
        if let expiresAt { fields["expiresAt"] = expiresAt.timeIntervalSinceReferenceDate }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        record = String(decoding: data, as: UTF8.self)
    }

    func credential(for providerID: String) async throws -> String? {
        providerID == "oauth:githubCopilot:copilot-test" ? record : nil
    }

    func setCredential(_ value: String?, for providerID: String) async throws {}
}

private struct NeverTransport: StreamingHTTPTransport {
    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        throw CopilotRuntimeError.runtimeFailed
    }
}

private actor CountingRuntime: CopilotRuntime {
    private var invocations = 0

    func complete(
        _ request: CopilotRuntimeRequest,
        authentication: CopilotRuntimeAuthentication
    ) async throws -> String {
        invocations += 1
        return "Fixture result."
    }

    func count() -> Int { invocations }
}

private final class RuntimeFixture: @unchecked Sendable {
    enum Scenario: String {
        case complete
        case peerExit
        case protocolMismatch
        case unsupportedBaseline
        case rejectOptions
        case permission
        case tool
        case oversized
        case length
        case contentFilter
        case missingUsage
        case missingFinishReason
        case missingContentFilter
        case hold
    }

    let executableURL: URL
    private let directory: URL
    private let markerURL: URL

    init(scenario: Scenario) throws {
        guard let python = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Python 3 is unavailable for the local protocol fixture.")
        }

        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imrse-copilot-fixture-\(UUID().uuidString)", isDirectory: true)
        executableURL = directory.appendingPathComponent("copilot-runtime-fixture", isDirectory: false)
        markerURL = directory.appendingPathComponent("trace.json", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = Self.script(scenario: scenario, python: python, marker: markerURL.path)
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func trace() throws -> [String: Any] {
        let data = try Data(contentsOf: markerURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func traceContains(_ text: String) throws -> Bool {
        String(decoding: try Data(contentsOf: markerURL), as: UTF8.self).contains(text)
    }

    func waitForTrace(
        _ predicate: @Sendable ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        for _ in 0..<300 {
            if let trace = try? trace(), predicate(trace) { return trace }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CopilotRuntimeError.timeout
    }

    private static func script(scenario: Scenario, python: String, marker: String) -> String {
        """
        #!\(python)
        import json
        import os
        import signal
        import sys
        import uuid

        SCENARIO = \(quoted(scenario.rawValue))
        MARKER = \(quoted(marker))
        EXPECTED_PROMPT = "rewrite\\n\\nSelected text:\\nselected"
        SESSION_ID = None
        state = {
            "methods": [], "denial_response": None, "terminated": False,
            "prompt_is_expected": False, "static_auth_verified": False
        }

        def snapshot(**values):
            state.update(values)
            with open(MARKER + ".tmp", "w", encoding="utf-8") as handle:
                json.dump(state, handle, sort_keys=True)
            os.replace(MARKER + ".tmp", MARKER)

        def terminate(_signal, _frame):
            snapshot(terminated=True)
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, terminate)

        def read_message():
            header = bytearray()
            while not header.endswith(b"\\r\\n\\r\\n"):
                part = sys.stdin.buffer.read(1)
                if not part:
                    return None
                header.extend(part)
                if len(header) > 8192:
                    return None
            lengths = [line.split(b":", 1)[1].strip() for line in header[:-4].split(b"\\r\\n")
                       if line.lower().startswith(b"content-length:")]
            if len(lengths) != 1:
                return None
            length = int(lengths[0])
            if length < 1 or length > 5_000_000:
                return None
            payload = sys.stdin.buffer.read(length)
            if len(payload) != length:
                return None
            return json.loads(payload)

        def send(message):
            payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
            sys.stdout.buffer.write(b"Content-Length: " + str(len(payload)).encode("ascii") + b"\\r\\n\\r\\n" + payload)
            sys.stdout.buffer.flush()

        def reply(message, result):
            send({"jsonrpc": "2.0", "id": message["id"], "result": result})

        def session_fs_round_trip(session_id):
            send({"jsonrpc": "2.0", "id": "fixture-write", "method": "sessionFs.writeFile", "params": {
                "sessionId": session_id, "path": "/nested/session-state/events.jsonl", "content": "selected"
            }})
            write_response = read_message()
            if not write_response or write_response.get("result") is not None:
                return False
            send({"jsonrpc": "2.0", "id": "fixture-read", "method": "sessionFs.readFile", "params": {
                "sessionId": session_id, "path": "/nested/session-state/events.jsonl"
            }})
            read_response = read_message()
            content = read_response.get("result", {}).get("content") if read_response else None
            return content == "selected"

        def sensitive_data_on_disk():
            home = os.environ["COPILOT_HOME"]
            sensitive = (b"selected", b"synthetic-github-token")
            for root, _directories, files in os.walk(home):
                for name in files:
                    path = os.path.join(root, name)
                    try:
                        with open(path, "rb") as handle:
                            tail = b""
                            while True:
                                chunk = handle.read(65_536)
                                if not chunk:
                                    break
                                contents = tail + chunk
                                if any(value in contents for value in sensitive):
                                    return True
                                tail = contents[-21:]
                    except OSError:
                        continue
            return False

        def safe_create(parameters):
            allowed = set('''
                sessionId model tools availableTools excludedTools toolFilterPrecedence systemMessage
                requestPermission requestUserInput requestElicitation requestCanvasRenderer requestExtensions
                requestExitPlanMode requestAutoModeSwitch hooks mcpServers mcpOAuthTokenStorage customAgents
                customAgentsLocalOnly skillDirectories pluginDirectories instructionDirectories
                disabledSkills disabledMcpServers enableConfigDiscovery enableSkills enableFileHooks
                enableHostGitOperations enableSessionStore memory skipEmbeddingRetrieval
                embeddingCacheStorage infiniteSessions enableSessionTelemetry isExperimentalMode
                enableCitations enableFileChangeTracking skipCustomInstructions
                enableOnDemandInstructionDiscovery remoteSession enableManagedSettings workingDirectory
                additionalDirectories streaming includeSubAgentStreamingEvents
            '''.split())
            return set(parameters).issubset(allowed) \\
                and parameters.get("model") == "fixture-model" \\
                and parameters.get("availableTools") == [] \\
                and parameters.get("excludedTools") == [] \\
                and parameters.get("toolFilterPrecedence") == "excluded" \\
                and parameters.get("tools") == [] \\
                and parameters.get("mcpServers") == {} \\
                and parameters.get("mcpOAuthTokenStorage") == "in-memory" \\
                and parameters.get("customAgents") == [] \\
                and parameters.get("customAgentsLocalOnly") is True \\
                and parameters.get("memory", {}).get("enabled") is False \\
                and parameters.get("skipEmbeddingRetrieval") is True \\
                and parameters.get("embeddingCacheStorage") == "in-memory" \\
                and parameters.get("infiniteSessions", {}).get("enabled") is False \\
                and parameters.get("skillDirectories") == [] \\
                and parameters.get("pluginDirectories") == [] \\
                and parameters.get("instructionDirectories") == [] \\
                and parameters.get("disabledSkills") == [] \\
                and parameters.get("disabledMcpServers") == [] \\
                and parameters.get("enableConfigDiscovery") is False \\
                and parameters.get("enableSkills") is False \\
                and parameters.get("enableFileHooks") is False \\
                and parameters.get("enableHostGitOperations") is False \\
                and parameters.get("enableSessionStore") is False \\
                and parameters.get("requestPermission") is False \\
                and parameters.get("requestUserInput") is False \\
                and parameters.get("requestElicitation") is False \\
                and parameters.get("requestCanvasRenderer") is False \\
                and parameters.get("requestExtensions") is False \\
                and parameters.get("requestExitPlanMode") is False \\
                and parameters.get("requestAutoModeSwitch") is False \\
                and parameters.get("enableSessionTelemetry") is False \\
                and parameters.get("isExperimentalMode") is False \\
                and parameters.get("hooks") is False \\
                and parameters.get("enableCitations") is False \\
                and parameters.get("enableFileChangeTracking") is False \\
                and parameters.get("skipCustomInstructions") is True \\
                and parameters.get("enableOnDemandInstructionDiscovery") is False \\
                and parameters.get("enableManagedSettings") is False \\
                and parameters.get("remoteSession") == "off" \\
                and parameters.get("workingDirectory") == os.environ.get("COPILOT_HOME") \\
                and parameters.get("additionalDirectories") == [] \\
                and parameters.get("streaming") is True \\
                and parameters.get("includeSubAgentStreamingEvents") is False \\
                and parameters.get("systemMessage", {}).get("sections", {}).get("environment_context", {}).get("action") == "remove"

        def emit_event(event_type, data, ephemeral=None):
            event = {
                "id": str(uuid.uuid4()),
                "parentId": None,
                "timestamp": "2026-10-04T00:00:00.000Z",
                "type": event_type,
                "data": data
            }
            if ephemeral is not None:
                event["ephemeral"] = ephemeral
            send({"jsonrpc": "2.0", "method": "session.event", "params": {"sessionId": SESSION_ID, "event": event}})

        def respond_to_denial(method):
            pending = read_message()
            params = pending.get("params", {}) if pending else {}
            if method == "session.permissions.handlePendingPermissionRequest":
                decision = params.get("result", {}).get("kind")
                state["denial_response"] = decision
                valid = decision == "reject" and "sessionId" not in params
            else:
                valid = method == "session.tools.handlePendingToolCall" \\
                    and params.get("error") == "Tools are disabled." \\
                    and "sessionId" not in params
                state["denial_response"] = "tool-error" if valid else "invalid"
            snapshot()
            if pending:
                reply(pending, {"success": True})

        try:
            while True:
                message = read_message()
                if message is None:
                    break
                method = message.get("method")
                parameters = message.get("params", {})
                state["methods"].append(method)
                snapshot()

                if method == "connect":
                    version = 2 if SCENARIO == "protocolMismatch" else 3
                    runtime_version = \(quoted(CopilotProcessRuntime.minimumVerifiedRuntimeVersion))
                    if SCENARIO == "unsupportedBaseline":
                        runtime_version = "1.0.82"
                    reply(message, {"ok": True, "protocolVersion": version, "version": runtime_version})
                    if SCENARIO == "peerExit":
                        os._exit(0)
                elif method == "sessionFs.setProvider":
                    capabilities = parameters.get("capabilities", {})
                    configured = parameters.get("sessionStatePath") == "/session-state" \\
                        and parameters.get("conventions") == "posix" \\
                        and capabilities.get("sqlite") is False \\
                        and parameters.get("initialCwd") == os.environ.get("COPILOT_HOME")
                    snapshot(session_fs_configured=configured)
                    reply(message, {"success": True})
                elif method == "session.create":
                    SESSION_ID = parameters["sessionId"]
                    snapshot(
                        safe_create=safe_create(parameters),
                        isolated_home=os.environ.get("HOME") == os.environ.get("COPILOT_HOME"),
                        keytar_disabled=os.environ.get("COPILOT_DISABLE_KEYTAR") == "1",
                        ambient_auth_present=any(key in os.environ for key in (
                            "GITHUB_TOKEN", "GH_TOKEN", "COPILOT_SDK_AUTH_TOKEN", "COPILOT_TOKEN"
                        )),
                        args=sys.argv[1:],
                        token_in_args=any("synthetic-github-token" in item for item in sys.argv)
                    )
                    reply(message, {"sessionId": SESSION_ID})
                elif method == "session.gitHubAuth.login":
                    verified = parameters.get("sessionId") == SESSION_ID \\
                        and parameters.get("host") == "https://github.com" \\
                        and parameters.get("login") == "synthetic-user" \\
                        and parameters.get("token") == "synthetic-github-token" \\
                        and parameters.get("persist") is False
                    snapshot(static_auth_verified=verified)
                    reply(message, {
                        "type": "token", "host": "https://github.com", "token": "synthetic-github-token"
                    })
                elif method == "session.options.update":
                    safe_options = parameters.get("sessionId") == SESSION_ID \\
                        and parameters.get("skipCustomInstructions") is True \\
                        and parameters.get("customAgentsLocalOnly") is True \\
                        and parameters.get("coauthorEnabled") is False \\
                        and parameters.get("manageScheduleEnabled") is False \\
                        and parameters.get("installedPlugins") == [] \\
                        and parameters.get("includedBuiltinSkills") == []
                    snapshot(safe_options=safe_options)
                    snapshot(session_fs_round_trip=session_fs_round_trip(SESSION_ID))
                    reply(message, {"success": SCENARIO != "rejectOptions"})
                elif method == "session.send":
                    snapshot(
                        sensitive_data_on_disk=sensitive_data_on_disk()
                    )
                    snapshot(prompt_is_expected=parameters.get("prompt") == EXPECTED_PROMPT)
                    reply(message, {"messageId": "fixture-user-message"})
                    if SCENARIO == "permission":
                        emit_event("permission.requested", {
                            "requestId": "fixture-permission",
                            "permissionRequest": {
                                "kind": "shell", "fullCommandText": "echo denied", "commands": [],
                                "possiblePaths": [], "possibleUrls": [], "canOfferSessionApproval": False,
                                "hasWriteFileRedirection": False, "intention": "fixture"
                            }
                        })
                        respond_to_denial("session.permissions.handlePendingPermissionRequest")
                    elif SCENARIO == "tool":
                        emit_event("external_tool.requested", {
                            "requestId": "fixture-tool", "sessionId": SESSION_ID,
                            "toolCallId": "fixture-call", "toolName": "fixture-tool"
                        })
                        respond_to_denial("session.tools.handlePendingToolCall")
                    elif SCENARIO == "oversized":
                        emit_event("assistant.message_delta", {"messageId": "fixture-answer", "deltaContent": "x" * 64}, True)
                    elif SCENARIO == "hold":
                        snapshot(sent=True)
                        while read_message() is not None:
                            pass
                    else:
                        content = "Partial fixture result." if SCENARIO in (
                            "length", "contentFilter", "missingUsage", "missingFinishReason", "missingContentFilter"
                        ) else "Fixture result."
                        emit_event("assistant.message_delta", {"messageId": "fixture-answer", "deltaContent": content}, True)
                        emit_event("assistant.message", {
                            "apiCallId": "fixture-api-call", "messageId": "fixture-answer",
                            "content": content, "chunkIndex": 0,
                            "phase": "final_answer"
                        })
                        if SCENARIO != "missingUsage":
                            finish_reason = "stop"
                            if SCENARIO == "length":
                                finish_reason = "length"
                            elif SCENARIO == "contentFilter":
                                finish_reason = "content_filter"
                            usage = {
                                "apiCallId": "fixture-api-call",
                                "finishReason": finish_reason,
                                "contentFilterTriggered": SCENARIO == "contentFilter"
                            }
                            if SCENARIO == "missingFinishReason":
                                del usage["finishReason"]
                            elif SCENARIO == "missingContentFilter":
                                del usage["contentFilterTriggered"]
                            emit_event("assistant.usage", usage)
                        emit_event("session.idle", {"aborted": False, "mode": "interactive"}, True)
                elif method == "session.detach":
                    reply(message, {"success": True})
                elif method == "session.delete":
                    reply(message, {"success": True})
                elif method == "runtime.shutdown":
                    reply(message, {"success": True})
                    break
                else:
                    send({"jsonrpc": "2.0", "id": message.get("id"), "error": {"code": -32601, "message": "Unsupported fixture RPC."}})
        finally:
            snapshot()
        """
    }

    private static func quoted(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast()).replacingOccurrences(of: "\\/", with: "/")
    }
}

#endif
