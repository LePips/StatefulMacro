import SwiftDiagnostics

struct ActionFunctionConflictError: DiagnosticMessage, Error {
    let functionName: String

    var message: String {
        "A function with the same name as the action case '\(functionName)' already exists."
    }

    var diagnosticID: MessageID {
        MessageID(domain: "com.statefulmacro", id: "actionFunctionConflict")
    }

    var severity: DiagnosticSeverity { .error }
}
