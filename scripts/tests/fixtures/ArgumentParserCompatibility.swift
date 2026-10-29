import ArgumentParser

private struct DefaultArguments: ParsableArguments {}

private struct LegacyLabelArguments: ParsableArguments {
  static var _errorLabel: String { "Legacy failure" }
}

private struct ExplicitPrefixArguments: ParsableArguments {
  static var _errorLabel: String { "Legacy failure" }
  static var _errorPrefix: String { "Selected prefix: " }
}

private func assertPrefix<T: ParsableArguments>(_ type: T.Type, equals expected: String) {
  precondition(type._errorPrefix == expected, "Unexpected error prefix for \(type)")
}

assertPrefix(DefaultArguments.self, equals: "Error: ")
assertPrefix(LegacyLabelArguments.self, equals: "Legacy failure: ")
assertPrefix(ExplicitPrefixArguments.self, equals: "Selected prefix: ")
