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

    public let actionPublisher = EventPublisher<ActionType>()
    public let eventPublisher = EventPublisher<EventType>()

    public init() {}

    private var actionTasks: [CaseKey: Task<Void, Never>] = [:]
    private var functionRegistry: [CaseKey: any _ActionFunctionRegistry] = [:]

    private var currentTransitionAction: CaseKey?
    private var stateBeforeCurrentTransitionAction: StateType?

    private func unpackErrorState<S: WithErrorState>(from _: S) -> S {
        .error
    }

    private func hasErrorState() -> Bool {
        StateType.self is any WithErrorState.Type
    }

    private func isCancelAction(
        from a: ActionType
    ) -> Bool {
        if let a = a as? any WithCancelAction {
            return a.isCancel
        }
        return false
    }

    private func isErrorAction(
        from a: ActionType
    ) -> Bool {
        if let a = a as? any WithErrorAction {
            return a.isError
        }
        return false
    }

    func withPossibleErrorAction<S: Sendable>(
        from a: ActionType,
        payload: S,
        withError: (Error) async -> Void
    ) async {
        if let a = a as? any WithErrorAction, a.isError {
            if let e = payload as? any Error {
                await withError(e)
            }
        }
    }

    private var shouldRespondToError: Bool {
        let hasErrorState = StateType.self is any WithErrorState.Type
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

    private func set(error: Error) {

        self.error = error

        if let i = StateType.initial as? any WithErrorState {
            let errorState = unpackErrorState(from: i)

            for action in actionTasks {
                action.value.cancel()
            }

            backgroundStates.removeAll()

            state = errorState as! StateType
            stateBeforeCurrentTransitionAction = nil
        } else if let stateBeforeCurrentTransitionAction {
            state = stateBeforeCurrentTransitionAction
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
        
        actionPublisher.send(extractedAction)

        // MARK: - error

        await withPossibleErrorAction(
            from: extractedAction,
            payload: payload
        ) { error in
            // Note: if error is called from within an action Function,
            // Task.isCancelled must be properly checked within the
            // attached function
            for task in actionTasks.values {
                task.cancel()
            }

            await MainActor.run {
                backgroundStates.removeAll()
            }

            set(error: error)
        }

        // MARK: - cancel

        if isCancelAction(from: extractedAction) {
            for task in actionTasks.values {
                task.cancel()
            }

            await MainActor.run {
                backgroundStates.removeAll()
            }

            if let newState = extractedAction.transition.intermediate {
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
            assertionFailure("No handlers registered for action: \(extractedAction)")
            return
        }

        let transition = extractedAction.transition

        if !transition.isBackground, !background, !isErrorAction(from: extractedAction) {
            guard currentTransitionAction == nil else {
                assertionFailure(
                    "State Violation: Cannot start a new transition action while another transition action is in progress!",
                )
                return
            }
            currentTransitionAction = action.hashValue
        }

        InvalidStatesCheck: if let invalidStates = transition.invalidStates {
            guard !invalidStates.isEmpty else {
                assertionFailure("Action Violation: An invalid sets array was set for action but was empty!")
                break InvalidStatesCheck
            }

            guard !invalidStates.contains(state) else {
                assertionFailure(
                    "State Violation: Current state is in the set of invalid states for action!"
                )
                break InvalidStatesCheck
            }
        }

        RequiredStatesCheck: if let requiredStates = transition.requiredStates {
            guard !requiredStates.isEmpty else {
                assertionFailure("Action Violation: A required sets array was set for action but was empty!")
                break RequiredStatesCheck
            }

            guard requiredStates.contains(state) else {
                assertionFailure(
                    "State Violation: Current state is not in the set of required states for action!"
                )
                break RequiredStatesCheck
            }
        }

        let finalState: StateType? = {
            guard !background else {
                return nil
            }

            if transition.goToStartOnCompletion {
                return self.state
            } else {
                return transition.destination
            }
        }()

        stateBeforeCurrentTransitionAction = self.state
        let startState: StateType? = transition.intermediate

        if let startState, !background {
            await MainActor.run {
                self.state = startState
            }
        }

        let backgroundState = transition.background

        if let backgroundState, transition.isBackground || background {
            await MainActor.run {
                _ = self.backgroundStates.insert(backgroundState)
            }
        }

        var _error: Error? = nil

        do {
            try await runWithGroup(
                functions: register.functions,
                payload: payload
            )
        } catch is CancellationError {
            // cancels are handled above
            if !transition.isBackground {
                currentTransitionAction = nil
                stateBeforeCurrentTransitionAction = nil
            }
            return
        } catch {
            _error = error
        }

        if !transition.isBackground {
            self.currentTransitionAction = nil
            self.stateBeforeCurrentTransitionAction = nil
        }

        if let _error {
            self.set(
                error: _error
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

    private func runWithGroup<S: Sendable>(
        functions: [(S) async throws -> Void],
        payload: S
    ) async throws {
        try await withThrowingTaskGroup { group in
            for handler in functions {
                nonisolated(unsafe) let h = handler
                let op = { @Sendable in try await h(payload) }

                group.addTask {
                    try await op()
                }
            }

            try await group.waitForAll()
        }
    }
}
