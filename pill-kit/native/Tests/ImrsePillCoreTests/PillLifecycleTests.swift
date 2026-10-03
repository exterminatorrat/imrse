import XCTest
@testable import ImrsePillCore
final class PillLifecycleTests: XCTestCase {
 func testHiddenOnConstruction() { XCTAssertEqual(PillLifecycle().phase,.hidden) }
 func testInvokeOpens() { var s=PillLifecycle();s.send(.invoke);XCTAssertEqual(s.phase,.input) }
 func testHiddenCannotSubmit() { var s=PillLifecycle();s.send(.submit(UUID()));XCTAssertEqual(s.phase,.hidden) }
 func testRequestLifecycle() { var s=PillLifecycle();let id=UUID();s.send(.invoke);s.send(.submit(id));XCTAssertEqual(s.phase,.processing(id));s.send(.generated(id));XCTAssertEqual(s.phase,.applying(id));s.send(.applied(id));XCTAssertEqual(s.phase,.success(id)) }
 func testNoFakeSuccessFromGeneration() { var s=PillLifecycle();let id=UUID();s.send(.invoke);s.send(.submit(id));s.send(.applied(id));XCTAssertEqual(s.phase,.processing(id)) }
 func testStaleResultIgnored() { var s=PillLifecycle();let id=UUID();s.send(.invoke);s.send(.submit(id));s.send(.generated(UUID()));XCTAssertEqual(s.phase,.processing(id)) }
 func testDuplicateSubmitIgnored() { var s=PillLifecycle();let id=UUID();s.send(.invoke);s.send(.submit(id));s.send(.submit(UUID()));XCTAssertEqual(s.phase,.processing(id)) }
 func testCancelThenLateCallback() { var s=PillLifecycle();let id=UUID();s.send(.invoke);s.send(.submit(id));s.send(.dismiss);s.send(.generated(id));XCTAssertEqual(s.phase,.hidden) }
 func testFailureRemainsUntilDismissed() { var s=PillLifecycle();let id=UUID();s.send(.invoke);s.send(.submit(id));s.send(.failed(id,"Could not update"));XCTAssertEqual(s.phase,.failure(id,"Could not update"));s.send(.dismiss);XCTAssertEqual(s.phase,.hidden) }
 func testCaptureFailureNeedsNoSubmittedRequest() { var s=PillLifecycle();s.send(.captureFailed("Select some text first"));guard case .failure(_,let message)=s.phase else{return XCTFail("Expected a capture failure")};XCTAssertEqual(message,"Select some text first");XCTAssertNil(s.phase.activeRequestID) }
}
