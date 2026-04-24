public enum StatefulGraphError: Error, CustomStringConvertible, Equatable {
    case typeNotFound(String)
    case noStatefulTypesFound
    case ambiguousStatefulTypes([String])

    public var description: String {
        switch self {
        case let .typeNotFound(typeName):
            return "No @Stateful type named '\(typeName)' was found."
        case .noStatefulTypesFound:
            return "No @Stateful types were found."
        case let .ambiguousStatefulTypes(typeNames):
            return "Multiple @Stateful types were found. Pass --type with one of: \(typeNames.joined(separator: ", "))."
        }
    }
}

public struct StatefulTypeGraph: Equatable {
    public var typeName: String
    public var states: [String]
    public var backgroundStates: [String]
    public var actions: [String]
    public var functionRegistrations: [String: [String]]
    public var transitions: [StatefulActionTransition]

    public init(
        typeName: String,
        states: [String],
        backgroundStates: [String],
        actions: [String],
        functionRegistrations: [String: [String]],
        transitions: [StatefulActionTransition]
    ) {
        self.typeName = typeName
        self.states = states
        self.backgroundStates = backgroundStates
        self.actions = actions
        self.functionRegistrations = functionRegistrations
        self.transitions = transitions
    }
}

public struct StatefulActionTransition: Equatable {
    public var action: String
    public var effect: StatefulTransitionEffect
    public var source: StatefulTransitionSource
    public var backgroundState: String?
    public var repeatBehavior: String?
    public var debounce: String?
    public var catchesErrors: Bool
    public var unresolvedExpression: String?

    public init(
        action: String,
        effect: StatefulTransitionEffect,
        source: StatefulTransitionSource = .anyAllowed,
        backgroundState: String? = nil,
        repeatBehavior: String? = nil,
        debounce: String? = nil,
        catchesErrors: Bool = false,
        unresolvedExpression: String? = nil
    ) {
        self.action = action
        self.effect = effect
        self.source = source
        self.backgroundState = backgroundState
        self.repeatBehavior = repeatBehavior
        self.debounce = debounce
        self.catchesErrors = catchesErrors
        self.unresolvedExpression = unresolvedExpression
    }
}

public enum StatefulTransitionEffect: Equatable {
    case none
    case to(destination: String)
    case through(intermediate: String, destination: String)
    case loop(intermediate: String)
    case background(String)
    case unresolved(String)
}

public enum StatefulTransitionSource: Equatable {
    case anyAllowed
    case required([String])
    case invalid([String])
}
