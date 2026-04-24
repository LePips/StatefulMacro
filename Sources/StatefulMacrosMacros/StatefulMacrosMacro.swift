import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implementation of the `@Stateful` member macro.
public struct StatefulMacro: MemberMacro {

    // MARK: - Member Macro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let input = try Self.makeInput(of: node, in: declaration, context: context)
        try Self.validateAction(in: input, node: node, context: context)
        return try Self.assembleMembers(from: buildPlan(from: input, context: context))
    }

    private static func validateAction(
        in input: StatefulInput,
        node: AttributeSyntax,
        context: some MacroExpansionContext
    ) throws {
        guard let actionEnum = input.actionEnum else {
            let diagnostic = Diagnostic(node: Syntax(node), message: StatefulMacroError.missingActionEnum)
            context.diagnose(diagnostic)
            throw StatefulMacroError.missingActionEnum
        }

        guard input.actionEnumIsCasePathable else {
            let diagnostic = Diagnostic(node: Syntax(actionEnum.name), message: StatefulMacroError.actionEnumNotCasePathable)
            context.diagnose(diagnostic)
            throw StatefulMacroError.actionEnumNotCasePathable
        }
    }

    private static func buildPlan(
        from input: StatefulInput,
        context: some MacroExpansionContext
    ) throws -> StatefulPlan {
        let (backgroundStateTypeName, backgroundStateEnum) = try Self.generatedBackgroundState(from: input)
        let (stateEnumName, stateEnum, hasErrorState) = try Self.generatedState(from: input, context: context)
        let (eventTypeName, eventEnum, hasErrorEvent) = try Self.generatedEvent(from: input)
        let actionEnumName = "_Action"

        let actionEnum = try Self.generatedActionEnum(
            named: actionEnumName,
            from: input,
            stateEnumName: stateEnumName,
            backgroundStateTypeName: backgroundStateTypeName,
            access: input.access
        )
        let generatedActionFunctions = try Self.generatedActionFunctions(
            from: input,
            context: context,
            access: input.access
        )

        return StatefulPlan(
            access: input.access,
            conformances: input.conformances,
            backgroundStateTypeName: backgroundStateTypeName,
            backgroundStateEnum: backgroundStateEnum,
            stateEnumName: stateEnumName,
            stateEnum: stateEnum,
            hasErrorState: hasErrorState,
            eventTypeName: eventTypeName,
            eventEnum: eventEnum,
            hasErrorEvent: hasErrorEvent,
            actionEnumName: actionEnumName,
            actionEnum: actionEnum,
            addFunctionStmts: Self.functionRegistrations(from: input),
            generatedActionFunctions: generatedActionFunctions,
            hasErrorAction: input.hasErrorAction
        )
    }
}
