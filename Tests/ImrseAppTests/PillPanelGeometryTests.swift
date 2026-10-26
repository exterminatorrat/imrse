#if os(macOS)
import AppKit
import ImrsePillUI
import XCTest
@testable import ImrseApp

@MainActor
final class PillPanelGeometryTests: XCTestCase {
    private let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)

    func testMissingGeometryUsesCapturedScreenFallback() {
        let frame = PillPanelController.frame(width: PillTokens.width, visibleFrame: screen)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.minY, screen.minY + PillTokens.bottomInset)
        XCTAssertTrue(screen.contains(frame))
    }

    func testSelectionPlacesSurfaceBelowWithEightPointGap() {
        let selection = CGRect(x: -1000, y: 600, width: 200, height: 24)
        let frame = PillPanelController.frame(width: PillTokens.width, visibleFrame: screen, selectionBounds: selection)
        XCTAssertEqual(frame.midX, selection.midX)
        XCTAssertEqual(frame.maxY - PillTokens.shadowPadding, selection.minY - 8)
        XCTAssertTrue(screen.contains(frame))
    }

    func testSelectionNearBottomPlacesSurfaceAbove() {
        let selection = CGRect(x: -1000, y: 125, width: 200, height: 24)
        let frame = PillPanelController.frame(width: PillTokens.width, visibleFrame: screen, selectionBounds: selection)
        XCTAssertEqual(frame.minY + PillTokens.shadowPadding, selection.maxY + 8)
        XCTAssertTrue(screen.contains(frame))
    }

    func testEdgeSelectionClampsWholePanelToUsableScreen() {
        let selection = CGRect(x: -20, y: 970, width: 18, height: 20)
        let frame = PillPanelController.frame(width: PillTokens.width, visibleFrame: screen, selectionBounds: selection)
        XCTAssertTrue(screen.insetBy(dx: PillTokens.edgeInset, dy: PillTokens.edgeInset).contains(frame))
    }

    func testInvalidAndOffScreenGeometryUsesFallback() {
        let fallback = PillPanelController.frame(width: PillTokens.width, visibleFrame: screen)
        let invalidBounds = [
            CGRect.zero,
            CGRect(x: 5000, y: 5000, width: 100, height: 20),
            CGRect(x: CGFloat.nan, y: 600, width: 100, height: 20),
            CGRect(x: -1000, y: 600, width: CGFloat.infinity, height: 20)
        ]
        for bounds in invalidBounds {
            XCTAssertEqual(PillPanelController.frame(width: PillTokens.width, visibleFrame: screen, selectionBounds: bounds), fallback)
        }
    }

    func testPhaseChangesKeepTrailingControlsAndBottomEdgeAnchored() {
        let selection = CGRect(x: -1000, y: 600, width: 200, height: 24)
        let input = PillPanelController.frame(width: PillTokens.width, visibleFrame: screen, selectionBounds: selection)
        for width in [CGFloat(240), 220, 180, 300] {
            let frame = PillPanelController.frame(width: width, visibleFrame: screen, anchorFrame: input)
            XCTAssertEqual(frame.maxX, input.maxX)
            XCTAssertEqual(frame.minY, input.minY)
            XCTAssertTrue(screen.contains(frame))
        }
    }

    func testPreviewGrowsAboveTheAnchoredActionRow() {
        let input = PillPanelController.frame(width: PillTokens.width, visibleFrame: screen)
        let preview = PillPanelController.frame(width: PillTokens.width, height: PillTokens.height(for: .proposal(UUID())), visibleFrame: screen, anchorFrame: input)
        XCTAssertEqual(preview.maxX, input.maxX)
        XCTAssertEqual(preview.minY, input.minY)
        XCTAssertGreaterThan(preview.height, input.height)
        XCTAssertTrue(screen.contains(preview))
    }

    func testPreviewNearTopEdgeClampsRatherThanLeavingScreen() {
        let selection = CGRect(x: -1000, y: 950, width: 200, height: 24)
        let input = PillPanelController.frame(width: PillTokens.width, visibleFrame: screen, selectionBounds: selection)
        let preview = PillPanelController.frame(width: PillTokens.width, height: PillTokens.height(for: .proposal(UUID())), visibleFrame: screen, anchorFrame: input)
        XCTAssertTrue(screen.insetBy(dx: PillTokens.edgeInset, dy: PillTokens.edgeInset).contains(preview))
    }

    func testNarrowScreenCapsBothHostedContentAndPanel() {
        let narrow = CGRect(x: 0, y: 0, width: 320, height: 600)
        let contentWidth = PillPanelController.contentWidth(PillTokens.width, visibleFrame: narrow)
        let frame = PillPanelController.frame(width: PillTokens.width, visibleFrame: narrow)
        XCTAssertEqual(frame.width, contentWidth + 2 * PillTokens.shadowPadding)
        XCTAssertTrue(narrow.insetBy(dx: PillTokens.edgeInset, dy: PillTokens.edgeInset).contains(frame))
    }
}
#endif
