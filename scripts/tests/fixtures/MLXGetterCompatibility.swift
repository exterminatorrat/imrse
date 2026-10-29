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

private func announceTrapMode(_ mode: String) {
    FileHandle.standardError.write(Data("GETTER_TRAP_MODE:\(mode)\n".utf8))
}

@main
enum MLXGetterCompatibility {
    static func main() {
        switch CommandLine.arguments.dropFirst().first ?? "" {
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
        print("GETTER_MATRIX_PASSED")
    }

    private static func verifyParameterInfo() {
        expect(ParameterInfoGetterHarness<Int>(storedValue: 31).wrappedValue == 31,
               "ParameterInfo lost a nonoptional value")
        let innerNil: Int? = ParameterInfoGetterHarness<Int?>(storedValue: .some(nil)).wrappedValue
        expect(innerNil == nil, "ParameterInfo lost an inner optional nil")
        let outerNil: Int? = ParameterInfoGetterHarness<Int?>(storedValue: nil).wrappedValue
        expect(outerNil == nil, "ParameterInfo trapped or changed an outer storage nil")
        let middleNil: Int?? = ParameterInfoGetterHarness<Int??>(storedValue: .some(nil)).wrappedValue
        expect(middleNil == nil, "ParameterInfo changed a nested optional nil")
        let innerNestedNil: Int?? = ParameterInfoGetterHarness<Int??>(storedValue: .some(.some(nil))).wrappedValue
        if case .some(.none) = innerNestedNil {
        } else {
            fatalError("ParameterInfo collapsed nested optional depth")
        }
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
        let middleNil: Int?? = ModuleInfoGetterHarness<Int??>(storedValue: .some(nil)).wrappedValue
        expect(middleNil == nil, "ModuleInfo changed a nested optional nil")
        let innerNestedNil: Int?? = ModuleInfoGetterHarness<Int??>(storedValue: .some(.some(nil))).wrappedValue
        if case .some(.none) = innerNestedNil {
        } else {
            fatalError("ModuleInfo collapsed nested optional depth")
        }
        let nestedValue: Int?? = ModuleInfoGetterHarness<Int??>(storedValue: .some(.some(.some(53)))).wrappedValue
        if case .some(.some(53)) = nestedValue {
        } else {
            fatalError("ModuleInfo changed a nested optional value")
        }
        let reference = ReferenceValue()
        expect(ModuleInfoGetterHarness<ReferenceValue>(storedValue: reference).wrappedValue === reference,
               "ModuleInfo changed reference identity")
    }
}
