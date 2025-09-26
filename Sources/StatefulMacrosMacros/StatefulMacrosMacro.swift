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
        let (actionEnumDecl, isCasePathable) = findActionEnum(in: declaration)

        guard let actionEnumDecl else {
            let diagnostic = Diagnostic(node: Syntax(node), message: StatefulMacroError.missingActionEnum)
            context.diagnose(diagnostic)
            return []
        }

        guard isCasePathable else {
            let diagnostic = Diagnostic(node: Syntax(actionEnumDecl.name), message: StatefulMacroError.actionEnumNotCasePathable)
            context.diagnose(diagnostic)
            return []
        }

        let stateActionEnums = [actionEnumDecl]
        let (backgroundStateTypeName, backgroundStateEnum) = try handleBackgroundState(in: declaration)
        let (stateEnumName, stateEnum, hasErrorState) = try handleStateEnum(in: declaration, context: context)
        let (eventTypeName, eventEnum, hasErrorEvent) = try handleEventEnum(in: declaration)

        let actionEnumName = "_Action"

        let actionEnum = try createActionEnum(
            named: actionEnumName,
            from: stateActionEnums,
            stateEnumName: stateEnumName,
            backgroundStateTypeName: backgroundStateTypeName,
            context: context
        )

        let (generatedActionFunctions, hasErrorAction) = try generateActionFunctions(
            from: stateActionEnums,
            in: declaration,
            context: context
        )

        let addFunctionStmts = try processFunctionAttributes(in: declaration, context: context)
        let coreProperty = createCoreProperty(
            stateEnumName: stateEnumName,
            actionEnumName: actionEnumName,
            eventTypeName: eventTypeName,
            addFunctionStmts: addFunctionStmts
        )

        let transitionTypeAlias: DeclSyntax = """
        public typealias Transition = StateTransition<\(raw: stateEnumName), \(raw: backgroundStateTypeName)>
        """

        let stateCoreTypeAlias: DeclSyntax = """
        public typealias _StateCore = StateCore<\(raw: stateEnumName), \(raw: actionEnumName), \(raw: eventTypeName)>
        """

        var newDecls: [DeclSyntax] = []

        if let eventEnum {
            newDecls.append(DeclSyntax(eventEnum))
        }

        if let backgroundStateEnum {
            newDecls.append(DeclSyntax(backgroundStateEnum))
        }

        newDecls.append(contentsOf: [
            DeclSyntax(stateEnum),
            DeclSyntax(actionEnum),
            transitionTypeAlias,
            stateCoreTypeAlias,
            coreProperty,
        ])

        if backgroundStateEnum != nil {
            newDecls.append(createBackgroundStruct(actionFunctions: generatedActionFunctions))
        }

        try newDecls.append(contentsOf: generatedActionFunctions.map(buildFunction))
        newDecls.append(contentsOf: createPublishedProperties(
            in: declaration,
            stateEnumName: stateEnumName,
            hasBackgroundStateType: backgroundStateEnum != nil,
            hasEventType: eventEnum != nil,
            hasError: hasErrorAction || hasErrorEvent || hasErrorState
        ))

        newDecls.append(
            createPublisherAssignments(
                hasError: hasErrorState || hasErrorEvent,
                hasBackgroundState: backgroundStateEnum != nil
            )
        )

        return newDecls
    }

    // MARK: - Private Helper Functions

    private static func findActionEnum(in declaration: some DeclGroupSyntax) -> (actionEnum: EnumDeclSyntax?, isCasePathable: Bool) {
        guard let actionEnum = declaration.memberBlock.members.compactMap({ $0.decl.as(EnumDeclSyntax.self) })
            .first(where: { $0.name.text == "Action" })
        else {
            return (nil, false)
        }

        let isCasePathable = actionEnum.attributes.contains { attr in
            attr.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "CasePathable"
        }

        return (actionEnum, isCasePathable)
    }

    private static func findEventEnum(in declaration: some DeclGroupSyntax) -> EnumDeclSyntax? {
        declaration.memberBlock.members.compactMap { $0.decl.as(EnumDeclSyntax.self) }
            .first(where: { $0.name.text == "Event" })
    }

    // MARK: - Background state

    private static func handleBackgroundState(in declaration: some DeclGroupSyntax) throws -> (String, EnumDeclSyntax?) {
        let userDefinedBackgroundStateEnum = declaration.memberBlock.members.first {
            $0.decl.as(EnumDeclSyntax.self)?.name.text == "BackgroundState"
        }?.decl.as(EnumDeclSyntax.self)

        var backgroundStateTypeName = "Never"
        var backgroundStateEnum: EnumDeclSyntax?
        if let userDefinedBackgroundStateEnum {
            let newName = "_BackgroundState"
            backgroundStateTypeName = newName
            backgroundStateEnum = try EnumDeclSyntax("public enum \(raw: newName): Hashable, Sendable") {
                for member in userDefinedBackgroundStateEnum.memberBlock.members {
                    member
                }
            }
        }
        return (backgroundStateTypeName, backgroundStateEnum)
    }

    // MARK: - Event enum

    private static func handleEventEnum(in declaration: some DeclGroupSyntax) throws -> (String, EnumDeclSyntax?, Bool) {
        let userDefinedEventEnum = findEventEnum(in: declaration)

        var eventTypeName = "Never"
        var eventEnum: EnumDeclSyntax?
        var hasErrorCase = false

        if let userDefinedEventEnum {
            let newName = "_Event"
            eventTypeName = newName

            hasErrorCase = userDefinedEventEnum.memberBlock.members.contains { member in
                guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self),
                      let caseName = caseDecl.elements.first?.name.text
                else {
                    return false
                }
                return caseName == "error"
            }

            var conformances: [String] = []

            if hasErrorCase {
                conformances.append("WithErrorEvent")
            }

            let conformancesString = conformances.isEmpty ? "" : ": \(conformances.joined(separator: ", "))"

            let newCases = userDefinedEventEnum.memberBlock.members.filter { member in
                guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else {
                    return true
                }
                return !caseDecl.elements.contains { $0.name.text == "error" }
            }

            eventEnum = try EnumDeclSyntax("public enum \(raw: newName)\(raw: conformancesString)") {
                for member in newCases {
                    member
                }
            }
        }
        return (eventTypeName, eventEnum, hasErrorCase)
    }

    // MARK: - State enum

    private static func handleStateEnum(
        in declaration: some DeclGroupSyntax,
        context: some MacroExpansionContext
    ) throws -> (String, EnumDeclSyntax, Bool) {
        let stateEnumName = "_State"
        let userDefinedStateEnum = declaration.memberBlock.members.compactMap { member -> EnumDeclSyntax? in
            guard let enumDecl = member.decl.as(EnumDeclSyntax.self) else {
                return nil
            }
            return enumDecl.name.text == "State" ? enumDecl : nil
        }.first

        var hasErrorState = false

        let stateEnum: EnumDeclSyntax
        if let userState = userDefinedStateEnum {
            let hasInitialCase = userState.memberBlock.members.contains { member in
                guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self),
                      let caseName = caseDecl.elements.first?.name.text
                else {
                    return false
                }
                return caseName == "initial"
            }

            if !hasInitialCase {
                let diagnostic = Diagnostic(node: Syntax(userState.name), message: StatefulMacroError.missingInitialState)
                context.diagnose(diagnostic)
                throw StatefulMacroError.missingInitialState
            }

            hasErrorState = userState.memberBlock.members.contains { member in
                guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self),
                      let caseName = caseDecl.elements.first?.name.text
                else {
                    return false
                }
                return caseName == "error"
            }

            var conformances = ["CoreState"]
            if hasErrorState {
                conformances.append("WithErrorState")
            }

            stateEnum = try EnumDeclSyntax("public enum \(raw: stateEnumName): \(raw: conformances.joined(separator: ", "))") {
                for member in userState.memberBlock.members {
                    member
                }
            }
        } else {
            stateEnum = try EnumDeclSyntax("public enum \(raw: stateEnumName): CoreState") {
                try EnumCaseDeclSyntax("case initial")
            }
        }
        return (stateEnumName, stateEnum, hasErrorState)
    }

    // MARK: - Action enum

    private static func createActionEnum(
        named actionEnumName: String,
        from stateActionEnums: [EnumDeclSyntax],
        stateEnumName: String,
        backgroundStateTypeName: String,
        context: some MacroExpansionContext
    ) throws -> EnumDeclSyntax {
        var actionCases = stateActionEnums.flatMap { $0.memberBlock.members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) } }
        var actionConformances = ["StateAction"]
        var hasErrorCase = false
        var hasCancelCase = false

        // Find and remove the original 'error' case, noting its existence.
        actionCases.removeAll { enumCase in
            if enumCase.elements.contains(where: { $0.name.text == "error" }) {
                hasErrorCase = true
                return true
            }

            if enumCase.elements.contains(where: { $0.name.text == "cancel" }) {
                hasCancelCase = true
            }

            return false
        }

        if hasCancelCase {
            actionConformances.append("WithCancelAction")
        }

        if hasErrorCase {
            actionConformances.append("WithErrorAction")
        }

        return try EnumDeclSyntax("@CasePathable public enum \(raw: actionEnumName): \(raw: actionConformances.joined(separator: ", "))") {
            try TypeAliasDeclSyntax("public typealias Transition = StateTransition<\(raw: stateEnumName), \(raw: backgroundStateTypeName)>")

            for enumCase in actionCases {
                enumCase
            }

            // If an 'error' case was originally present, add the new version with an associated value.
            if hasErrorCase {
                try EnumCaseDeclSyntax("case error(Error)")
            }

            let transitionVariable: VariableDeclSyntax? = stateActionEnums
                .flatMap { $0.memberBlock.members.compactMap { $0.decl.as(VariableDeclSyntax.self) } }
                .first { varDecl in
                    varDecl.bindings.contains { binding in
                        binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "transition"
                    }
                }

            if let transitionVariable {
                modifyTransitionVariable(transitionVariable)
            } else {
                try VariableDeclSyntax("public var transition: Transition") {
                    StmtSyntax("return .none")
                }
            }

            if hasCancelCase {
                try VariableDeclSyntax("public var isCancel: Bool") {
                    StmtSyntax("if case .cancel = self { return true } else { return false }")
                }
            }

            if hasErrorCase {
                try VariableDeclSyntax("public var isError: Bool") {
                    StmtSyntax("if case .error = self { return true } else { return false }")
                }
            }
        }
    }

    // MARK: - transition

    private static func modifyTransitionVariable(_ transitionVariable: VariableDeclSyntax) -> VariableDeclSyntax {
        var switchStmt: SwitchExprSyntax?
        if let accessorBlock = transitionVariable.bindings.first?.accessorBlock {
            if case let .getter(codeBlock) = accessorBlock.accessors {
                switchStmt = codeBlock.first?.item.as(SwitchExprSyntax.self)
            } else if case let .accessors(accessorList) = accessorBlock.accessors {
                if let getAccessor = accessorList.first(where: { $0.accessorSpecifier.text == "get" }) {
                    switchStmt = getAccessor.body?.statements.first?.item.as(SwitchExprSyntax.self)
                }
            }
        }

        if let switchStmt {
            let newCases = switchStmt.cases.filter {
                $0.as(SwitchCaseSyntax.self)?.label.description.contains("error") != true
            }

            var newSwitchString = "switch self {\n"
            for c in newCases {
                newSwitchString += c.description + "\n"
            }
            newSwitchString += "}"

            let newBinding = transitionVariable.bindings.first?.with(
                \.accessorBlock,
                .init(accessors: .getter(CodeBlockItemListSyntax(stringLiteral: newSwitchString)))
            )
            return transitionVariable.with(\.bindings, .init(arrayLiteral: newBinding!))
        }

        return transitionVariable
    }

    // MARK: - Action functions

    private static func generateActionFunctions(
        from stateActionEnums: [EnumDeclSyntax],
        in declaration: some DeclGroupSyntax,
        context: some MacroExpansionContext
    ) throws -> ([FunctionSyntaxPair], Bool) {
        var generatedActionFunctions: [FunctionSyntaxPair] = []
        let allCases = stateActionEnums.flatMap(\.memberBlock.members).compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }

        let hasCancelAction = allCases.contains { caseDecl in
            caseDecl.elements.contains { $0.name.text == "cancel" }
        }

        let hasErrorAction = allCases.contains { caseDecl in
            caseDecl.elements.contains { $0.name.text == "error" }
        }

        if hasErrorAction {
            let syncErrorFunc = (
                "public func error(_ error: Error)",
                "\n\tcore.send(\\.error, error)"
            )
            let asyncErrorFunc = (
                "public func error(_ error: Error) async",
                "\n\tawait core.send(\\.error, error)"
            )
            generatedActionFunctions.append(syncErrorFunc)
            generatedActionFunctions.append(asyncErrorFunc)
        }

        let cancelActionAccess = hasCancelAction ? "public" : "private"
        let syncCancelSend = hasCancelAction ? "core.send(\\.cancel)" : ""
        let asyncCancelSend = hasCancelAction ? "await core.send(\\.cancel)" : ""
        let coreCancel = "core.cancelAll()"

        let syncCancelFunc = (
            "\(cancelActionAccess) func cancel()",
            "\n\t\(coreCancel)\n\t\(syncCancelSend)"
        )
        let asyncCancelFunc = (
            "\(cancelActionAccess) func cancel() async",
            "\n\t\(coreCancel)\n\t\(asyncCancelSend)"
        )

        generatedActionFunctions.append(syncCancelFunc)
        generatedActionFunctions.append(asyncCancelFunc)

        let nonErrorCases = allCases.filter { caseDecl in
            !caseDecl.elements.contains { $0.name.text == "error" } &&
                !caseDecl.elements.contains { $0.name.text == "cancel" }
        }

        let existingFunctionNames = declaration.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self)?.name.text }

        for caseDecl in nonErrorCases {
            for element in caseDecl.elements {
                let funcName = element.name.text

                if existingFunctionNames.contains(funcName) {
                    let diagnostic = Diagnostic(node: Syntax(element.name), message: ActionFunctionConflictError(functionName: funcName))
                    context.diagnose(diagnostic)
                    continue
                }

                var parameters: [String] = []
                var parameterNames: [String] = []

                if let parameterClause = element.parameterClause {
                    var generatedArgIndex = 1
                    for param in parameterClause.parameters {
                        let paramType = param.type.trimmedDescription
                        let argName: String
                        let paramSignature: String

                        let externalName = param.firstName?.text
                        let internalName = param.secondName?.text

                        if let internalName = internalName { // case ... (external internal: Type)
                            argName = internalName
                            paramSignature = "\(externalName ?? "_") \(internalName): \(paramType)"
                        } else if let externalName = externalName, externalName != "_" { // case ... (external: Type)
                            argName = externalName
                            paramSignature = "\(externalName): \(paramType)"
                        } else { // case ... (Type) or case ... (_: Type)
                            argName = "arg\(generatedArgIndex)"
                            generatedArgIndex += 1
                            paramSignature = "_ \(argName): \(paramType)"
                        }

                        parameters.append(paramSignature)
                        parameterNames.append(argName)
                    }
                }

                let casePath = "\\.\(funcName)"
                let sendCall: String
                if parameterNames.isEmpty {
                    sendCall = "send(\(casePath))"
                } else if parameterNames.count == 1 {
                    sendCall = "send(\(casePath), \(parameterNames.first!))"
                } else {
                    let tuple = "(\(parameterNames.joined(separator: ", ")))"
                    sendCall = "send(\(casePath), \(tuple))"
                }

                let syncFuncDecl = (
                    "public func \(funcName)(\(parameters.joined(separator: ", ")))",
                    "\n\tcore.\(sendCall)"
                )
                generatedActionFunctions.append(syncFuncDecl)

                let asyncFuncDecl = (
                    "public func \(funcName)(\(parameters.joined(separator: ", "))) async ",
                    "\n\tawait core.\(sendCall)"
                )
                generatedActionFunctions.append(asyncFuncDecl)
            }
        }

        return (generatedActionFunctions, hasErrorAction)
    }

    typealias FunctionSyntaxPair = (String, String)

    private static func buildFunction(_ functionDecl: String, _ stmtSyntax: String) throws -> DeclSyntax {
        let f = try FunctionDeclSyntax("\(raw: functionDecl)") {
            StmtSyntax("\(raw: stmtSyntax)")
        }

        return DeclSyntax(f)
    }

    // MARK: - Function attributes

    private static func processFunctionAttributes(
        in declaration: some DeclGroupSyntax,
        context _: some MacroExpansionContext
    ) throws -> [String] {
        let functionDecls = declaration.memberBlock.members.compactMap { member -> (FunctionDeclSyntax, LabeledExprListSyntax)? in
            guard let funcDecl = member.decl.as(FunctionDeclSyntax.self) else {
                return nil
            }

            let functionAttribute = funcDecl.attributes.first { attr in
                guard let attrSyntax = attr.as(AttributeSyntax.self),
                      let attrName = attrSyntax.attributeName.as(IdentifierTypeSyntax.self)
                else {
                    return false
                }
                return attrName.name.text == "Function"
            }

            guard let functionAttribute = functionAttribute?.as(AttributeSyntax.self),
                  let arguments = functionAttribute.arguments?.as(LabeledExprListSyntax.self)
            else {
                return nil
            }

            return (funcDecl, arguments)
        }

        var addFunctionStmts: [String] = []
        for (funcDecl, arguments) in functionDecls {
            guard let actionCasePath = arguments.first?.expression.as(KeyPathExprSyntax.self)?.components.last else {
                continue
            }
            let funcName = funcDecl.name.text
            let functionStmt: String

            if funcDecl.signature.parameterClause.parameters.isEmpty {
                functionStmt = "core.addFunction(for: \\\(actionCasePath), function: { [weak self] in\n\ttry await self?.\(funcName)()\n})"
            } else if funcDecl.signature.parameterClause.parameters.count == 1,
                      let firstParam = funcDecl.signature.parameterClause.parameters.first
            {
                let paramName = firstParam.secondName?.text ?? firstParam.firstName.text
                functionStmt = "core.addFunction(for: \\\(actionCasePath), function: { [weak self] \(paramName) in\n\ttry await self?.\(funcName)(\(paramName))\n})"
            } else {
                let paramNames = funcDecl.signature.parameterClause.parameters.compactMap { $0.secondName?.text ?? $0.firstName.text }
                functionStmt = "core.addFunction(for: \\\(actionCasePath), function: { [weak self] \(paramNames.joined(separator: ", ")) in\n\ttry await self?.\(funcName)(\(paramNames.joined(separator: ", ")))\n})"
            }
            addFunctionStmts.append(functionStmt)
        }
        return addFunctionStmts
    }

    // MARK: - Properties

    private static func createCoreProperty(
        stateEnumName: String,
        actionEnumName: String,
        eventTypeName: String,
        addFunctionStmts: [String]
    ) -> DeclSyntax {
        let coreProperty: DeclSyntax =
            """
            private lazy var core: _StateCore = {
                let core = _StateCore()
                \(raw: addFunctionStmts.joined(separator: "\n\n"))

                setupPublisherAssignments(core: core)
                return core
            }()
            """
        return coreProperty
    }

    private static func createPublishedProperties(
        in declaration: some DeclGroupSyntax,
        stateEnumName: String,
        hasBackgroundStateType: Bool,
        hasEventType: Bool,
        hasError: Bool
    ) -> [DeclSyntax] {

        var newDecls: [DeclSyntax] = []

        if hasBackgroundStateType {
            let stateVar: DeclSyntax =
                """
                @Published
                private(set) public var background: _BackgroundActions = .init(core: nil, states: [])
                """
            newDecls.append(stateVar)
        }

        if hasError {
            let stateVar: DeclSyntax =
                """
                @Published public var error: Error? = nil
                """
            newDecls.append(stateVar)
        }

        let stateVar: DeclSyntax =
            """
            @Published public var state: \(raw: stateEnumName) = .initial
            """
        newDecls.append(stateVar)

        let actionVar: DeclSyntax =
            """
            public var actions: EventPublisher<_Action> {
                core.actionPublisher
            }
            """
        newDecls.append(actionVar)

        if hasEventType {
            let eventVar: DeclSyntax =
                """
                public var events: EventPublisher<_Event> {
                    core.eventPublisher
                }
                """
            newDecls.append(eventVar)
        }

        return newDecls
    }

    private static func createPublisherAssignments(
        hasError: Bool,
        hasBackgroundState: Bool
    ) -> DeclSyntax {
        let errorAssignment = hasError ? """
        core.$error
            .receive(on: DispatchQueue.main)
            .assign(to: &self.$error)
        """ : ""

        let backgroundAssignment = hasBackgroundState ? """
        core.$backgroundStates
            .receive(on: DispatchQueue.main)
            .map { [weak self] newValue -> _BackgroundActions? in
                return _BackgroundActions.init(
                    core: core,
                    states: newValue
                )
            }
            .compactMap { $0 }
            .assign(to: &self.$background)
        """ : ""

        return """
        private func setupPublisherAssignments(core: _StateCore) {
            core.$state
                .receive(on: DispatchQueue.main)
                .assign(to: &self.$state)
            \(raw: errorAssignment)
            \(raw: backgroundAssignment)
        }
        """
    }

    private static func generateFunctionCall(
        functionName: String,
        parameters: [FunctionParameterSyntax],
        isAsync: Bool,
        isBackground: Bool
    ) -> String {
        let paramNames = parameters.compactMap { $0.secondName?.text ?? $0.firstName.text }
        let paramList = paramNames.joined(separator: ", ")
        let backgroundPrefix = isBackground ? "background: true" : ""
        let awaitPrefix = isAsync ? "await " : ""

        if paramNames.isEmpty {
            return "\(awaitPrefix)core.send(\\.\\(functionName), \(backgroundPrefix))"
        } else if paramNames.count == 1 {
            return "\(awaitPrefix)core.send(\\.\\(functionName), \(paramList), \(backgroundPrefix))"
        } else {
            return "\(awaitPrefix)core.send(\\.\\(functionName), (\(paramList)), \(backgroundPrefix))"
        }
    }

    private static func createBackgroundStruct(
        actionFunctions: [FunctionSyntaxPair]
    ) -> DeclSyntax {

        let syncFunctions = actionFunctions.filter { functionDecl, _ in
            !functionDecl.contains(" async")
        }
        .filter { functionDecl, _ in
            !functionDecl.contains("func error(") &&
                !functionDecl.contains("func cancel(")
        }

        let optionalCoreStrings = syncFunctions.map { functionDecl, stmt in
            let stmt = stmt.replacingOccurrences(of: "core.s", with: "core?.s")
            return (functionDecl, stmt)
        }

        let functionStrings = optionalCoreStrings.map { functionDecl, stmt in
            var backgroundedStatement = stmt
            backgroundedStatement.removeLast()
            backgroundedStatement.append(", background: true)")

            return """
            \(functionDecl) {
                \(backgroundedStatement)
            }
            """
        }.joined(separator: "\n\n")

        return """
        @MainActor
        struct _BackgroundActions {

            public let states: Set<_BackgroundState>

            public func `is`(_ backgroundState: _BackgroundState) -> Bool {
                states.contains(backgroundState)
            }

            private let core: _StateCore?

            init(
                core: _StateCore?,
                states: Set<_BackgroundState> = []
            ) {
                self.core = core
                self.states = states
            }

            \(raw: functionStrings)
        }
        """
    }
}
