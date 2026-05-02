import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

extension StatefulMacro {
    static func makeInput(
        of node: AttributeSyntax,
        in declaration: some DeclGroupSyntax,
        context: some MacroExpansionContext
    ) throws -> StatefulInput {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: Syntax(node), message: StatefulMacroError.invalidStatefulTarget))
            throw StatefulMacroError.invalidStatefulTarget
        }

        var actionEnum: EnumDeclSyntax?
        var stateEnum: EnumDeclSyntax?
        var eventEnum: EnumDeclSyntax?
        var backgroundStateEnum: EnumDeclSyntax?
        var existingFunctionNames = Set<String>()
        var functionRegistrations: [FunctionRegistration] = []

        for member in classDecl.memberBlock.members {
            if let enumDecl = member.decl.as(EnumDeclSyntax.self) {
                switch enumDecl.name.text {
                case "Action":
                    actionEnum = enumDecl
                case "State":
                    stateEnum = enumDecl
                case "Event":
                    eventEnum = enumDecl
                case "BackgroundState":
                    backgroundStateEnum = enumDecl
                default:
                    break
                }
                continue
            }

            guard let functionDecl = member.decl.as(FunctionDeclSyntax.self) else {
                continue
            }

            existingFunctionNames.insert(functionDecl.name.text)

            if let registration = functionRegistration(from: functionDecl) {
                functionRegistrations.append(registration)
            }
        }

        let actionCases = actionEnum?.memberBlock.members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) } ?? []

        return StatefulInput(
            access: accessLevel(from: classDecl),
            conformances: conformances(from: node),
            actionEnum: actionEnum,
            actionEnumIsCasePathable: actionEnum?.attributes.contains(where: isCasePathableAttribute) ?? false,
            stateEnum: stateEnum,
            eventEnum: eventEnum,
            backgroundStateEnum: backgroundStateEnum,
            existingFunctionNames: existingFunctionNames,
            registeredFunctions: functionRegistrations,
            actionCases: actionCases,
            transitionVariable: actionEnum?.memberBlock.members
                .compactMap { $0.decl.as(VariableDeclSyntax.self) }
                .first(where: isTransitionVariable),
            hasErrorAction: actionCases.contains { $0.hasCase(named: "error") },
            hasCancelAction: actionCases.contains { $0.hasCase(named: "cancel") }
        )
    }

    static func actionCaseProperty(in node: AttributeSyntax) -> KeyPathPropertyComponentSyntax? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              let firstArgument = arguments.first,
              let keyPath = firstArgument.expression.as(KeyPathExprSyntax.self),
              let lastComponent = keyPath.components.last,
              let property = lastComponent.component.as(KeyPathPropertyComponentSyntax.self)
        else {
            return nil
        }

        return property
    }

    static func hasAttribute(named name: String, in attributes: AttributeListSyntax) -> Bool {
        attribute(named: name, in: attributes) != nil
    }

    static func accessLevel(from declaration: some DeclGroupSyntax) -> String {
        let accessLevel = declaration.modifiers.first {
            $0.name.tokenKind == .keyword(.public) ||
                $0.name.tokenKind == .keyword(.internal) ||
                $0.name.tokenKind == .keyword(.fileprivate) ||
                $0.name.tokenKind == .keyword(.private)
        }?.name.text ?? "internal"

        return (accessLevel == "private" || accessLevel == "fileprivate") ? "internal" : accessLevel
    }

    private static func conformances(from node: AttributeSyntax) -> [String] {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              let conformancesArgument = arguments.first(where: { $0.label?.text == "conformances" }),
              let arrayExpr = conformancesArgument.expression.as(ArrayExprSyntax.self)
        else {
            return []
        }

        return arrayExpr.elements.compactMap { conformanceName(from: $0.expression) }
    }

    private static func conformanceName(from expression: ExprSyntax) -> String? {
        if let memberAccess = expression.as(MemberAccessExprSyntax.self),
           memberAccess.declName.baseName.text == "self"
        {
            return memberAccess.base?.trimmedDescription
        }

        if let declReference = expression.as(DeclReferenceExprSyntax.self) {
            return declReference.baseName.text
        }

        return expression.trimmedDescription.replacingOccurrences(of: ".self", with: "")
    }

    private static func isCasePathableAttribute(_ attr: AttributeListSyntax.Element) -> Bool {
        attr.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "CasePathable"
    }

    private static func isTransitionVariable(_ varDecl: VariableDeclSyntax) -> Bool {
        varDecl.bindings.contains {
            $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "transition"
        }
    }

    private static func functionRegistration(from funcDecl: FunctionDeclSyntax) -> FunctionRegistration? {
        guard let arguments = attribute(named: "Function", in: funcDecl.attributes)?.arguments?.as(LabeledExprListSyntax.self),
              let keyPath = arguments.first?.expression.as(KeyPathExprSyntax.self),
              let actionCasePath = keyPath.components.last,
              case .property = actionCasePath.component
        else {
            return nil
        }

        return FunctionRegistration(
            casePathComponent: actionCasePath,
            functionName: funcDecl.name.text,
            parameterNames: funcDecl.signature.parameterClause.parameters.map {
                $0.secondName?.text ?? $0.firstName.text
            },
            isAsync: funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil,
            isThrowing: funcDecl.signature.effectSpecifiers?.throwsClause?.throwsSpecifier != nil
        )
    }

    private static func attribute(named name: String, in attributes: AttributeListSyntax) -> AttributeSyntax? {
        attributes.compactMap { $0.as(AttributeSyntax.self) }
            .first { $0.attributeName.as(IdentifierTypeSyntax.self)?.name.text == name }
    }
}
