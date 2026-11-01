import Foundation

private final class ParameterInfoGetterHarness<T> {
    var value: T?

    init(storedValue: T?) {
        value = storedValue
    }

    var wrappedValue: T {
        __PARAMETER_GETTER__
    }
}

private final class ModuleInfoGetterHarness<T> {
    var module: T?

    init(storedValue: T?) {
        module = storedValue
    }

    var wrappedValue: T {
        __MODULE_GETTER__
    }
}

private final class PlainOptionalUnwrapParameter<T> {
    var value: T?

    init(storedValue: T?) {
        value = storedValue
    }

    var wrappedValue: T {
        get {
            if let value = value {
                return value
            } else {
                return value!
            }
        }
    }
}

private final class PlainOptionalUnwrapModule<T> {
    var module: T?

    init(storedValue: T?) {
        module = storedValue
    }

    var wrappedValue: T {
        get {
            if let module = module {
                return module
            } else {
                return module!
            }
        }
    }
}

private final class ReferenceValue {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

@inline(never)
private func referenceCast<Source, Destination>(_ value: Source, to: Destination.Type) -> Destination? {
    value as? Destination
}

private func referenceGetter<T>(_ value: T?) -> T {
    if let value = referenceCast(value, to: T.self) {
        return value
    }
    return value!
}

private func sameReference(_ lhs: ReferenceValue?, _ rhs: ReferenceValue?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case (.some(let lhs), .some(let rhs)):
        return lhs === rhs
    default:
        return false
    }
}

private func sameReference(_ lhs: ReferenceValue??, _ rhs: ReferenceValue??) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none), (.some(.none), .some(.none)):
        return true
    case (.some(.some(let lhs)), .some(.some(let rhs))):
        return lhs === rhs
    default:
        return false
    }
}

private func verifyMatrix<T>(
    _ type: String,
    _ cases: [(String, T?)],
    parameter: (T?) -> T,
    module: (T?) -> T,
    matches: (T, T) -> Bool
) {
    for (name, storedValue) in cases {
        let reference = referenceGetter(storedValue)
        let parameterValue = parameter(storedValue)
        let moduleValue = module(storedValue)
        let parameterMatches = matches(parameterValue, reference)
        let moduleMatches = matches(moduleValue, reference)
        let line = "REFERENCE_MATRIX:\(type):\(name) input=\(String(reflecting: storedValue)) "
            + "reference=\(String(reflecting: reference)) parameter=\(String(reflecting: parameterValue)) "
            + "module=\(String(reflecting: moduleValue)) parameter_match=\(parameterMatches) "
            + "module_match=\(moduleMatches)\n"
        FileHandle.standardError.write(Data(line.utf8))
        expect(parameterMatches && moduleMatches, "\(type) \(name) differs from the direct cast oracle")
    }
}

private func announceTrapMode(_ mode: String) {
    FileHandle.standardError.write(Data("GETTER_TRAP_MODE:\(mode)\n".utf8))
}

@main
enum MLXGetterCompatibility {
    static func main() {
        switch CommandLine.arguments.dropFirst().first ?? "" {
        case "--missing-reference":
            announceTrapMode("missing-reference")
            _ = referenceGetter(nil as Int?)
            print("MISSING_REFERENCE_RETURNED")
            return
        case "--missing-parameter":
            announceTrapMode("missing-parameter")
            _ = ParameterInfoGetterHarness<Int>(storedValue: nil).wrappedValue
            print("MISSING_VALUE_RETURNED")
            return
        case "--missing-module":
            announceTrapMode("missing-module")
            _ = ModuleInfoGetterHarness<Int>(storedValue: nil).wrappedValue
            print("MISSING_VALUE_RETURNED")
            return
        case "--negative-control-parameter":
            announceTrapMode("negative-control-parameter")
            _ = PlainOptionalUnwrapParameter<Int?>(storedValue: nil).wrappedValue
            print("NEGATIVE_CONTROL_RETURNED")
            return
        case "--negative-control-module":
            announceTrapMode("negative-control-module")
            _ = PlainOptionalUnwrapModule<Int?>(storedValue: nil).wrappedValue
            print("NEGATIVE_CONTROL_RETURNED")
            return
        default:
            break
        }

        verifyParameterInfo()
        verifyModuleInfo()
        verifyReferenceMatrix()
        verifySpecDepthPreservation()
        print("GETTER_MATRIX_PASSED")
    }

    private static func verifyParameterInfo() {
        expect(ParameterInfoGetterHarness<Int>(storedValue: 31).wrappedValue == 31,
               "ParameterInfo lost a nonoptional value")
        let innerNil: Int? = ParameterInfoGetterHarness<Int?>(storedValue: .some(nil)).wrappedValue
        expect(innerNil == nil, "ParameterInfo lost an inner optional nil")
        let outerNil: Int? = ParameterInfoGetterHarness<Int?>(storedValue: nil).wrappedValue
        expect(outerNil == nil, "ParameterInfo trapped or changed an outer storage nil")
        let nestedValue: Int?? = ParameterInfoGetterHarness<Int??>(storedValue: .some(.some(.some(37)))).wrappedValue
        if case .some(.some(37)) = nestedValue {
        } else {
            fatalError("ParameterInfo changed a nested optional value")
        }
        let reference = ReferenceValue()
        expect(ParameterInfoGetterHarness<ReferenceValue>(storedValue: reference).wrappedValue === reference,
               "ParameterInfo changed reference identity")
    }

    private static func verifyModuleInfo() {
        expect(ModuleInfoGetterHarness<Int>(storedValue: 47).wrappedValue == 47,
               "ModuleInfo lost a nonoptional value")
        let innerNil: Int? = ModuleInfoGetterHarness<Int?>(storedValue: .some(nil)).wrappedValue
        expect(innerNil == nil, "ModuleInfo lost an inner optional nil")
        let outerNil: Int? = ModuleInfoGetterHarness<Int?>(storedValue: nil).wrappedValue
        expect(outerNil == nil, "ModuleInfo trapped or changed an outer storage nil")
        let nestedValue: Int?? = ModuleInfoGetterHarness<Int??>(storedValue: .some(.some(.some(53)))).wrappedValue
        if case .some(.some(53)) = nestedValue {
        } else {
            fatalError("ModuleInfo changed a nested optional value")
        }
        let reference = ReferenceValue()
        expect(ModuleInfoGetterHarness<ReferenceValue>(storedValue: reference).wrappedValue === reference,
               "ModuleInfo changed reference identity")
    }

    private static func verifyReferenceMatrix() {
        let optionalValues: [(String, Int??)] = [
            ("outer nil", nil), ("inner nil", .some(nil)), ("value", .some(.some(31)))
        ]
        verifyMatrix("Int?", optionalValues,
                     parameter: { ParameterInfoGetterHarness<Int?>(storedValue: $0).wrappedValue },
                     module: { ModuleInfoGetterHarness<Int?>(storedValue: $0).wrappedValue },
                     matches: { $0 == $1 })

        let nestedValues: [(String, Int???)] = [
            ("outer nil", nil), ("middle nil", .some(nil)),
            ("inner nil", .some(.some(nil))), ("value", .some(.some(.some(37))))
        ]
        verifyMatrix("Int??", nestedValues,
                     parameter: { ParameterInfoGetterHarness<Int??>(storedValue: $0).wrappedValue },
                     module: { ModuleInfoGetterHarness<Int??>(storedValue: $0).wrappedValue },
                     matches: { $0 == $1 })

        let reference = ReferenceValue()
        let optionalReferences: [(String, ReferenceValue??)] = [
            ("outer nil", nil), ("inner nil", .some(nil)), ("identity", .some(.some(reference)))
        ]
        verifyMatrix("ReferenceValue?", optionalReferences,
                     parameter: { ParameterInfoGetterHarness<ReferenceValue?>(storedValue: $0).wrappedValue },
                     module: { ModuleInfoGetterHarness<ReferenceValue?>(storedValue: $0).wrappedValue },
                     matches: { sameReference($0, $1) })

        let nestedReferences: [(String, ReferenceValue???)] = [
            ("outer nil", nil), ("middle nil", .some(nil)), ("inner nil", .some(.some(nil))),
            ("identity", .some(.some(.some(reference))))
        ]
        verifyMatrix("ReferenceValue??", nestedReferences,
                     parameter: { ParameterInfoGetterHarness<ReferenceValue??>(storedValue: $0).wrappedValue },
                     module: { ModuleInfoGetterHarness<ReferenceValue??>(storedValue: $0).wrappedValue },
                     matches: { sameReference($0, $1) })
    }

    private static func verifySpecDepthPreservation() {
        let depthOne: Int???? = .some(.some(.some(.none)))
        let castFour: Int????? = referenceCast(depthOne, to: Int????.self)
        if case .some(.some(.some(.some(.none)))) = castFour {} else {
            fatalError("documented four-level cast depth changed")
        }
        let castThree: Int???? = referenceCast(depthOne, to: Int???.self)
        if case .some(.some(.some(.none))) = castThree {} else {
            fatalError("documented three-level cast depth changed")
        }
        let castTwo: Int??? = referenceCast(depthOne, to: Int??.self)
        if case .some(.some(.none)) = castTwo {} else {
            fatalError("documented two-level cast depth changed")
        }
        let castOne: Int?? = referenceCast(depthOne, to: Int?.self)
        if case .some(.none) = castOne {} else {
            fatalError("documented one-level cast depth changed")
        }

        let depthFour: Int???? = .none
        let castFallback: Int??? = referenceCast(depthFour, to: Int??.self)
        if case .some(.none) = castFallback {} else {
            fatalError("documented greatest-possible cast depth changed")
        }
    }
}
