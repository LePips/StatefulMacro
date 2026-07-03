// TODO: error catcher
//       - catch errors, rethrow or ignore

public struct StateTransition<
    StateType,
    BackgroundStateType: Hashable
> {

    public enum RepeatBehavior {
        case cancel
        case ignore
    }

    var intermediate: StateType?
    var destination: StateType?
    var background: BackgroundStateType?
    var requiredStates: [StateType]?
    var invalidStates: [StateType]?
    var repeatBehavior: RepeatBehavior = .ignore
    var goToStartOnCompletion: Bool = false
    var debounce: Double?

    var `catch`: ((Error) async throws -> Void)?

    var isNone: Bool {
        intermediate == nil && destination == nil && background == nil
    }

    var isBackground: Bool {
        intermediate == nil && destination == nil && background != nil
    }
}

// MARK: - none

public extension StateTransition {

    static var none: Self {
        .init()
    }
}

// MARK: - to

public extension StateTransition {

    static func to(
        _ destination: StateType
    ) -> Self {
        .init(
            destination: destination
        )
    }

    static func to(
        _ intermediate: StateType,
        then destination: StateType
    ) -> Self {
        .init(
            intermediate: intermediate,
            destination: destination
        )
    }
}

// MARK: - loop

public extension StateTransition {

    static func loop(
        _ intermediate: StateType
    ) -> Self {
        .init(
            intermediate: intermediate,
            goToStartOnCompletion: true
        )
    }
}

// MARK: - background

public extension StateTransition {

    static func background(
        _ state: BackgroundStateType
    ) -> Self {
        .init(
            background: state
        )
    }
}

// MARK: - whenBackground

public extension StateTransition {

    func whenBackground(
        _ background: BackgroundStateType
    ) -> Self {
        var copy = self
        copy.background = background
        return copy
    }
}

// MARK: - required

public extension StateTransition {

    func required(
        _ states: [StateType]
    ) -> Self {
        var copy = self
        copy.requiredStates = states
        return copy
    }

    func required(
        _ states: StateType...
    ) -> Self {
        required(states)
    }
}

// MARK: - invalid

public extension StateTransition {

    func invalid(
        _ states: [StateType]
    ) -> Self {
        var copy = self
        copy.invalidStates = states
        return copy
    }

    func invalid(
        _ states: StateType...
    ) -> Self {
        invalid(states)
    }
}

// MARK: - repeat

public extension StateTransition {

    func onRepeat(
        _ behavior: RepeatBehavior
    ) -> Self {
        var copy = self
        copy.repeatBehavior = behavior
        return copy
    }

    /// - Important: Experimental
    func _debounce(_ seconds: Double) -> Self {
        var copy = self
        copy.debounce = seconds
        return copy
    }
}

// MARK: - Error

public extension StateTransition {

    func `catch`(
        _ catch: @escaping (Error) async throws -> Void
    ) -> Self {
        var copy = self
        copy.catch = `catch`
        return copy
    }
}
