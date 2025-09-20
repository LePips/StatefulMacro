import CasePaths
import Combine
import Foundation

// TODO: need to protect against multiple actions that can change the state
//       - only have one action that can change the state at a time
//       - cancel behavior
//       - transitions require start state
//       - build graph on macro expansion and verify?
// TODO: - when error occurs but there is no error state
//       - go to starting state, final state

// TODO: implement
enum StateTransitionTaskRepeatBehavior {
    case cancel
    case wait(count: Int)
}

public protocol CoreState {
    static var initial: Self { get }
}

public protocol WithErrorState: CoreState {
    static var error: Self { get }
}

public protocol StateTransitional {
    associatedtype BackgroundStateType: Hashable = Never
    associatedtype StateType: CoreState

    typealias Transition = StateTransition<StateType, BackgroundStateType>

    var transition: Transition { get }
}

public protocol StateAction: StateTransitional, CasePathIterable, Equatable {}

public protocol WithCancelAction: StateAction {
    static var cancel: Self { get }
}

public protocol WithErrorEvent: Equatable {}

public struct StateTransition<
    StateType,
    BackgroundStateType: Hashable
> {
    let start: StateType?
    let final: StateType?
    let background: BackgroundStateType?
    let goToFinalOnError: Bool

    private init(
        start: StateType? = nil,
        final: StateType? = nil,
        background: BackgroundStateType? = nil,
        goToFinalOnError: Bool = false
    ) {
        self.start = start
        self.final = final
        self.background = background
        self.goToFinalOnError = goToFinalOnError
    }

    public static var identity: Self {
        .init(
            start: nil,
            final: nil,
            background: nil
        )
    }

    public static func to(
        _ start: StateType
    ) -> Self {
        .init(
            start: start,
            final: nil,
            background: nil
        )
    }

    public static func to(
        _ start: StateType,
        then final: StateType
    ) -> Self {
        .init(
            start: start,
            final: final,
            background: nil
        )
    }

    // TODO: remove, see comment above about error handling

    public static func to(
        _ start: StateType,
        thenWithError final: StateType
    ) -> Self {
        .init(
            start: start,
            final: final,
            background: nil,
            goToFinalOnError: true
        )
    }

    public static func background(
        _ state: BackgroundStateType
    ) -> Self {
        .init(
            start: nil,
            final: nil,
            background: state
        )
    }

    public func mapState<NewStateType>(_ transform: (StateType) -> NewStateType) -> StateTransition<NewStateType, BackgroundStateType> {
        .init(
            start: start.map(transform),
            final: final.map(transform),
            background: background
        )
    }

    public func mapBackground<NewBackgroundStateType: Hashable>(_ transform: (BackgroundStateType) -> NewBackgroundStateType)
    -> StateTransition<StateType, NewBackgroundStateType> {
        .init(
            start: start,
            final: final,
            background: background.map(transform)
        )
    }
}

protocol _ActionFunctionRegistry {
    associatedtype Payload: Sendable
    mutating func addFunction(_ handler: @escaping (Payload) async throws -> Void)
}

public struct ActionFunctionRegistry<Payload>: _ActionFunctionRegistry {
    var functions: [(Payload) async throws -> Void] = []

    mutating func addFunction(_ function: @escaping (Payload) async throws -> Void) {
        functions.append(function)
    }
}

@MainActor
public class StateCore<
    StateType: CoreState,
    ActionType: StateAction,
    EventType
>: ObservableObject where ActionType.StateType == StateType {
    typealias CaseKey = Int

    @Published
    public private(set) var backgroundStates: Set<ActionType.BackgroundStateType> = []
    @Published
    public private(set) var error: Error? = nil
    @Published
    public private(set) var state: StateType = .initial

    public let eventSubject = EventPublisher<EventType>()

    public init() {}

    private var functionRegistry: [CaseKey: any _ActionFunctionRegistry] = [:]
    private var actionTasks: [CaseKey: Task<Void, Never>] = [:]

    private func unpackErrorState<S: WithErrorState>(from _: S) -> S {
        .error
    }

    private func isCancelAction<A: WithCancelAction>(from a: A) -> Bool {
        a == A.cancel
    }

    private var shouldRespondToError: Bool {
        let hasErrorState = StateType.self is WithErrorState.Type
        let hasErrorEvent = EventType.self is any WithErrorEvent.Type

        return hasErrorState || hasErrorEvent
    }

    public func addFunction<S>(
        for action: CaseKeyPath<ActionType, S>,
        function: @escaping (S) async throws -> Void
    ) {
        var registry = (functionRegistry[action.hashValue] as? ActionFunctionRegistry<S>) ?? .init()
        registry.addFunction(function)
        functionRegistry[action.hashValue] = registry
    }

    public func error(_ error: Error, finalState: StateType? = nil) {

        self.error = error

        if let i = StateType.initial as? WithErrorState {
            let errorState = unpackErrorState(from: i)

            for action in actionTasks {
                action.value.cancel()
            }

            backgroundStates.removeAll()

            state = errorState as! StateType
        } else if let finalState {
            state = finalState
        }
    }

    // MARK: - sync send

    public func send(_ action: CaseKeyPath<ActionType, Void>) {
        send(action, ())
    }

    public func send<S: Sendable>(_ action: CaseKeyPath<ActionType, S>, _ payload: S) {
        let newTask = Task {
            await send(action, payload)
        }

        actionTasks[action.hashValue] = newTask
    }

    // MARK: - async send

    public func send(_ action: CaseKeyPath<ActionType, Void>) async {
        await send(action, ())
    }

    @MainActor
    public func send<S: Sendable>(_ action: CaseKeyPath<ActionType, S>, _ payload: S) async {
        let extractedAction = action(payload)

        // MARK: - cancel

        if let cancelActionType = extractedAction as? any WithCancelAction,
           isCancelAction(from: cancelActionType)
        {
            for task in actionTasks.values {
                task.cancel()
            }

            await MainActor.run {
                backgroundStates.removeAll()
            }

            if let newState = extractedAction.transition.start {
                await MainActor.run {
                    self.state = newState
                }
            }

            return
        }

        let newTask = Task {
            await _run(
                extractedAction: extractedAction,
                action: action,
                payload: payload
            )
        }

        actionTasks[action.hashValue] = newTask

        await newTask.value
    }

    private func _run<S: Sendable>(
        extractedAction: ActionType,
        action: CaseKeyPath<ActionType, S>,
        payload: S
    ) async {
        guard let register = functionRegistry[action.hashValue] as? ActionFunctionRegistry<S> else {
            assertionFailure("No handlers registered for action: \(action)")
            return
        }

        if let newState = extractedAction.transition.start {
            await MainActor.run {
                self.state = newState
            }
        }
        let finalState = extractedAction.transition.final

        let backgroundState = extractedAction.transition.background

        if let backgroundState {
            await MainActor.run {
                _ = self.backgroundStates.insert(backgroundState)
            }
        }

        var _error: Error? = nil

        do {
            try await withThrowingTaskGroup { group in
                for handler in register.functions {
                    nonisolated(unsafe) let h = handler
                    let op = { @Sendable in try await h(payload) }

                    group.addTask {
                        try await op()
                    }
                }

                try await group.waitForAll()
            }
        } catch is CancellationError {
            // cancels are handled above
            return
        } catch {
            _error = error
        }

        if let _error {
            self.error(
                _error,
                finalState: extractedAction.transition.goToFinalOnError ? finalState : nil
            )
        } else if let finalState {
            await MainActor.run {
                self.state = finalState
            }
        }

        if let backgroundState {
            await MainActor.run {
                _ = self.backgroundStates.remove(backgroundState)
            }
        }
    }
}
