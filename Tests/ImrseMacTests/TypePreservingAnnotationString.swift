#if os(macOS)
import AppKit
import CoreFoundation
import Foundation
import Testing

final class TypePreservingAnnotationString: NSAttributedString {
    private let base: NSAttributedString
    private let annotation: Any
    private let annotationRange: NSRange
    private let annotationKey = NSAttributedString.Key("AXMarkedMisspelled")

    init(_ base: NSAttributedString, annotation: Any, range: NSRange) {
        precondition(range.location >= 0 && range.length > 0)
        precondition(range.location <= base.length && range.length <= base.length - range.location)
        self.base = base
        self.annotation = annotation
        annotationRange = range
        super.init(string: base.string)
    }

    required init?(coder: NSCoder) { return nil }

    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { return nil }

    override var string: String { base.string }
    override var length: Int { base.length }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        precondition(location >= 0 && location < base.length)
        var baseRange = NSRange()
        var result = base.attributes(at: location, effectiveRange: &baseRange)
        let lowerBound: Int
        let upperBound: Int
        if location < annotationRange.location {
            lowerBound = baseRange.location
            upperBound = min(NSMaxRange(baseRange), annotationRange.location)
        } else if location < NSMaxRange(annotationRange) {
            lowerBound = max(baseRange.location, annotationRange.location)
            upperBound = min(NSMaxRange(baseRange), NSMaxRange(annotationRange))
            result[annotationKey] = annotation
        } else {
            lowerBound = max(baseRange.location, NSMaxRange(annotationRange))
            upperBound = NSMaxRange(baseRange)
        }
        range?.pointee = NSRange(location: lowerBound, length: upperBound - lowerBound)
        return result
    }
}

@Suite
struct AnnotationFixtureTypeTests {
    @Test
    func preservesBooleanAndNumericTypesWithOtherwiseIdenticalAttributes() throws {
        let key = NSAttributedString.Key("AXMarkedMisspelled")
        let base = NSAttributedString(string: "before sample after", attributes: [
            NSAttributedString.Key("AXFont"): "synthetic font",
            NSAttributedString.Key("AXForegroundColor"): "synthetic foreground"
        ])
        let range = NSRange(location: 7, length: 6)
        let boolean = TypePreservingAnnotationString(base, annotation: NSNumber(value: true), range: range)
        let numeric = TypePreservingAnnotationString(base, annotation: NSNumber(value: 1), range: range)
        let boolValue = try #require(boolean.attribute(key, at: 7, effectiveRange: nil))
        let numberValue = try #require(numeric.attribute(key, at: 7, effectiveRange: nil))
        #expect(CFGetTypeID(boolValue as CFTypeRef) == CFBooleanGetTypeID())
        #expect(CFGetTypeID(numberValue as CFTypeRef) == CFNumberGetTypeID())
        #expect(CFGetTypeID(numberValue as CFTypeRef) != CFBooleanGetTypeID())
        for value in [boolean, numeric] {
            var effective = NSRange()
            _ = value.attributes(at: 8, effectiveRange: &effective)
            #expect(effective == range)
            #expect(value.attribute(key, at: 0, effectiveRange: nil) == nil)
            #expect(value.attribute(key, at: 13, effectiveRange: nil) == nil)
        }
    }
}
#endif
