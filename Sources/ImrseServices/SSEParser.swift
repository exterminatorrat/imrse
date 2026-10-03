import Foundation
import ImrseCore

struct SSEParser {
    private let maximumEventBytes: Int
    private var line = Data()
    private var eventData = Data()
    private var hasDataField = false
    private var previousWasCR = false

    init(maximumEventBytes: Int) {
        self.maximumEventBytes = max(1, maximumEventBytes)
    }

    mutating func append(_ bytes: Data) throws -> [String] {
        var events: [String] = []
        for byte in bytes {
            if byte == 0x0A {
                if previousWasCR {
                    previousWasCR = false
                } else if let event = try processLine() {
                    events.append(event)
                }
                continue
            }
            if byte == 0x0D {
                if let event = try processLine() { events.append(event) }
                previousWasCR = true
                continue
            }
            previousWasCR = false
            line.append(byte)
            guard line.count <= maximumEventBytes else { throw ImrseError.outputTooLarge }
        }
        return events
    }

    mutating func finish() throws -> [String] {
        var events: [String] = []
        if !line.isEmpty, let event = try processLine() { events.append(event) }
        if hasDataField, let event = try dispatchEvent() { events.append(event) }
        return events
    }

    private mutating func processLine() throws -> String? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return try dispatchEvent() }
        if line.first == 0x3A { return nil }

        let separator = line.firstIndex(of: 0x3A)
        let fieldEnd = separator ?? line.endIndex
        let field = line[..<fieldEnd]
        guard field == Data("data".utf8) else { return nil }

        var value = separator.map { Data(line[line.index(after: $0)...]) } ?? Data()
        if value.first == 0x20 { value.removeFirst() }
        let addedBytes = value.count + (hasDataField ? 1 : 0)
        guard eventData.count + addedBytes <= maximumEventBytes else { throw ImrseError.outputTooLarge }
        if hasDataField { eventData.append(0x0A) }
        eventData.append(value)
        hasDataField = true
        return nil
    }

    private mutating func dispatchEvent() throws -> String? {
        defer {
            eventData.removeAll(keepingCapacity: true)
            hasDataField = false
        }
        guard hasDataField else { return nil }
        guard let value = String(data: eventData, encoding: .utf8) else { throw ImrseError.malformedResponse }
        return value
    }
}
