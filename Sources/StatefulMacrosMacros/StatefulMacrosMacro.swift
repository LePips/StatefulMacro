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
        let macroContext = try createContext(of: node, in: declaration, context: context)

        let coreProperty = Self.createCoreProperty(
            stateEnumName: macroContext.stateEnumName,
            actionEnumName: macroContext.actionEnumName,
            eventTypeName: macroContext.eventTypeName,
            addFunctionStmts: macroContext.addFunctionStmts
        )

        let transitionTypeAlias: DeclSyntax = """
        \(raw: macroContext.access) typealias Transition = StateTransition<\(raw: macroContext.stateEnumName), \(raw: macroContext.backgroundStateTypeName)>
        """

        let stateCoreTypeAlias: DeclSyntax = """
        \(raw: macroContext.access) typealias _StateCore = StateCore<\(raw: macroContext.stateEnumName), \(raw: macroContext.actionEnumName), \(raw: macroContext.eventTypeName)>
        """

        var newDecls: [DeclSyntax] = []

        if let eventEnum = macroContext.eventEnum {
            newDecls.append(DeclSyntax(eventEnum))
        }

        if let backgroundStateEnum = macroContext.backgroundStateEnum {
            newDecls.append(DeclSyntax(backgroundStateEnum))
        }

        newDecls.append(contentsOf: [
            DeclSyntax(macroContext.stateEnum),
            DeclSyntax(macroContext.actionEnum),
            transitionTypeAlias,
            stateCoreTypeAlias,
            coreProperty,
        ])

        if macroContext.backgroundStateEnum != nil {
            newDecls.append(Self.createBackgroundStruct(actionFunctions: macroContext.generatedActionFunctions, conformances: macroContext.conformances, access: macroContext.access))
        }

        try newDecls.append(contentsOf: macroContext.generatedActionFunctions.map(Self.buildFunction))
        newDecls.append(contentsOf: Self.createPublishedProperties(
            in: declaration,
            stateEnumName: macroContext.stateEnumName,
            hasBackgroundStateType: macroContext.backgroundStateEnum != nil,
            hasEventType: macroContext.eventEnum != nil,
            hasError: macroContext.hasErrorAction || macroContext.hasErrorEvent || macroContext.hasErrorState,
            access: macroContext.access
        ))

        newDecls.append(
            Self.createPublisherAssignments(
                hasError: macroContext.hasErrorState || macroContext.hasErrorEvent || macroContext.hasErrorAction,
                hasBackgroundState: macroContext.backgroundStateEnum != nil
            )
        )

        return newDecls
    }

    private static func createContext(of node: AttributeSyntax, in declaration: some DeclGroupSyntax, context: some MacroExpansionContext) throws -> StatefulMacroContext {
        let access = Self.getAccessLevel(from: declaration)
        let conformances = Self.getConformances(from: node)
        let (actionEnumDecl, isCasePathable) = Self.findActionEnum(in: declaration)

        guard let actionEnumDecl else {
            let diagnostic = Diagnostic(node: Syntax(node), message: StatefulMacroError.missingActionEnum)
            context.diagnose(diagnostic)
            throw StatefulMacroError.missingActionEnum
        }

        guard isCasePathable else {
            let diagnostic = Diagnostic(node: Syntax(actionEnumDecl.name), message: StatefulMacroError.actionEnumNotCasePathable)
            context.diagnose(diagnostic)
            throw StatefulMacroError.actionEnumNotCasePathable
        }

        let stateActionEnums = [actionEnumDecl]
        let (backgroundStateTypeName, backgroundStateEnum) = try Self.handleBackgroundState(in: declaration, access: access)
        let (stateEnumName, stateEnum, hasErrorState) = try Self.handleStateEnum(in: declaration, context: context, access: access)
        let (eventTypeName, eventEnum, hasErrorEvent) = try Self.handleEventEnum(in: declaration, access: access)

        let actionEnumName = "_Action"

        let actionEnum = try Self.createActionEnum(
            named: actionEnumName,
            from: stateActionEnums,
            stateEnumName: stateEnumName,
            backgroundStateTypeName: backgroundStateTypeName,
            context: context,
            access: access
        )

        let (addFunctionStmts, throwingActions) = try Self.processFunctionAttributes(in: declaration, context: context)

        let (generatedActionFunctions, hasErrorAction) = try Self.generateActionFunctions(
            from: stateActionEnums,
            in: declaration,
            throwingActions: throwingActions,
            context: context,
            access: access
        )

        return StatefulMacroContext(
            access: access,
            conformances: conformances,
            actionEnumDecl: actionEnumDecl,
            isCasePathable: isCasePathable,
            stateActionEnums: stateActionEnums,
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
            addFunctionStmts: addFunctionStmts,
            throwingActions: throwingActions,
            generatedActionFunctions: generatedActionFunctions,
            hasErrorAction: hasErrorAction
        )
    }
}