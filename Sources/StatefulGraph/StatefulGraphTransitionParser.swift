import SwiftSyntax

enum StatefulGraphTransitionParser {
    static func actionNames(in pattern: PatternSyntax) -> [String] {
        namesAfterDot(in: Syntax(pattern))
    }

    static func parseTransitionExpression(_ expression: ExprSyntax) -> StatefulActionTransition {
        parseTransitionSyntax(Syntax(expression), originalExpression: expression.trimmedDescription)
    }

    private static func parseTransitionSyntax(
        _ syntax: Syntax,
        originalExpression: String
    ) -> StatefulActionTransition {
        if let memberAccess = syntax.as(MemberAccessExprSyntax.self),
           memberAccess.base == nil,
           memberAccess.declName.baseName.text == "none"
        {
            return StatefulActionTransition(action: "", effect: .none)
        }

        guard let functionCall = syntax.as(FunctionCallExprSyntax.self),
              let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self)
        else {
            return StatefulActionTransition(
                action: "",
                effect: .unresolved(originalExpression),
                unresolvedExpression: originalExpression
            )
        }

        let memberName = memberAccess.declName.baseName.text
        if let base = memberAccess.base {
            var transition = parseTransitionSyntax(Syntax(base), originalExpression: originalExpression)
            applyModifier(memberName, call: functionCall, to: &transition)
            return transition
        }

        switch memberName {
        case "to":
            let arguments = Array(functionCall.arguments)
            if arguments.count >= 2,
               arguments[1].label?.text == "then",
               let intermediate = stateName(from: arguments[0].expression),
               let destination = stateName(from: arguments[1].expression)
            {
                return StatefulActionTransition(action: "", effect: .through(intermediate: intermediate, destination: destination))
            }
            if let destination = arguments.first.flatMap({ stateName(from: $0.expression) }) {
                return StatefulActionTransition(action: "", effect: .to(destination: destination))
            }
        case "loop":
            if let intermediate = functionCall.arguments.first.flatMap({ stateName(from: $0.expression) }) {
                return StatefulActionTransition(action: "", effect: .loop(intermediate: intermediate))
            }
        case "background":
            if let backgroundState = functionCall.arguments.first.flatMap({ stateName(from: $0.expression) }) {
                return StatefulActionTransition(action: "", effect: .background(backgroundState))
            }
        default:
            break
        }

        return StatefulActionTransition(
            action: "",
            effect: .unresolved(originalExpression),
            unresolvedExpression: originalExpression
        )
    }

    private static func applyModifier(
        _ memberName: String,
        call: FunctionCallExprSyntax,
        to transition: inout StatefulActionTransition
    ) {
        switch memberName {
        case "whenBackground":
            transition.backgroundState = call.arguments.first.flatMap { stateName(from: $0.expression) }
        case "required":
            let states = call.arguments.flatMap { stateNames(from: $0.expression) }
            if !states.isEmpty {
                transition.source = .required(states)
            }
        case "invalid":
            let states = call.arguments.flatMap { stateNames(from: $0.expression) }
            if !states.isEmpty {
                transition.source = .invalid(states)
            }
        case "onRepeat":
            transition.repeatBehavior = call.arguments.first.flatMap { stateName(from: $0.expression) }
        case "_debounce":
            transition.debounce = call.arguments.first?.expression.trimmedDescription
        case "catch":
            transition.catchesErrors = true
        default:
            transition.effect = .unresolved(call.trimmedDescription)
            transition.unresolvedExpression = call.trimmedDescription
        }
    }

    private static func stateName(from expression: ExprSyntax) -> String? {
        stateNames(from: expression).last
    }

    private static func stateNames(from expression: ExprSyntax) -> [String] {
        if let arrayExpression = expression.as(ArrayExprSyntax.self) {
            return arrayExpression.elements.flatMap { stateNames(from: $0.expression) }
        }
        return namesAfterDot(in: Syntax(expression))
    }

    private static func namesAfterDot(in syntax: Syntax) -> [String] {
        let tokens = syntax.tokens(viewMode: .sourceAccurate).map(\.text)
        var names: [String] = []

        for index in tokens.indices {
            if tokens[index].hasPrefix("."), tokens[index].count > 1 {
                let name = String(tokens[index].dropFirst())
                if name.first?.isLetter == true || name.first == "_" {
                    names.append(name)
                }
                continue
            }

            guard tokens[index] == "." else {
                continue
            }

            let nextIndex = tokens.index(after: index)
            guard nextIndex < tokens.endIndex else {
                continue
            }
            let name = tokens[nextIndex]
            if name.first?.isLetter == true || name.first == "_" {
                names.append(name)
            }
        }

        return names
    }
}
