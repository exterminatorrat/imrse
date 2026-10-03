#if os(macOS) && DEBUG
import AppKit
import Foundation
import ImrseCore
import XCTest
@testable import ImrseApp

@MainActor
final class ResponseDetailsMenuTests: XCTestCase {
    func testMenuDefaultsOffAndToggleAddsUnavailableLatestResponseSubmenu() throws {
        let model = makeModel(responses: [])
        let coordinator = AppCoordinator(model: model)
        let menu = coordinator.contextMenu
        let toggle = try XCTUnwrap(menu.items.first { $0.title == "Show Response Details" })

        XCTAssertEqual(toggle.state, .off)
        XCTAssertEqual(toggle.action, #selector(AppCoordinator.toggleResponseDetails(_:)))
        XCTAssertTrue(toggle.target === coordinator)
        XCTAssertNil(menu.items.first { $0.title == "Latest Response" })

        coordinator.toggleResponseDetails(toggle)

        XCTAssertEqual(toggle.state, .on)
        let submenu = try latestResponseSubmenu(in: coordinator.contextMenu)
        XCTAssertTrue(submenu.items.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(
            submenu.items.map(\.title),
            [
                "Detected model: Unavailable",
                "Input tokens: Unavailable",
                "Output tokens: Unavailable",
                "Total tokens: Unavailable",
                "Cost (USD): Unavailable"
            ]
        )
    }

    func testCheckedResponseDetailsMenuRoutesQuitThroughCoordinator() throws {
        let coordinator = AppCoordinator(model: makeModel(responses: []))
        try enableResponseDetails(on: coordinator)

        let menu = coordinator.contextMenu
        let toggle = try XCTUnwrap(menu.items.first { $0.title == "Show Response Details" })
        let quit = try XCTUnwrap(menu.items.first { $0.title == "Quit imrse" })

        XCTAssertEqual(toggle.state, .on)
        XCTAssertNotNil(try latestResponseSubmenu(in: menu))
        XCTAssertEqual(quit.action, #selector(AppCoordinator.quitFromMenuItem(_:)))
        XCTAssertTrue(quit.target === coordinator)
    }

    func testMenuUsesReportedModelAndKeepsMissingFieldsUnavailable() async throws {
        let metadata = ResponseMetadata(
            detectedModel: "fixture-reported-model",
            inputTokens: 10,
            totalTokens: 12,
            costUSD: 0.0000000001
        )
        let model = makeModel(responses: [ResponseFixture(output: "fixture output", metadata: metadata)])
        let coordinator = AppCoordinator(model: model)
        try enableResponseDetails(on: coordinator)

        await runNextResponse(model, configuredModel: "configured-model-not-reported")

        let titles = try latestResponseSubmenu(in: coordinator.contextMenu).items.map(\.title)
        XCTAssertEqual(titles[0], "Detected model: fixture-reported-model")
        XCTAssertEqual(titles[1], "Input tokens: 10")
        XCTAssertEqual(titles[2], "Output tokens: Unavailable")
        XCTAssertEqual(titles[3], "Total tokens: 12")
        XCTAssertTrue(titles[4].hasPrefix("Cost (USD): $0.0000000001"))
        XCTAssertNotEqual(titles[4], "Cost (USD): $0.00")
    }

    func testCompletedResponseWithoutMetadataShowsUnavailableForEveryField() async throws {
        let model = makeModel(responses: [ResponseFixture(output: "fixture output", metadata: nil)])
        let coordinator = AppCoordinator(model: model)
        try enableResponseDetails(on: coordinator)

        await runNextResponse(model)

        XCTAssertEqual(model.state, .succeeded(unchanged: false))
        XCTAssertEqual(
            try latestResponseSubmenu(in: coordinator.contextMenu).items.map(\.title),
            [
                "Detected model: Unavailable",
                "Input tokens: Unavailable",
                "Output tokens: Unavailable",
                "Total tokens: Unavailable",
                "Cost (USD): Unavailable"
            ]
        )
    }

    func testDismissRetainsLatestResponseAndNextInvocationClearsIt() async throws {
        let metadata = ResponseMetadata(detectedModel: "fixture-first-response", inputTokens: 3)
        let model = makeModel(responses: [
            ResponseFixture(output: "first fixture output", metadata: metadata),
            ResponseFixture(output: "", metadata: nil, failure: .server)
        ])
        let coordinator = AppCoordinator(model: model)
        try enableResponseDetails(on: coordinator)

        await runNextResponse(model)
        XCTAssertEqual(model.latestResponseMetadata, metadata)

        model.engine.dismiss()
        XCTAssertNil(model.engine.responseMetadata)
        XCTAssertEqual(model.latestResponseMetadata, metadata)
        XCTAssertEqual(
            try latestResponseSubmenu(in: coordinator.contextMenu).items[0].title,
            "Detected model: fixture-first-response"
        )

        model.engine.invoke()
        XCTAssertNil(model.latestResponseMetadata)
        XCTAssertEqual(model.state, .ready)
        model.engine.submit(instruction: "fixture instruction", provider: fixtureProvider())
        await waitForTerminalState(model.engine)

        XCTAssertEqual(model.state, .failed(.server))
        XCTAssertNil(model.latestResponseMetadata)
        XCTAssertEqual(
            try latestResponseSubmenu(in: coordinator.contextMenu).items.map(\.title),
            [
                "Detected model: Unavailable",
                "Input tokens: Unavailable",
                "Output tokens: Unavailable",
                "Total tokens: Unavailable",
                "Cost (USD): Unavailable"
            ]
        )
    }

    func testProviderResponseRemainsAvailableWhenReplacementFails() async throws {
        let metadata = ResponseMetadata(detectedModel: "fixture-completed-response", outputTokens: 7)
        let selection = ResponseDetailsSelectionAccess(replacementError: .replacementFailed)
        let model = makeModel(
            responses: [ResponseFixture(output: "fixture generated output", metadata: metadata)],
            selection: selection
        )
        let coordinator = AppCoordinator(model: model)
        try enableResponseDetails(on: coordinator)

        await runNextResponse(model)

        XCTAssertEqual(model.state, .failed(.replacementFailed))
        XCTAssertEqual(model.latestResponseMetadata, metadata)
        XCTAssertEqual(
            try latestResponseSubmenu(in: coordinator.contextMenu).items[0].title,
            "Detected model: fixture-completed-response"
        )
    }

    func testUndoAfterDismissKeepsLatestProviderResponse() async throws {
        let metadata = ResponseMetadata(detectedModel: "fixture-response-before-undo", outputTokens: 7)
        let model = makeModel(responses: [ResponseFixture(output: "fixture generated output", metadata: metadata)])
        let coordinator = AppCoordinator(model: model)
        try enableResponseDetails(on: coordinator)

        await runNextResponse(model)
        model.engine.dismiss()
        await model.engine.undo()

        XCTAssertEqual(model.state, .succeeded(unchanged: false))
        XCTAssertEqual(model.latestResponseMetadata, metadata)
        XCTAssertEqual(
            try latestResponseSubmenu(in: coordinator.contextMenu).items[0].title,
            "Detected model: fixture-response-before-undo"
        )
    }

    func testFormatterRejectsInvalidValuesAndKeepsExtremelySmallCostNonzero() {
        let rows = ResponseDetailsFormatter.rows(for: ResponseMetadata(
            detectedModel: "  fixture\nmodel  ",
            inputTokens: -1,
            outputTokens: 0,
            totalTokens: nil,
            costUSD: Double.nan
        ))

        XCTAssertEqual(rows.map(\.menuTitle), [
            "Detected model: fixture model",
            "Input tokens: Unavailable",
            "Output tokens: 0",
            "Total tokens: Unavailable",
            "Cost (USD): Unavailable"
        ])

        let tinyCost = ResponseDetailsFormatter.rows(for: ResponseMetadata(costUSD: 1e-20))[4].value
        XCTAssertNotEqual(tinyCost, "$0.00")
        XCTAssertNotEqual(tinyCost, "Unavailable")
    }

    private func makeModel(
        responses: [ResponseFixture],
        selection: ResponseDetailsSelectionAccess = ResponseDetailsSelectionAccess()
    ) -> AppModel {
        let engine = TransformationEngine(
            selectionAccess: selection,
            textProvider: ResponseDetailsTextProvider(responses: responses)
        )
        return AppModel(testEngine: engine)
    }

    private func runNextResponse(_ model: AppModel, configuredModel: String = "configured-fixture-model") async {
        model.engine.invoke()
        model.engine.submit(instruction: "fixture instruction", provider: fixtureProvider(model: configuredModel))
        await waitForTerminalState(model.engine)
    }

    private func waitForTerminalState(_ engine: TransformationEngine) async {
        for _ in 0..<100 {
            switch engine.state {
            case .succeeded(_), .failed(_):
                return
            default:
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        XCTFail("The fixture response did not reach a terminal state.")
    }

    private func latestResponseSubmenu(in menu: NSMenu, file: StaticString = #filePath, line: UInt = #line) throws -> NSMenu {
        let item = try XCTUnwrap(menu.items.first { $0.title == "Latest Response" }, file: file, line: line)
        return try XCTUnwrap(item.submenu, file: file, line: line)
    }

    private func enableResponseDetails(on coordinator: AppCoordinator) throws {
        let item = try XCTUnwrap(coordinator.contextMenu.items.first { $0.title == "Show Response Details" })
        coordinator.toggleResponseDetails(item)
    }

    private func fixtureProvider(model: String = "configured-fixture-model") -> ProviderConfiguration {
        ProviderConfiguration(
            id: "fixture-provider",
            name: "Fixture Provider",
            kind: .compatible,
            endpoint: URL(string: "https://fixture.invalid")!,
            model: model,
            requiresCredential: false
        )
    }
}

private struct ResponseFixture: Sendable {
    let output: String
    let metadata: ResponseMetadata?
    let failure: ImrseError?

    init(output: String, metadata: ResponseMetadata?, failure: ImrseError? = nil) {
        self.output = output
        self.metadata = metadata
        self.failure = failure
    }
}

private actor ResponseDetailsTextProvider: TextProvider {
    private var responses: [ResponseFixture]

    init(responses: [ResponseFixture]) {
        self.responses = responses
    }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        guard !responses.isEmpty else { throw ImrseError.server }
        let response = responses.removeFirst()
        if let metadata = response.metadata, let reportMetadata = request.reportResponseMetadata {
            await reportMetadata(metadata)
        }
        return AsyncThrowingStream { continuation in
            if let failure = response.failure {
                continuation.finish(throwing: failure)
                return
            }
            continuation.yield(response.output)
            continuation.finish()
        }
    }
}

@MainActor
private final class ResponseDetailsSelectionAccess: SelectionAccess {
    private let target = SelectionSnapshot(
        applicationID: "response-details.fixture",
        processID: 1,
        role: "text field",
        text: "fixture selection",
        range: TextRange(location: 0, length: "fixture selection".utf16.count)
    )
    private let replacementError: ImrseError?

    init(replacementError: ImrseError? = nil) {
        self.replacementError = replacementError
    }

    func capture() throws -> SelectionSnapshot { target }

    func validate(_ target: SelectionSnapshot) throws {}

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        if let replacementError { throw replacementError }
        return ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {}

    func discard(_ target: SelectionSnapshot) {}
}
#endif
