import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

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

/// Implementation of the `@Stateful` member macro.
public struct StatefulMacro: MemberMacro, ExtensionMacro {
    
    // MARK: - Extension Macro
    
    public static func expansion(
        of _: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let isObservableObject = declaration.inheritanceClause?.inheritedTypes.contains { inherited in
            inherited.type.as(IdentifierTypeSyntax.self)?.name.text == "ObservableObject"
        } ?? false

        guard !isObservableObject else { return [] }

        let observableObjectExtension: DeclSyntax = """
            extension \(type.trimmed): ObservableObject {}
            """

        return [observableObjectExtension.cast(ExtensionDeclSyntax.self)]
    }

    // MARK: - Member Macro
    
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let (actionEnumDecl, isCasePathable) = findStateActionEnums(in: declaration)

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

        let actionEnumName = "_Action"
        let actionEnum = try createActionEnum(
            named: actionEnumName,
            from: stateActionEnums,
            stateEnumName: stateEnumName,
            backgroundStateTypeName: backgroundStateTypeName
        )

        let generatedActionFunctions = try generateActionFunctions(
            from: stateActionEnums,
            in: declaration,
            context: context
        )

        let addFunctionStmts = try processFunctionAttributes(in: declaration, context: context)
        let coreProperty = createCoreProperty(
            stateEnumName: stateEnumName,
            actionEnumName: actionEnumName,
            addFunctionStmts: addFunctionStmts
        )

        let transitionTypeAlias: DeclSyntax = """
            public typealias Transition = StateTransition<\(raw: stateEnumName), \(raw: backgroundStateTypeName)>
            """

        var newDecls: [DeclSyntax] = []
        
        if let backgroundStateEnum {
            newDecls.append(DeclSyntax(backgroundStateEnum))
        }

        newDecls.append(contentsOf: [
            DeclSyntax(stateEnum),
            DeclSyntax(actionEnum),
            transitionTypeAlias,
            coreProperty,
        ])

        newDecls.append(contentsOf: generatedActionFunctions)
        newDecls.append(contentsOf: createPublishedProperties(
            in: declaration,
            stateEnumName: stateEnumName,
            hasErrorState: hasErrorState
        ))
        
        newDecls.append(createPublisherAssignments(hasErrorVariable: hasErrorState))

        if let initDecl = createInitializer(in: declaration, context: context, node: node) {
            newDecls.append(initDecl)
        }

        return newDecls
    }

    // MARK: - Private Helper Functions

    private static func findStateActionEnums(in declaration: some DeclGroupSyntax) -> (actionEnum: EnumDeclSyntax?, isCasePathable: Bool) {
        guard let actionEnum = declaration.memberBlock.members.compactMap({ $0.decl.as(EnumDeclSyntax.self) }).first(where: { $0.name.text == "Action" }) else {
            return (nil, false)
        }

        let isCasePathable = actionEnum.attributes.contains { attr in
            attr.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "CasePathable"
        }

        return (actionEnum, isCasePathable)
    }

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

    private static func handleStateEnum(in declaration: some DeclGroupSyntax, context: some MacroExpansionContext) throws -> (String, EnumDeclSyntax, Bool) {
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

    private static func createActionEnum(named actionEnumName: String, from stateActionEnums: [EnumDeclSyntax], stateEnumName: String, backgroundStateTypeName: String) throws -> EnumDeclSyntax {
        let hasCancelAction = stateActionEnums.flatMap { $0.memberBlock.members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) } }.contains { enumCase in
            enumCase.elements.contains { $0.name.text == "cancel" }
        }

        var actionConformances = ["StateAction"]
        if hasCancelAction {
            actionConformances.append("WithCancelAction")
        }

        let actionCases = stateActionEnums.flatMap { $0.memberBlock.members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) } }.filter { caseDecl in
            !caseDecl.elements.contains { $0.name.text == "error" }
        }

        return try EnumDeclSyntax("@CasePathable public enum \(raw: actionEnumName): \(raw: actionConformances.joined(separator: ", "))") {
            try TypeAliasDeclSyntax("public typealias Transition = StateTransition<\(raw: stateEnumName), \(raw: backgroundStateTypeName)>")

            for enumCase in actionCases {
                enumCase
            }

            let transitionVariable = stateActionEnums.flatMap { $0.memberBlock.members.compactMap { $0.decl.as(VariableDeclSyntax.self) } }.first { varDecl in
                varDecl.bindings.contains { binding in
                    binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "transition"
                }
            }

            if let transitionVariable {
                modifyTransitionVariable(transitionVariable)
            } else {
                try VariableDeclSyntax("public var transition: Transition") {
                    StmtSyntax("return .identity")
                }
            }
        }
    }

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

            let newBinding = transitionVariable.bindings.first?.with(\.accessorBlock, .init(accessors: .getter(CodeBlockItemListSyntax(stringLiteral: newSwitchString))))
            return transitionVariable.with(\.bindings, .init(arrayLiteral: newBinding!))
        }

        return transitionVariable
    }

    private static func generateActionFunctions(from stateActionEnums: [EnumDeclSyntax], in declaration: some DeclGroupSyntax, context: some MacroExpansionContext) throws -> [DeclSyntax] {
        var generatedActionFunctions: [DeclSyntax] = []
        let allCases = stateActionEnums.flatMap { $0.memberBlock.members }.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }

        let hasErrorCase = allCases.contains { caseDecl in
            caseDecl.elements.contains { $0.name.text == "error" }
        }

        if hasErrorCase {
            let errorFunc = try FunctionDeclSyntax("public func error(_ error: Error)") {
                StmtSyntax("\n\tcore.error(error)")
            }
            generatedActionFunctions.append(DeclSyntax(errorFunc))
        }

        let nonErrorCases = allCases.filter { caseDecl in
            !caseDecl.elements.contains { $0.name.text == "error" }
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

                let syncFuncDecl = try FunctionDeclSyntax("public func \(raw: funcName)(\(raw: parameters.joined(separator: ", ")))") {
                    StmtSyntax("\n\tcore.\(raw: sendCall)")
                }
                generatedActionFunctions.append(DeclSyntax(syncFuncDecl))

                let asyncFuncDecl = try FunctionDeclSyntax("public func \(raw: funcName)(\(raw: parameters.joined(separator: ", "))) async ") {
                    StmtSyntax("\n\tawait core.\(raw: sendCall)")
                }
                generatedActionFunctions.append(DeclSyntax(asyncFuncDecl))
            }
        }
        return generatedActionFunctions
    }

    private static func processFunctionAttributes(in declaration: some DeclGroupSyntax, context _: some MacroExpansionContext) throws -> [String] {
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
            addFunctionStmts.append("core.addFunction(for: \\\(actionCasePath), function: self.\(funcName))")
        }
        return addFunctionStmts
    }

    private static func createCoreProperty(stateEnumName: String, actionEnumName: String, addFunctionStmts: [String]) -> DeclSyntax {
        let coreProperty: DeclSyntax =
            """
            private lazy var core: StateCore<\(raw: stateEnumName), \(raw: actionEnumName)> = {
                let core = StateCore<\(raw: stateEnumName), \(raw: actionEnumName)>()
                \(raw: addFunctionStmts.joined(separator: "\n\n"))
                return core
            }()
            """
        return coreProperty
    }

    private static func createPublishedProperties(in declaration: some DeclGroupSyntax, stateEnumName: String, hasErrorState: Bool) -> [DeclSyntax] {
        var newDecls: [DeclSyntax] = []

        let hasPublishedState = declaration.memberBlock.members.contains { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return false }

            let isPublished = varDecl.attributes.contains { attr in
                attr.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Published"
            }

            guard isPublished else { return false }

            guard let binding = varDecl.bindings.first,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  identifier == "state"
            else {
                return false
            }

            guard let type = binding.typeAnnotation?.type.as(IdentifierTypeSyntax.self)?.name.text,
                  type == stateEnumName
            else {
                return false
            }

            return true
        }

        if !hasPublishedState {
            let stateVar: DeclSyntax =
                """
                @Published public var state: \(raw: stateEnumName) = .initial
                """
            newDecls.append(stateVar)
        }

        let hasPublishedError = declaration.memberBlock.members.contains { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return false }

            let isPublished = varDecl.attributes.contains { attr in
                attr.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Published"
            }

            guard isPublished else { return false }

            guard let binding = varDecl.bindings.first,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  identifier == "error"
            else {
                return false
            }

            guard let type = binding.typeAnnotation?.type.as(IdentifierTypeSyntax.self)?.name.text,
                  type == stateEnumName
            else {
                return false
            }

            return true
        }

        if !hasPublishedError, hasErrorState {
            let stateVar: DeclSyntax =
                """
                @Published public var error: Error? = nil
                """
            newDecls.append(stateVar)
        }

        return newDecls
    }
    
    private static func createPublisherAssignments(hasErrorVariable: Bool) -> DeclSyntax {
        let errorAssignment = hasErrorVariable ? """
                \ncore.$error
                    .receive(on: DispatchQueue.main)
                    .assign(to: &self.$error)
                """ : ""
        
        return """
            private func setupPublisherAssignments() {
                core.$state
                    .receive(on: DispatchQueue.main)
                    .assign(to: &self.$state)\(raw: errorAssignment)
            }
            """
    }

    private static func createInitializer(in declaration: some DeclGroupSyntax, context: some MacroExpansionContext, node: AttributeSyntax) -> DeclSyntax? {
        let hasInit = declaration.memberBlock.members.contains { member in
            member.decl.is(InitializerDeclSyntax.self)
        }

        if !hasInit {
            let initDecl: DeclSyntax =
                """
                public init() {
                    setupPublisherAssignments()
                }
                """
            return initDecl
        } else {
            return nil
        }
    }
}
