public protocol StateTransitional {
    associatedtype BackgroundStateType: Hashable = Never
    associatedtype StateType: CoreState

    typealias Transition = StateTransition<StateType, BackgroundStateType>

    var transition: Transition { get }
}
