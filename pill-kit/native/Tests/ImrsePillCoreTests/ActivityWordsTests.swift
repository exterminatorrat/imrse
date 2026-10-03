import XCTest
@testable import ImrsePillCore
final class ActivityWordsTests: XCTestCase {
    func testWordTiming() { XCTAssertEqual(ActivityWords.word(at:0),"Thinking");XCTAssertEqual(ActivityWords.word(at:2.499),"Thinking");XCTAssertEqual(ActivityWords.word(at:2.5),"Refining");XCTAssertEqual(ActivityWords.word(at:10),"Discombobulating");XCTAssertEqual(ActivityWords.word(at:12.5),"Thinking") }
    func testEmptyWords() { XCTAssertEqual(ActivityWords.word(at:10,words:[]),"Thinking") }
    func testInvalidElapsed() { XCTAssertEqual(ActivityWords.word(at: -.infinity),"Thinking");XCTAssertEqual(ActivityWords.word(at: -.nan),"Thinking");XCTAssertEqual(ActivityWords.word(at: -5),"Thinking") }
    func testInvalidInterval() { XCTAssertEqual(ActivityWords.word(at:2.5,interval:0),"Refining") }
    func testSequenceExactlyFourFastTwoSlow() { var s=SpiralCycle();for _ in 0..<3{s.complete();XCTAssertEqual(s.phase,.fast)};s.complete();XCTAssertEqual(s.phase,.slow);s.complete();XCTAssertEqual(s.phase,.slow);s.complete();XCTAssertEqual(s.phase,.fast);XCTAssertEqual(s.completedRepeats,0) }
    func testManyCyclesDoNotDrift() { var s=SpiralCycle();for _ in 0..<600{s.complete()};XCTAssertEqual(s.phase,.fast);XCTAssertEqual(s.completedRepeats,0) }
}
