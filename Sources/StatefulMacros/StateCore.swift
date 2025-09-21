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
    let goToStartOnCompletion: Bool

    var isBackground: Bool {
        start == nil && final == nil && background != nil
    }

    fileprivate init(
        start: StateType? = nil,
        final: StateType? = nil,
        background: BackgroundStateType? = nil,
        goToStartOnCompletion: Bool = false
    ) {
        self.start = start
        self.final = final
        self.background = background
        self.goToStartOnCompletion = goToStartOnCompletion
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

    public static func loop(
        _ state: StateType
    ) -> Self {
        .init(
            start: state,
            final: nil,
            background: nil,
            goToStartOnCompletion: true
        )
    }

    public static func to(
        _ start: StateType,
        whenBackground background: BackgroundStateType
    ) -> Self {
        .init(
            start: start,
            final: nil,
            background: background
        )
    }

    public static func to(
        _ start: StateType,
        then final: StateType,
        whenBackground background: BackgroundStateType
    ) -> Self {
        .init(
            start: start,
            final: final,
            background: background
        )
    }

    public static func loop(
        _ state: StateType,
        whenBackground background: BackgroundStateType
    ) -> Self {
        .init(
            start: state,
            final: nil,
            background: background,
            goToStartOnCompletion: true
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
    public typealias _StateTransition = StateTransition<StateType, ActionType.BackgroundStateType>

    @Published
    public private(set) var backgroundStates: Set<ActionType.BackgroundStateType> = []
    @Published
    public private(set) var error: Error? = nil
    @Published
    public private(set) var state: StateType = .initial

    public let eventSubject = EventPublisher<EventType>()

    public init() {}

    private var actionTasks: [CaseKey: Task<Void, Never>] = [:]
    private var functionRegistry: [CaseKey: any _ActionFunctionRegistry] = [:]

    private var currentTransitionAction: CaseKey?

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

    public func error(_ error: Error, startState: StateType? = nil) {

        self.error = error

        if let i = StateType.initial as? WithErrorState {
            let errorState = unpackErrorState(from: i)

            for action in actionTasks {
                action.value.cancel()
            }

            backgroundStates.removeAll()

            state = errorState as! StateType
        } else if let startState {
            state = startState
        }
    }

    // MARK: - sync send

    public func send(
        _ action: CaseKeyPath<ActionType, Void>,
        background: Bool = false
    ) {
        send(
            action,
            (),
            background: background
        )
    }

    public func send<S: Sendable>(
        _ action: CaseKeyPath<ActionType, S>,
        _ payload: S,
        background: Bool = false
    ) {
        let newTask = Task {
            await send(
                action,
                payload,
                background: background
            )
        }

        actionTasks[action.hashValue] = newTask
    }

    // MARK: - async send

    public func send(
        _ action: CaseKeyPath<ActionType, Void>,
        background: Bool = false
    ) async {
        await send(
            action,
            (),
            background: background
        )
    }

    @MainActor
    public func send<S: Sendable>(
        _ action: CaseKeyPath<ActionType, S>,
        _ payload: S,
        background: Bool = false
    ) async {
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
                payload: payload,
                background: background
            )
        }

        actionTasks[action.hashValue] = newTask

        await newTask.value
    }

    private func _run<S: Sendable>(
        extractedAction: ActionType,
        action: CaseKeyPath<ActionType, S>,
        payload: S,
        background: Bool = false
    ) async {
        guard let register = functionRegistry[action.hashValue] as? ActionFunctionRegistry<S> else {
            assertionFailure("No handlers registered for action: \(action)")
            return
        }

        let transition = extractedAction.transition

        if !transition.isBackground, !background {
            guard currentTransitionAction == nil else {
                assertionFailure(
                    "Cannot start a new transition action while another transition action is in progress",
                )
                return
            }
            currentTransitionAction = action.hashValue
        }

        let finalState: StateType? = {
            guard !background else {
                return nil
            }

            if transition.goToStartOnCompletion {
                return self.state
            } else {
                return transition.final
            }
        }()

        let startState: StateType? = transition.start

        if let startState, !background {
            await MainActor.run {
                self.state = startState
            }
        }

        let backgroundState = transition.background

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

        if !transition.isBackground {
            self.currentTransitionAction = nil
        }

        if let _error {
            self.error(
                _error,
                startState: startState
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
