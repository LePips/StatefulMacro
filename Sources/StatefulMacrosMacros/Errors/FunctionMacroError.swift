import SwiftDiagnostics

enum FunctionMacroError: String, DiagnosticMessage, Error {
    case nameCollision
    case requiresFunctionDeclaration
    case parameterNamesMustBeUnderscored

    var message: String {
        switch self {
        case .nameCollision:
            return "Function name cannot be the same as the action case name"
        case .requiresFunctionDeclaration:
            return "`@Function` can only be applied to functions"
        case .parameterNamesMustBeUnderscored:
            return "All parameters of a `@Function` must have underscored names"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "com.statefulmacro.functionmacro", id: rawValue)
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
