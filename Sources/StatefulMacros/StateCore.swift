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
// TODO: way to cancel other actions from within member but not with a cancel action

@MainActor
public class StateCore<
    StateType: CoreState,
    ActionType: StateAction,
    EventType
>: ObservableObject where ActionType.StateType == StateType {
    typealias CaseKey = Int

    public typealias BackgroundStateType = ActionType.BackgroundStateType
    public typealias Transition = StateTransition<StateType, BackgroundStateType>

    @Published
    public private(set) var backgroundStates: Set<BackgroundStateType> = []
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
    private var currentTransition: Transition?
    private var stateBeforeCurrentTransitionAction: StateType?

    private func unpackErrorState<S: WithErrorState>(from _: S) -> S {
        .error
    }

    private func hasErrorState() -> Bool {
        StateType.self is any WithErrorState.Type
    }

    public func cancelAll() {
        for task in actionTasks {
            task.value.cancel()
        }
    }

    public func cancel<S>(action: CaseKeyPath<ActionType, S>) {
        if let task = actionTasks[action.hashValue] {
            task.cancel()
        }
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
        Task {
            await send(
                action,
                payload,
                background: background
            )
        }
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
            // Task.isCancelled should be properly checked within the
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

            if let newState = extractedAction.transition.destination {
                await MainActor.run {
                    self.state = newState
                }
            }

            currentTransitionAction = nil
            stateBeforeCurrentTransitionAction = nil

            return
        }

        let transition: Transition = {
            var _transition = extractedAction.transition

            if _transition.isBackground {
                _transition.intermediate = nil
                _transition.destination = nil
                return _transition
            }

            if _transition.goToStartOnCompletion {
                _transition.destination = self.state
                return _transition
            }

            return _transition
        }()

        if transition.debounce != nil, let cancellable = actionTasks[action.hashValue] {
            cancellable.cancel()
        }

        if !transition.isBackground,
           !transition.isNone,
           !background,
           !isErrorAction(from: extractedAction),
           transition.debounce == nil
        {
            if currentTransitionAction == action.hashValue {
                switch transition.repeatBehavior {
                case .cancel:
                    actionTasks[action.hashValue]?.cancel()
                case .ignore:
                    return
                }
            } else if let currentTransitionAction, currentTransitionAction != action.hashValue {
                #if DEBUG
                print("State warning: A new transition action started while another transition action is in progress!")
                #endif
            }

            currentTransitionAction = action.hashValue
        }

        await _run(
            extractedAction: extractedAction,
            transition: transition,
            action: action,
            payload: payload
        )
    }

    @MainActor
    private func _run<S: Sendable>(
        extractedAction: ActionType,
        transition: Transition,
        action: CaseKeyPath<ActionType, S>,
        payload: S
    ) async {
        let newTask = Task {
            guard let (
                finalState,
                backgroundState,
                functions
            ) = await preAction(
                extractedAction: extractedAction,
                transition: transition,
                action: action
            ) else {
                return
            }

            if let debounce = transition.debounce {
                do {
                    try await Task.sleep(for: .seconds(debounce))
                } catch {
                    return
                }
            }

            guard let error = await actuallyRun(
                functions: functions,
                payload: payload
            ) else {
                await postAction(
                    error: nil,
                    transition: transition,
                    finalState: finalState,
                    backgroundState: backgroundState
                )
                return
            }

            var finalError: Error? = error

            if let handler = transition.catch {
                do {
                    try await handler(error)
                    finalError = nil
                } catch {
                    finalError = error
                }
            }

            await postAction(
                error: finalError,
                transition: transition,
                finalState: finalState,
                backgroundState: backgroundState
            )
        }

        actionTasks[action.hashValue] = newTask

        await newTask.value
    }

    private func actuallyRun<S: Sendable>(
        functions: [(S) async throws -> Void],
        payload: S
    ) async -> Error? {
        do {
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
        } catch is CancellationError {
            // Task was cancelled
        } catch URLError.cancelled {
            // URL request was cancelled
        } catch {
            return error
        }

        return nil
    }

    private func preAction<S>(
        extractedAction: ActionType,
        transition: Transition,
        action: CaseKeyPath<ActionType, S>
    ) async -> (
        finalState: StateType?,
        backgroundState: BackgroundStateType?,
        functions: [(S) async throws -> Void]
    )? {
        guard let register = functionRegistry[action.hashValue] as? ActionFunctionRegistry<S> else {
            assertionFailure("No handlers registered for action: \(extractedAction)")
            return nil
        }

        InvalidStatesCheck: if let invalidStates = transition.invalidStates {
            guard !invalidStates.isEmpty else {
                #if DEBUG
                print("Action Violation: An invalid states array was set for action but was empty!")
                #endif
                break InvalidStatesCheck
            }

            guard !invalidStates.contains(state) else {
                #if DEBUG
                print("Current state: \(state), invalid states: \(invalidStates) for action: \(extractedAction)")
                #endif
                break InvalidStatesCheck
            }
        }

        RequiredStatesCheck: if let requiredStates = transition.requiredStates {
            guard !requiredStates.isEmpty else {
                #if DEBUG
                print("Action Violation: A required states array was set for action but was empty!")
                #endif
                break RequiredStatesCheck
            }

            guard requiredStates.contains(state) else {
                #if DEBUG
                print("Current state: \(state), required states: \(requiredStates) for action: \(extractedAction)")
                #endif
                return nil
            }
        }

        let finalState: StateType? = transition.destination

        stateBeforeCurrentTransitionAction = self.state
        let startState: StateType? = transition.intermediate

        if let startState, state != startState {
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

        return (
            finalState,
            backgroundState,
            register.functions
        )
    }

    private func postAction(
        error: Error?,
        transition: Transition,
        finalState: StateType?,
        backgroundState: BackgroundStateType?
    ) async {
        if !transition.isBackground {
            self.currentTransitionAction = nil
            self.stateBeforeCurrentTransitionAction = nil
        }

        if let error {
            self.set(
                error: error
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
