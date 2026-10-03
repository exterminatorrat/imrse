#if os(macOS) && DEBUG
import ImrseServices
import SwiftUI
import XCTest
@testable import ImrseApp

@MainActor
final class CuratedModelChoicesViewTests: XCTestCase {
    func testDefaultPresentationUsesGenericProviderCopy() {
        let view = CuratedModelChoicesView(choices: [], selection: .constant(""))
        let copy = view.presentation.copy(isPreview: false, hasConfiguredModel: false)

        XCTAssertEqual(view.presentation, .provider)
        XCTAssertEqual(copy.sectionTitle, "Recommended models")
        XCTAssertEqual(copy.sectionDetail, "Choose a model recommended for this provider.")
        XCTAssertEqual(copy.emptyStateTitle, "No model recommendations")
        XCTAssertEqual(copy.emptyStateDetail, "This provider has no recommended models.")
        XCTAssertEqual(copy.accessibilityLabel, "Recommended models")
        XCTAssertEqual(copy.configuredModelDetail, "Currently configured for this provider")
    }

    func testChatGPTAccountPresentationKeepsAccountAndUnlistedModelCopy() {
        let view = CuratedModelChoicesView(
            choices: [],
            selection: .constant(""),
            presentation: .chatGPTAccount
        )
        let copy = view.presentation.copy(isPreview: view.isPreview, hasConfiguredModel: view.configuredModel != nil)
        let configuredView = CuratedModelChoicesView(
            choices: [],
            selection: .constant("configured-model"),
            configuredModel: CuratedModelChoice(
                id: "configured-model",
                name: "configured-model",
                detail: "Currently configured · not returned by the latest account model list"
            ),
            presentation: .chatGPTAccount
        )
        let configuredCopy = configuredView.presentation.copy(
            isPreview: configuredView.isPreview,
            hasConfiguredModel: configuredView.configuredModel != nil
        )

        XCTAssertEqual(copy.sectionTitle, "Account model IDs")
        XCTAssertEqual(copy.sectionDetail, "Choose a model ID returned by your ChatGPT account.")
        XCTAssertEqual(copy.emptyStateTitle, "No model IDs returned")
        XCTAssertEqual(copy.emptyStateDetail, "The connected account returned no selectable model IDs.")
        XCTAssertEqual(copy.accessibilityLabel, "Account model IDs")
        XCTAssertEqual(configuredCopy.sectionTitle, "Configured and account model IDs")
        XCTAssertEqual(configuredCopy.emptyStateDetail, "Your saved model is shown above; the empty account list doesn't determine whether it works.")
        XCTAssertEqual(configuredCopy.configuredModelDetail, "Currently configured · not returned by the latest account model list")
    }

    func testChatGPTPreviewStillUsesExampleCopy() {
        let view = CuratedModelChoicesView(
            choices: [],
            selection: .constant(""),
            isPreview: true,
            presentation: .chatGPTAccount
        )
        let copy = view.presentation.copy(isPreview: view.isPreview, hasConfiguredModel: view.configuredModel != nil)

        XCTAssertEqual(copy.sectionTitle, "Example models")
        XCTAssertEqual(copy.sectionDetail, "Preview examples aren't checked against a connected account.")
        XCTAssertEqual(copy.emptyStateTitle, "No example models")
        XCTAssertEqual(copy.configuredModelDetail, "Currently configured")
        XCTAssertEqual(copy.accessibilityLabel, "Example models, preview only")
    }
}
#endif
