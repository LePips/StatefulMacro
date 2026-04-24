import SwiftSyntax
import SwiftSyntaxBuilder

extension StatefulMacro {
    static func codeBlockItem(_ item: CodeBlockItemSyntax.Item) -> CodeBlockItemSyntax {
        CodeBlockItemSyntax(item: item, trailingTrivia: .newline)
    }

    static func statement(_ source: String) -> CodeBlockItemSyntax {
        CodeBlockItemSyntax(item: .init(StmtSyntax(stringLiteral: source)))
    }

    static func functionBodyStatement(_ source: String) -> CodeBlockItemSyntax {
        let statement = StmtSyntax(stringLiteral: source)
            .with(\.leadingTrivia, .newline + .spaces(4))
            .with(\.trailingTrivia, .newline)
        return CodeBlockItemSyntax(
            item: .init(statement)
        )
    }

    static func functionSource(signature: String, body: [String]) -> String {
        let bodyLines = body.flatMap { source in
            source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        return """
        \(signature) {
        \(bodyLines.map { "    \($0)" }.joined(separator: "\n"))
        }
        """
    }

    static func functionRegistrations(from input: StatefulInput) -> [CodeBlockItemSyntax] {
        input.registeredFunctions.map { registration in
            var callPrefix = ""
            if registration.isThrowing {
                callPrefix += "try "
            }
            if registration.isAsync {
                callPrefix += "await "
            }

            let parameters = registration.parameterNames
            let functionStmt: String
            if parameters.isEmpty {
                functionStmt = "core.addFunction(for: \\\(registration.casePathComponent), function: { [weak self] in\n    \(callPrefix)self?.\(registration.functionName)()\n})"
            } else {
                functionStmt = "core.addFunction(for: \\\(registration.casePathComponent), function: { [weak self] \(parameters.joined(separator: ", ")) in\n    \(callPrefix)self?.\(registration.functionName)(\(parameters.joined(separator: ", ")))\n})"
            }

            return statement(functionStmt)
        }
    }

    static func sendCall(for actionCase: ActionCase, includeBackground: Bool) -> String {
        var arguments = ["\\.\(actionCase.name)"]
        let payloadNames = actionCase.payloads.map(\.internalName)

        if payloadNames.count == 1 {
            arguments.append(payloadNames[0])
        } else if payloadNames.count > 1 {
            arguments.append("(\(payloadNames.joined(separator: ", ")))")
        }

        if includeBackground {
            arguments.append("background: true")
        }

        return "send(\(arguments.joined(separator: ", ")))"
    }

    static func backgroundSendBody(for actionCase: ActionCase, isAsync: Bool) -> String {
        let prefix = isAsync ? "try? await " : ""
        return "\(prefix)core?.\(sendCall(for: actionCase, includeBackground: true))"
    }
}
