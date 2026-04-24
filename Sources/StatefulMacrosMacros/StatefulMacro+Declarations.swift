import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension StatefulMacro {
    static func assembleMembers(from plan: StatefulPlan) throws -> [DeclSyntax] {
        var declarations: [DeclSyntax] = []

        if let eventEnum = plan.eventEnum {
            declarations.append(DeclSyntax(eventEnum))
        }
        if let backgroundStateEnum = plan.backgroundStateEnum {
            declarations.append(DeclSyntax(backgroundStateEnum))
        }

        try declarations.append(contentsOf: [
            DeclSyntax(plan.stateEnum),
            DeclSyntax(plan.actionEnum),
            createTypeAlias(
                access: plan.access,
                name: "Transition",
                type: "StateTransition<\(plan.stateEnumName), \(plan.backgroundStateTypeName)>"
            ),
            createTypeAlias(
                access: plan.access,
                name: "_StateCore",
                type: "StateCore<\(plan.stateEnumName), \(plan.actionEnumName), \(plan.eventTypeName)>"
            ),
            coreProperty(addFunctionStmts: plan.addFunctionStmts),
        ])

        if plan.backgroundStateEnum != nil {
            try declarations.append(backgroundActions(
                actionFunctions: plan.generatedActionFunctions,
                conformances: plan.conformances,
                access: plan.access
            ))
        }

        declarations.append(contentsOf: plan.generatedActionFunctions.map { DeclSyntax($0.declaration) })
        declarations.append(contentsOf: publishedProperties(
            stateEnumName: plan.stateEnumName,
            hasBackgroundStateType: plan.backgroundStateEnum != nil,
            hasEventType: plan.eventEnum != nil,
            hasError: plan.hasErrorAction || plan.hasErrorEvent || plan.hasErrorState,
            access: plan.access
        ))
        try declarations.append(publisherAssignments(
            hasError: plan.hasErrorAction || plan.hasErrorEvent || plan.hasErrorState,
            hasBackgroundState: plan.backgroundStateEnum != nil
        ))

        return declarations
    }

    static func createTypeAlias(access: String, name: String, type: String) -> DeclSyntax {
        DeclSyntax(
            TypeAliasDeclSyntax(
                modifiers: accessModifiers(access),
                name: .identifier(name),
                initializer: TypeInitializerClauseSyntax(value: TypeSyntax(stringLiteral: type))
            )
        )
    }

    static func accessModifiers(_ access: String) -> DeclModifierListSyntax {
        let token: TokenSyntax = switch access {
        case "public":
            .keyword(.public)
        case "private":
            .keyword(.private)
        case "fileprivate":
            .keyword(.fileprivate)
        default:
            .keyword(.internal)
        }
        return [.init(name: token)]
    }

    static func generatedActionEnum(
        named actionEnumName: String,
        from input: StatefulInput,
        stateEnumName: String,
        backgroundStateTypeName: String,
        access: String
    ) throws -> EnumDeclSyntax {
        var actionCases = input.actionCases.map(\.trimmed)
        var actionConformances = ["StateAction"]
        var hasErrorCase = false
        var hasCancelCase = false

        actionCases.removeAll { enumCase in
            if enumCase.hasCase(named: "error") {
                hasErrorCase = true
                return true
            }

            if enumCase.hasCase(named: "cancel") {
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

        return try EnumDeclSyntax(
            "@CasePathable \(raw: access) enum \(raw: actionEnumName): \(raw: actionConformances.joined(separator: ", "))"
        ) {
            try TypeAliasDeclSyntax(
                "\(raw: access) typealias Transition = StateTransition<\(raw: stateEnumName), \(raw: backgroundStateTypeName)>"
            )

            for enumCase in actionCases {
                enumCase
            }

            if hasErrorCase {
                try EnumCaseDeclSyntax("case error(Error)")
            }

            if let transitionVariable = input.transitionVariable {
                try transitionVariableWithoutErrorCase(transitionVariable.trimmed)
            } else {
                try VariableDeclSyntax("\(raw: access) var transition: Transition") {
                    functionBodyStatement("return .none")
                }
            }

            if hasCancelCase {
                try VariableDeclSyntax(
                    """
                    \(raw: access) var isCancel: Bool {
                        if case .cancel = self {
                            return true
                        } else {
                            return false
                        }
                    }
                    """
                )
            }

            if hasErrorCase {
                try VariableDeclSyntax(
                    """
                    \(raw: access) var isError: Bool {
                        if case .error = self {
                            return true
                        } else {
                            return false
                        }
                    }
                    """
                )
            }
        }
    }

    static func generatedActionFunctions(
        from input: StatefulInput,
        context: some MacroExpansionContext,
        access: String
    ) throws -> [GeneratedActionFunction] {
        var functions: [GeneratedActionFunction] = []

        if input.hasErrorAction {
            try functions.append(actionFunction(
                signature: "\(access) func error(_ error: Error)",
                body: ["core.send(\\.error, error)"]
            ))
            try functions.append(actionFunction(
                signature: "\(access) func error(_ error: Error) async",
                body: ["try? await core.send(\\.error, error)"]
            ))
        }

        let cancelAccess = input.hasCancelAction ? access : "private"
        try functions.append(actionFunction(
            signature: "\(cancelAccess) func cancel()",
            body: ["core.cancelAll()", input.hasCancelAction ? "core.send(\\.cancel)" : nil].compactMap { $0 }
        ))
        try functions.append(actionFunction(
            signature: "\(cancelAccess) func cancel() async",
            body: ["core.cancelAll()", input.hasCancelAction ? "try? await core.send(\\.cancel)" : nil].compactMap { $0 }
        ))

        for caseDecl in input.actionCases where !caseDecl.hasCase(named: "error") && !caseDecl.hasCase(named: "cancel") {
            for element in caseDecl.elements {
                let actionCase = actionCase(from: element, access: access)

                if input.existingFunctionNames.contains(actionCase.name) {
                    context.diagnose(Diagnostic(
                        node: Syntax(element.name),
                        message: ActionFunctionConflictError(functionName: actionCase.name)
                    ))
                    continue
                }

                let sendCall = sendCall(for: actionCase, includeBackground: false)
                try functions.append(actionFunction(
                    signature: functionSignature(for: actionCase, isAsync: false),
                    body: ["core.\(sendCall)"],
                    backgroundBody: actionCase.isBackgroundEligible ? [backgroundSendBody(for: actionCase, isAsync: false)] : nil
                ))
                try functions.append(actionFunction(
                    signature: functionSignature(for: actionCase, isAsync: true),
                    body: ["try? await core.\(sendCall)"],
                    backgroundBody: actionCase.isBackgroundEligible ? [backgroundSendBody(for: actionCase, isAsync: true)] : nil
                ))
            }
        }

        return functions
    }

    static func actionCase(from element: EnumCaseElementSyntax, access: String) -> ActionCase {
        let name = element.name.text
        let functionAccess = name.starts(with: "_") ? "private" : access
        var generatedArgIndex = 1

        let payloads = element.parameterClause?.parameters.map { parameter -> ActionPayload in
            if let secondName = parameter.secondName {
                return ActionPayload(
                    internalName: secondName.text,
                    signature: FunctionParameterSyntax(
                        firstName: parameter.firstName ?? .wildcardToken(),
                        secondName: secondName,
                        colon: .colonToken(trailingTrivia: .space),
                        type: parameter.type
                    )
                )
            }

            if let firstName = parameter.firstName, firstName.text != "_" {
                return ActionPayload(
                    internalName: firstName.text,
                    signature: FunctionParameterSyntax(
                        firstName: firstName,
                        colon: .colonToken(trailingTrivia: .space),
                        type: parameter.type
                    )
                )
            }

            defer { generatedArgIndex += 1 }
            let internalName = "arg\(generatedArgIndex)"
            return ActionPayload(
                internalName: internalName,
                signature: FunctionParameterSyntax(
                    firstName: .wildcardToken(trailingTrivia: .space),
                    secondName: .identifier(internalName),
                    colon: .colonToken(trailingTrivia: .space),
                    type: parameter.type
                )
            )
        } ?? []

        return ActionCase(name: name, access: functionAccess, payloads: payloads)
    }

    static func functionSignature(for actionCase: ActionCase, isAsync: Bool) -> String {
        let parameters = actionCase.payloads.map(\.signature.trimmedDescription).joined(separator: ", ")
        let asyncSuffix = isAsync ? " async" : ""
        return "\(actionCase.access) func \(actionCase.name)(\(parameters))\(asyncSuffix)"
    }

    private static func actionFunction(
        signature: String,
        body: [String],
        backgroundBody: [String]? = nil
    ) throws -> GeneratedActionFunction {
        let declaration = try FunctionDeclSyntax("\(raw: functionSource(signature: signature, body: body))")

        let backgroundDeclaration: FunctionDeclSyntax?
        if let backgroundBody {
            backgroundDeclaration = try FunctionDeclSyntax("\(raw: functionSource(signature: signature, body: backgroundBody))")
        } else {
            backgroundDeclaration = nil
        }

        return GeneratedActionFunction(
            declaration: declaration,
            backgroundDeclaration: backgroundDeclaration
        )
    }

    private static func transitionVariableWithoutErrorCase(_ transitionVariable: VariableDeclSyntax) throws -> VariableDeclSyntax {
        let switchStmt: SwitchExprSyntax?
        if let accessorBlock = transitionVariable.bindings.first?.accessorBlock {
            switch accessorBlock.accessors {
            case let .getter(codeBlock):
                switchStmt = codeBlock.first.flatMap(switchExpression)
            case let .accessors(accessorList):
                switchStmt = accessorList
                    .first { $0.accessorSpecifier.text == "get" }?
                    .body?.statements.first.flatMap(switchExpression)
            }
        } else {
            switchStmt = nil
        }

        guard let switchStmt else {
            if let switchSource = transitionSwitchSource(from: transitionVariable.trimmedDescription) {
                return try VariableDeclSyntax(
                    """
                    var transition: Transition {
                    \(raw: switchSource.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }
                        .joined(separator: "\n"))
                    }
                    """
                )
            }
            return transitionVariable
        }

        let cases = switchStmt.cases.filter { switchCase in
            guard let label = switchCase.as(SwitchCaseSyntax.self)?.label.as(SwitchCaseLabelSyntax.self) else {
                return true
            }

            return !label.caseItems.contains { item in
                item.pattern.tokens(viewMode: .sourceAccurate).contains { $0.text == "error" }
            }
        }

        let switchSource = normalizedMultilineSource(switchStmt.with(\.cases, cases).trimmedDescription)
        return try VariableDeclSyntax(
            """
            var transition: Transition {
            \(raw: switchSource.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n"))
            }
            """
        )
    }

    private static func switchExpression(in item: CodeBlockItemSyntax) -> SwitchExprSyntax? {
        item.item.as(SwitchExprSyntax.self)
            ?? item.item.as(ExprSyntax.self)?.as(SwitchExprSyntax.self)
    }

    private static func normalizedMultilineSource(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indentation = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: \.isWhitespace).count }
            .min() ?? 0
        return lines
            .map { line in
                line.dropFirst(min(indentation, line.count)).description
            }
            .joined(separator: "\n")
    }

    private static func transitionSwitchSource(from source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let switchIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("switch ") }) else {
            return nil
        }

        var switchLines: [String] = []
        var braceDepth = 0
        for line in lines[switchIndex...] {
            switchLines.append(line)
            braceDepth += line.filter { $0 == "{" }.count
            braceDepth -= line.filter { $0 == "}" }.count
            if !switchLines.isEmpty, braceDepth == 0 {
                break
            }
        }

        var filteredLines: [String] = []
        var skippingErrorCase = false
        for line in switchLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("case .error") {
                skippingErrorCase = true
                continue
            }
            if skippingErrorCase, trimmed.hasPrefix("case ") || trimmed.hasPrefix("default:") || trimmed == "}" {
                skippingErrorCase = false
            }
            if !skippingErrorCase {
                filteredLines.append(line)
            }
        }

        return normalizedMultilineSource(filteredLines.joined(separator: "\n"))
    }

    private static func coreProperty(addFunctionStmts: [CodeBlockItemSyntax]) throws -> DeclSyntax {
        var lines = [
            "lazy var core: _StateCore = {",
            "    let core = _StateCore()",
        ]
        lines.append(contentsOf: addFunctionStmts.flatMap { item in
            item.description
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    " + String($0) }
        })
        lines.append(contentsOf: [
            "    setupPublisherAssignments(core: core)",
            "    return core",
            "}()",
        ])

        return try DeclSyntax(VariableDeclSyntax("\(raw: lines.joined(separator: "\n"))"))
    }

    private static func publishedProperties(
        stateEnumName: String,
        hasBackgroundStateType: Bool,
        hasEventType: Bool,
        hasError: Bool,
        access: String
    ) -> [DeclSyntax] {
        var declarations: [DeclSyntax] = []

        if hasBackgroundStateType {
            declarations.append("""
            @Published
            \(raw: access) var background: _BackgroundActions = .init(core: nil, states: [])
            """)
        }

        if hasError {
            declarations.append("""
            @Published \(raw: access) var error: Error? = nil
            """)
        }

        declarations.append("""
        @Published \(raw: access) var state: \(raw: stateEnumName) = .initial
        """)
        declarations.append("""
        \(raw: access) var actions: EventPublisher<_Action> {
            core.actionPublisher
        }
        """)

        if hasEventType {
            declarations.append("""
            \(raw: access) var events: EventPublisher<_Event> {
                core.eventPublisher
            }
            """)
        }

        return declarations
    }

    private static func publisherAssignments(hasError: Bool, hasBackgroundState: Bool) throws -> DeclSyntax {
        var body = [
            """
            core.$state
                .receive(on: DispatchQueue.main)
                .assign(to: &self.$state)
            """,
        ]

        if hasError {
            body.append(
                """
                core.$error
                    .receive(on: DispatchQueue.main)
                    .assign(to: &self.$error)
                """
            )
        }

        if hasBackgroundState {
            body.append(
                """
                core.$backgroundStates
                    .receive(on: DispatchQueue.main)
                    .map { [weak self] newValue -> _BackgroundActions? in
                        return _BackgroundActions.init(
                            core: self?.core,
                            states: newValue
                        )
                    }
                    .compactMap({ $0 })
                    .assign(to: &self.$background)
                """
            )
        }

        return try DeclSyntax(
            FunctionDeclSyntax("\(raw: functionSource(signature: "private func setupPublisherAssignments(core: _StateCore)", body: body))")
        )
    }

    private static func backgroundActions(
        actionFunctions: [GeneratedActionFunction],
        conformances: [String],
        access: String
    ) throws -> DeclSyntax {
        let conformanceClause = conformances.isEmpty ? "" : ": " + conformances.joined(separator: ", ")
        let initializerSource = """
        init(
            core: _StateCore?,
            states: Set<_BackgroundState> = []
        ) {
            self.core = core
            self.states = states
        }
        """
        return try DeclSyntax(
            StructDeclSyntax("@MainActor\n\(raw: access) struct _BackgroundActions\(raw: conformanceClause)") {
                try VariableDeclSyntax("\(raw: access) let states: Set<_BackgroundState>")

                try FunctionDeclSyntax(
                    "\(raw: functionSource(signature: "\(access) func `is`(_ backgroundState: _BackgroundState) -> Bool", body: ["states.contains(backgroundState)"]))"
                )

                try VariableDeclSyntax("private let core: _StateCore?")

                DeclSyntax(stringLiteral: initializerSource)

                for backgroundFunction in actionFunctions.compactMap(\.backgroundDeclaration) {
                    backgroundFunction
                }
            }
        )
    }
}
