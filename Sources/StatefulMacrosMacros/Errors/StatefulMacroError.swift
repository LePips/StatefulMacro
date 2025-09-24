import SwiftDiagnostics

enum StatefulMacroError: String, DiagnosticMessage, Error {
    case invalidStatefulTarget
    case missingActionEnum
    case actionEnumNotCasePathable
    case missingInitialState

    var message: String {
        switch self {
        case .invalidStatefulTarget:
            return "`@Stateful` can only be applied to classes."
        case .missingActionEnum:
            return "`@Stateful` requires a nested enum named `Action`."
        case .actionEnumNotCasePathable:
            return "The `Action` enum must be marked with `@CasePathable`."
        case .missingInitialState:
            return "A `State` enum, if provided, must have an `initial` case."
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "com.statefulmacro", id: rawValue)
    }

    var severity: DiagnosticSeverity { .error }
}
