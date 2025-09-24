protocol _ActionFunctionRegistry {
    associatedtype Payload: Sendable
    mutating func addFunction(_ handler: @escaping (Payload) async throws -> Void)
}

public struct ActionFunctionRegistry<Payload>: _ActionFunctionRegistry {
    var functions: [(Payload) async throws -> Void] = []

    mutating func addFunction(_ function: @escaping (Payload) async throws -> Void) {
        functions.append(function)
    }
}
