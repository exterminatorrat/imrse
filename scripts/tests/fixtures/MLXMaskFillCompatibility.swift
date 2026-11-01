final class MaskFillProbe {
    var finfoReads = 0
    var magnitudeReads = 0
}

public struct DType: CustomStringConvertible {
    enum Kind: String {
        case float32
        case float16
        case bfloat16
        case int32
    }

    let kind: Kind
    private let probe: MaskFillProbe

    init(_ kind: Kind, probe: MaskFillProbe) {
        self.kind = kind
        self.probe = probe
    }

    public var description: String { kind.rawValue }

    var finfo: FInfo? {
        probe.finfoReads += 1
        guard kind != .int32 else { return nil }
        switch kind {
        case .float32: return FInfo(max: Double(Float.greatestFiniteMagnitude))
        case .float16: return FInfo(max: Double(Float16.greatestFiniteMagnitude))
        case .bfloat16: return FInfo(max: Double(Float(bitPattern: 0x7F7F_0000)))
        case .int32: return nil
        }
    }

    var greatestFiniteMagnitudeArray: MLXArray {
        probe.magnitudeReads += 1
        let maximum: Double
        switch kind {
        case .float32: maximum = Double(Float.greatestFiniteMagnitude)
        case .float16: maximum = Double(Float16.greatestFiniteMagnitude)
        case .bfloat16: maximum = Double(Float(bitPattern: 0x7F7F_0000))
        case .int32: fatalError("unexpected greatestFiniteMagnitudeArray")
        }
        return MLXArray(maximum, dtype: self)
    }
}

struct FInfo {
    let max: Double
}

public struct MLXArray {
    let value: Double
    let dtype: DType

    init(_ value: Double, dtype: DType) {
        self.value = value
        self.dtype = dtype
    }

    static prefix func - (array: MLXArray) -> MLXArray {
        MLXArray(-array.value, dtype: array.dtype)
    }
}

@main
struct MLXMaskFillCompatibility {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "invalid" {
            _ = MLXArray.maskFill(for: DType(.int32, probe: MaskFillProbe()))
            fatalError("invalid dtype unexpectedly returned")
        }

        let cases: [(DType.Kind, Double)] = [
            (.float32, Double(Float.greatestFiniteMagnitude)),
            (.float16, Double(Float16.greatestFiniteMagnitude)),
            (.bfloat16, Double(Float(bitPattern: 0x7F7F_0000))),
        ]
        for (kind, maximum) in cases {
            let probe = MaskFillProbe()
            let dtype = DType(kind, probe: probe)
            let result = MLXArray.maskFill(for: dtype)
            guard result.value == -maximum else { fatalError("maskFill returned the wrong negative maximum") }
            guard result.dtype.description == dtype.description else { fatalError("maskFill changed the dtype") }
            guard probe.finfoReads == 1 else { fatalError("maskFill must evaluate finfo exactly once") }
            guard probe.magnitudeReads == 1 else { fatalError("maskFill must use greatestFiniteMagnitudeArray once") }
        }
    }
}
