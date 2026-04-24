import SwiftParser
import SwiftSyntax

public enum StatefulGraphExtractor {
    public static func extract(from source: String) throws -> [StatefulTypeGraph] {
        let file = Parser.parse(source: source)
        return StatefulSyntaxExtractor().extract(from: file)
    }

    public static func select(_ graphs: [StatefulTypeGraph], typeName: String?) throws -> StatefulTypeGraph {
        guard !graphs.isEmpty else {
            throw StatefulGraphError.noStatefulTypesFound
        }

        if let typeName {
            guard let graph = graphs.first(where: { $0.typeName == typeName }) else {
                throw StatefulGraphError.typeNotFound(typeName)
            }
            return graph
        }

        guard graphs.count == 1 else {
            throw StatefulGraphError.ambiguousStatefulTypes(graphs.map(\.typeName).sorted())
        }

        return graphs[0]
    }
}

final class StatefulSyntaxExtractor {
    func extract(from file: SourceFileSyntax) -> [StatefulTypeGraph] {
        collectClasses(in: Syntax(file))
            .filter(hasStatefulAttribute)
            .map(graph(from:))
    }

    private func graph(from classDecl: ClassDeclSyntax) -> StatefulTypeGraph {
        let enums = nestedEnums(in: classDecl)
        let states = enumCases(in: enums["State"])
        let backgroundStates = enumCases(in: enums["BackgroundState"])
        let actions = enumCases(in: enums["Action"])
        let registrations = functionRegistrations(in: classDecl)
        let transitions = transitions(in: enums["Action"], actions: actions)

        return StatefulTypeGraph(
            typeName: classDecl.name.text,
            states: states.isEmpty ? ["initial"] : states,
            backgroundStates: backgroundStates,
            actions: actions,
            functionRegistrations: registrations,
            transitions: actions.map { action in
                transitions[action] ?? StatefulActionTransition(action: action, effect: .none)
            }
        )
    }

    private func collectClasses(in syntax: Syntax) -> [ClassDeclSyntax] {
        var classes: [ClassDeclSyntax] = []
        if let classDecl = syntax.as(ClassDeclSyntax.self) {
            classes.append(classDecl)
        }
        for child in syntax.children(viewMode: .sourceAccurate) {
            classes.append(contentsOf: collectClasses(in: child))
        }
        return classes
    }

    private func hasStatefulAttribute(_ classDecl: ClassDeclSyntax) -> Bool {
        classDecl.attributes.contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Stateful"
        }
    }

    private func nestedEnums(in classDecl: ClassDeclSyntax) -> [String: EnumDeclSyntax] {
        var enums: [String: EnumDeclSyntax] = [:]
        for member in classDecl.memberBlock.members {
            guard let enumDecl = member.decl.as(EnumDeclSyntax.self) else {
                continue
            }
            enums[enumDecl.name.text] = enumDecl
        }
        return enums
    }

    private func enumCases(in enumDecl: EnumDeclSyntax?) -> [String] {
        guard let enumDecl else {
            return []
        }

        return enumDecl.memberBlock.members
            .compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
            .flatMap { $0.elements.map(\.name.text) }
    }

    private func functionRegistrations(in classDecl: ClassDeclSyntax) -> [String: [String]] {
        var registrations: [String: [String]] = [:]

        for member in classDecl.memberBlock.members {
            guard let functionDecl = member.decl.as(FunctionDeclSyntax.self) else {
                continue
            }

            for attribute in functionDecl.attributes.compactMap({ $0.as(AttributeSyntax.self) }) {
                guard attribute.attributeName.trimmedDescription == "Function",
                      let action = actionName(fromFunctionAttribute: attribute)
                else {
                    continue
                }

                registrations[action, default: []].append(functionDecl.name.text)
            }
        }

        return registrations.mapValues { $0.sorted() }
    }

    private func actionName(fromFunctionAttribute attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
              let keyPath = arguments.first?.expression.as(KeyPathExprSyntax.self),
              let component = keyPath.components.last?.component.as(KeyPathPropertyComponentSyntax.self)
        else {
            return nil
        }
        return component.declName.baseName.text
    }

    private func transitions(
        in actionEnum: EnumDeclSyntax?,
        actions: [String]
    ) -> [String: StatefulActionTransition] {
        guard let transitionVariable = transitionVariable(in: actionEnum),
              let switchCases = transitionSwitchCases(in: transitionVariable)
        else {
            return [:]
        }

        var transitions: [String: StatefulActionTransition] = [:]
        for switchCase in switchCases.compactMap({ $0.as(SwitchCaseSyntax.self) }) {
            guard let caseLabel = switchCase.label.as(SwitchCaseLabelSyntax.self),
                  let transitionExpression = switchCase.statements.first.flatMap(expression)
            else {
                continue
            }

            let caseActions = caseLabel.caseItems
                .flatMap { StatefulGraphTransitionParser.actionNames(in: $0.pattern) }
                .filter { actions.contains($0) }

            for action in caseActions {
                var transition = StatefulGraphTransitionParser.parseTransitionExpression(transitionExpression)
                transition.action = action
                transitions[action] = transition
            }
        }

        return transitions
    }

    private func transitionVariable(in actionEnum: EnumDeclSyntax?) -> VariableDeclSyntax? {
        actionEnum?.memberBlock.members
            .compactMap { $0.decl.as(VariableDeclSyntax.self) }
            .first { variable in
                variable.bindings.contains {
                    $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "transition"
                }
            }
    }

    private func transitionSwitchCases(in variableDecl: VariableDeclSyntax) -> SwitchCaseListSyntax? {
        guard let accessorBlock = variableDecl.bindings.first?.accessorBlock else {
            return nil
        }

        switch accessorBlock.accessors {
        case let .getter(codeBlock):
            return codeBlock.first.flatMap(switchCases)
        case let .accessors(accessorList):
            return accessorList
                .first { $0.accessorSpecifier.text == "get" }?
                .body?.statements.first.flatMap(switchCases)
        }
    }

    private func switchCases(in item: CodeBlockItemSyntax) -> SwitchCaseListSyntax? {
        if let switchExpression = item.item.as(SwitchExprSyntax.self) {
            return switchExpression.cases
        }
        if let expressionStatement = item.item.as(ExpressionStmtSyntax.self),
           let switchExpression = expressionStatement.expression.as(SwitchExprSyntax.self)
        {
            return switchExpression.cases
        }
        if let expression = item.item.as(ExprSyntax.self)?.as(SwitchExprSyntax.self) {
            return expression.cases
        }
        return item.item.as(ReturnStmtSyntax.self)?.expression?.as(SwitchExprSyntax.self)?.cases
    }

    private func expression(in item: CodeBlockItemSyntax) -> ExprSyntax? {
        if let expressionStatement = item.item.as(ExpressionStmtSyntax.self) {
            return expressionStatement.expression
        }
        if let expression = item.item.as(ExprSyntax.self) {
            return expression
        }
        return item.item.as(ReturnStmtSyntax.self)?.expression
    }
}
