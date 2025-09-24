import SwiftDiagnostics

struct DebugError: DiagnosticMessage, Error {

    let message: String

    init(_ message: String) {
        self.message = message
    }

    var diagnosticID: MessageID {
        MessageID(domain: "com.statefulmacro", id: "internalError")
    }

    var severity: DiagnosticSeverity { .error }
}
