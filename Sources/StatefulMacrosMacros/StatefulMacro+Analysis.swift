import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

extension StatefulMacro {
    static func generatedEvent(
        from input: StatefulInput
    ) throws -> (typeName: String, declaration: EnumDeclSyntax?, hasError: Bool) {
        guard let userEvent = input.eventEnum else {
            return ("Never", nil, false)
        }

        let hasError = userEvent.memberBlock.members.contains {
            $0.decl.as(EnumCaseDeclSyntax.self)?.hasCase(named: "error") == true
        }
        let conformances = hasError ? ": WithErrorEvent" : ""
        let members = userEvent.memberBlock.members.filter {
            !($0.decl.as(EnumCaseDeclSyntax.self)?.hasCase(named: "error") == true)
        }

        return try ("_Event", EnumDeclSyntax("\(raw: input.access) enum _Event\(raw: conformances)") {
            for member in members {
                member.trimmed
            }
        }, hasError)
    }

    static func generatedBackgroundState(
        from input: StatefulInput
    ) throws -> (typeName: String, declaration: EnumDeclSyntax?) {
        guard let backgroundState = input.backgroundStateEnum else {
            return ("Never", nil)
        }

        return try ("_BackgroundState", EnumDeclSyntax("\(raw: input.access) enum _BackgroundState: Hashable, Sendable") {
            for member in backgroundState.memberBlock.members {
                member.trimmed
            }
        })
    }

    static func generatedState(
        from input: StatefulInput,
        context: some MacroExpansionContext
    ) throws -> (typeName: String, declaration: EnumDeclSyntax, hasError: Bool) {
        guard let userState = input.stateEnum else {
            return try ("_State", EnumDeclSyntax("\(raw: input.access) enum _State: CoreState") {
                try EnumCaseDeclSyntax("case initial")
            }, false)
        }

        let hasInitial = userState.memberBlock.members.contains {
            $0.decl.as(EnumCaseDeclSyntax.self)?.hasCase(named: "initial") == true
        }
        guard hasInitial else {
            context.diagnose(Diagnostic(node: Syntax(userState.name), message: StatefulMacroError.missingInitialState))
            throw StatefulMacroError.missingInitialState
        }

        let hasError = userState.memberBlock.members.contains {
            $0.decl.as(EnumCaseDeclSyntax.self)?.hasCase(named: "error") == true
        }
        let conformances = hasError ? "CoreState, WithErrorState" : "CoreState"

        return try ("_State", EnumDeclSyntax("\(raw: input.access) enum _State: \(raw: conformances)") {
            for member in userState.memberBlock.members {
                member.trimmed
            }
        }, hasError)
    }
}

extension EnumCaseDeclSyntax {
    func hasCase(named name: String) -> Bool {
        elements.contains { $0.name.text == name }
    }
}
