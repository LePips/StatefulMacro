public struct StateTransition<
    StateType,
    BackgroundStateType: Hashable
> {

    var intermediate: StateType?
    var destination: StateType?
    var background: BackgroundStateType?
    var requiredStates: [StateType]?
    var invalidStates: [StateType]?
    var goToStartOnCompletion: Bool

    var isBackground: Bool {
        intermediate == nil && destination == nil && background != nil
    }

    fileprivate init(
        intermediate: StateType? = nil,
        destination: StateType? = nil,
        background: BackgroundStateType? = nil,
        requiredStates: [StateType]? = nil,
        invalidStates: [StateType]? = nil,
        goToStartOnCompletion: Bool = false
    ) {
        self.intermediate = intermediate
        self.destination = destination
        self.background = background
        self.requiredStates = requiredStates
        self.invalidStates = invalidStates
        self.goToStartOnCompletion = goToStartOnCompletion
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
        _ destination: StateType
    ) -> Self {
        .init(
            destination: destination,
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
