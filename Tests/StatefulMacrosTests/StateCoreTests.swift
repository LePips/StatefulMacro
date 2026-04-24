import CasePaths
import Combine
import Foundation
import StatefulMacros
import Testing

@MainActor
struct StateCoreTests {

    @Test
    func sendRunsRegisteredFunctionPublishesActionAndAppliesTransition() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let observedActions = LockedRecorder<TestAction>()
        let cancellable = core.actionPublisher.sink { observedActions.append($0) }
        defer { cancellable.cancel() }

        let didRun = LockedRecorder<Bool>()
        core.addFunction(for: \.load) {
            didRun.append(true)
        }

        try await core.send(\.load)

        #expect(didRun.snapshot == [true])
        #expect(core.state == .loaded)
        #expect(observedActions.snapshot.count == 1)
        guard case .load = observedActions.snapshot.first else {
            Issue.record("Expected the load action to be published")
            return
        }
    }

    @Test
    func payloadActionsPassPayloadToAllRegisteredFunctions() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let receivedValues = LockedRecorder<Int>()

        core.addFunction(for: \.payload) { value in
            receivedValues.append(value)
        }
        core.addFunction(for: \.payload) { value in
            receivedValues.append(value * 2)
        }

        try await core.send(\.payload, 4)

        #expect(receivedValues.snapshot.sorted() == [4, 8])
    }

    @Test
    func requiredStatesPreventFunctionExecutionAndStateChanges() async {
        let core = StateCore<TestState, TestAction, Never>()
        let didRun = LockedRecorder<Bool>()

        core.addFunction(for: \.requireLoaded) {
            didRun.append(true)
        }

        await expectStateWarning(containing: "required states") {
            try await core.send(\.requireLoaded)
        }

        #expect(didRun.snapshot.isEmpty)
        #expect(core.state == .initial)
    }

    @Test
    func throwingFunctionPublishesErrorAndMovesToErrorState() async {
        let core = StateCore<TestState, TestAction, Never>()

        core.addFunction(for: \.fail) {
            throw TestError.boom
        }

        do {
            try await core.send(\.fail)
            Issue.record("Expected send to throw")
        } catch TestError.boom {
            #expect(core.error as? TestError == .boom)
            #expect(core.state == .error)
        } catch {
            Issue.record("Expected TestError.boom, got \(error)")
        }
    }

    @Test
    func errorActionPublishesErrorAndMovesToErrorState() async {
        let core = StateCore<TestState, TestAction, Never>()

        await expectStateWarning(containing: "No functions registered") {
            try await core.send(\.error, TestError.boom)
        }

        #expect(core.error as? TestError == .boom)
        #expect(core.state == .error)
    }

    @Test
    func backgroundSendSetsTaskLocalAndDoesNotChangeForegroundState() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let sawBackgroundTask = LockedRecorder<Bool>()
        let sawBackgroundState = LockedRecorder<Bool>()

        core.addFunction(for: \.backgroundLoad) { @MainActor in
            sawBackgroundTask.append(StateTask.isBackground)
            sawBackgroundState.append(core.backgroundStates.contains(.syncing))
        }

        try await core.send(\.backgroundLoad, background: true)

        #expect(sawBackgroundTask.snapshot == [true])
        #expect(sawBackgroundState.snapshot == [true])
        #expect(core.state == .initial)
        #expect(core.backgroundStates.isEmpty)
    }

    @Test
    func cancelActionCancelsRunningBackgroundWorkAndClearsBackgroundStates() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let started = LockedRecorder<Bool>()

        core.addFunction(for: \.backgroundLoad) {
            started.append(true)
            try await Task.sleep(for: .seconds(1))
        }

        let task = Task {
            try? await core.send(\.backgroundLoad)
        }

        while started.snapshot.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(core.backgroundStates.contains(.syncing))

        try await core.send(\.cancel)
        await task.value

        #expect(core.backgroundStates.isEmpty)
    }

    @Test
    func loopTransitionReturnsToStartingStateAfterWorkCompletes() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let statesDuringWork = LockedRecorder<TestState>()

        core.addFunction(for: \.loop) { @MainActor in
            statesDuringWork.append(core.state)
        }

        try await core.send(\.loop)

        #expect(statesDuringWork.snapshot == [.loading])
        #expect(core.state == .initial)
    }

    @Test
    func foregroundTransitionWithBackgroundStateClearsBackgroundAfterCompletion() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let observedBackgroundStates = LockedRecorder<Bool>()
        let observedForegroundStates = LockedRecorder<TestState>()

        core.addFunction(for: \.foregroundWithBackground) { @MainActor in
            observedBackgroundStates.append(core.backgroundStates.contains(.syncing))
            observedForegroundStates.append(core.state)
        }

        try await core.send(\.foregroundWithBackground)

        #expect(observedBackgroundStates.snapshot == [true])
        #expect(observedForegroundStates.snapshot == [.loading])
        #expect(core.backgroundStates.isEmpty)
        #expect(core.state == .loaded)
    }

    @Test
    func invalidStatesPreventFunctionExecutionAndStateChanges() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let observedActions = LockedRecorder<TestAction>()
        let cancellable = core.actionPublisher.sink { observedActions.append($0) }
        defer { cancellable.cancel() }

        let startedHandlers = LockedRecorder<String>()
        let observedStates = LockedRecorder<TestState>()

        core.addFunction(for: \.invalidWhenLoaded) { @MainActor in
            startedHandlers.append("first")
            observedStates.append(core.state)
        }

        core.addFunction(for: \.invalidWhenLoaded) { @MainActor in
            startedHandlers.append("second")
            observedStates.append(core.state)
        }

        try await core.send(\.invalidWhenLoaded)

        #expect(startedHandlers.snapshot.sorted() == ["first", "second"])
        #expect(observedStates.snapshot == [.loading, .loading])
        #expect(core.state == .loaded)

        await expectStateWarning(containing: "invalid states") {
            try await core.send(\.invalidWhenLoaded)
        }

        #expect(observedActions.snapshot.count == 2)
        #expect(startedHandlers.snapshot.sorted() == ["first", "second"])
        #expect(observedStates.snapshot == [.loading, .loading])
        #expect(core.state == .loaded)
    }

    @Test
    func overlappingForegroundTransitionReportsWarning() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let started = LockedRecorder<Bool>()

        core.addFunction(for: \.load) {
            started.append(true)
            try await Task.sleep(for: .milliseconds(80))
        }

        core.addFunction(for: \.foregroundWithBackground) {}

        let firstSend = Task {
            try await core.send(\.load)
        }

        try await waitUntil {
            started.snapshot == [true]
        }

        await expectStateWarning(containing: "another transition action") {
            try await core.send(\.foregroundWithBackground)
        }

        try await firstSend.value
    }

    @Test
    func repeatedTransitionWithIgnoreDoesNotRunSecondFunction() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let started = LockedRecorder<Bool>()

        core.addFunction(for: \.repeatIgnore) {
            started.append(true)
            try await Task.sleep(for: .milliseconds(80))
        }

        let firstSend = Task {
            try await core.send(\.repeatIgnore)
        }

        try await waitUntil {
            started.snapshot.count == 1
        }

        try await core.send(\.repeatIgnore)
        try await firstSend.value

        #expect(started.snapshot.count == 1)
    }

    @Test
    func repeatedTransitionWithCancelCancelsInFlightFunctionAndRunsReplacement() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let started = LockedRecorder<Int>()
        let completed = LockedRecorder<Int>()
        let cancelled = LockedRecorder<Int>()

        core.addFunction(for: \.repeatCancel) {
            let run = started.snapshot.count + 1
            started.append(run)

            do {
                if run == 1 {
                    try await Task.sleep(for: .seconds(1))
                } else {
                    try await Task.sleep(for: .milliseconds(10))
                }
                completed.append(run)
            } catch {
                cancelled.append(run)
                throw error
            }
        }

        let firstSend = Task {
            try await core.send(\.repeatCancel)
        }

        try await waitUntil {
            started.snapshot == [1]
        }

        let secondSend = Task {
            try await core.send(\.repeatCancel)
        }

        try await waitUntil {
            started.snapshot == [1, 2]
        }

        try await firstSend.value
        try await secondSend.value

        #expect(cancelled.snapshot == [1])
        #expect(completed.snapshot == [2])
    }

    @Test
    func debouncedTransitionOnlyRunsLatestAction() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let receivedPayloads = LockedRecorder<Int>()

        core.addFunction(for: \.debounced) { value in
            receivedPayloads.append(value)
        }

        let firstSend = Task {
            try await core.send(\.debounced, 1)
        }

        try await Task.sleep(for: .milliseconds(10))

        let secondSend = Task {
            try await core.send(\.debounced, 2)
        }

        try await firstSend.value
        try await secondSend.value

        #expect(receivedPayloads.snapshot == [2])
    }

    @Test
    func catchHandlerCanHandleErrorWithoutSettingErrorState() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let caughtErrors = LockedRecorder<TestError>()

        core.addFunction(for: \.catchHandled) { _ in
            throw TestError.boom
        }

        do {
            try await core.send(\.catchHandled, caughtErrors)
            Issue.record("Expected send to throw the original error")
        } catch TestError.boom {
            #expect(caughtErrors.snapshot == [.boom])
            #expect(core.error == nil)
            #expect(core.state == .loaded)
        } catch {
            Issue.record("Expected TestError.boom, got \(error)")
        }
    }

    @Test
    func catchHandlerCanReplaceFinalError() async throws {
        let core = StateCore<TestState, TestAction, Never>()
        let caughtErrors = LockedRecorder<TestError>()

        core.addFunction(for: \.catchRethrown) { _ in
            throw TestError.boom
        }

        do {
            try await core.send(\.catchRethrown, caughtErrors)
            Issue.record("Expected send to throw the original error")
        } catch TestError.boom {
            #expect(caughtErrors.snapshot == [.boom])
            #expect(core.error as? TestError == .handler)
            #expect(core.state == .error)
        } catch {
            Issue.record("Expected TestError.boom, got \(error)")
        }
    }
}

private enum TestState: CoreState, WithErrorState {
    case initial
    case loading
    case loaded
    case error
}

private enum BackgroundState: Hashable {
    case syncing
}

@CasePathable
private enum TestAction: StateAction, WithCancelAction, WithErrorAction {
    typealias StateType = TestState
    typealias BackgroundStateType = BackgroundState

    case load
    case payload(Int)
    case requireLoaded
    case backgroundLoad
    case foregroundWithBackground
    case fail
    case loop
    case invalidWhenLoaded
    case repeatIgnore
    case repeatCancel
    case debounced(Int)
    case catchHandled(LockedRecorder<TestError>)
    case catchRethrown(LockedRecorder<TestError>)
    case cancel
    case error(Error)

    var transition: Transition {
        switch self {
        case .load:
            .to(.loading, then: .loaded)
        case .payload:
            .none
        case .requireLoaded:
            .to(.loaded).required(.loaded)
        case .backgroundLoad:
            .background(.syncing)
        case .foregroundWithBackground:
            .to(.loading, then: .loaded)
                .whenBackground(.syncing)
        case .fail:
            .to(.loading, then: .loaded)
        case .loop:
            .loop(.loading)
        case .invalidWhenLoaded:
            .to(.loading, then: .loaded)
                .invalid(.loaded)
        case .repeatIgnore:
            .to(.loading, then: .loaded)
                .onRepeat(.ignore)
        case .repeatCancel:
            .to(.loading, then: .loaded)
                .onRepeat(.cancel)
        case .debounced:
            .none
                ._debounce(0.05)
        case let .catchHandled(caughtErrors):
            .to(.loading, then: .loaded)
                .catch { error in
                    if let error = error as? TestError {
                        caughtErrors.append(error)
                    }
                }
        case let .catchRethrown(caughtErrors):
            .to(.loading, then: .loaded)
                .catch { error in
                    if let error = error as? TestError {
                        caughtErrors.append(error)
                    }
                    throw TestError.handler
                }
        case .cancel:
            .none
        case .error:
            .none
        }
    }

    var isCancel: Bool {
        if case .cancel = self {
            return true
        }
        return false
    }

    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }
}

private enum TestError: Error, Equatable {
    case boom
    case handler
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    predicate: @escaping @Sendable () -> Bool
) async throws {
    let start = ContinuousClock.now

    while !predicate() {
        if start.duration(to: ContinuousClock.now) > timeout {
            Issue.record("Timed out waiting for condition")
            return
        }

        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func expectStateWarning(
    containing expectedMessage: String,
    _ operation: () async throws -> Void
) async {
    await withKnownIssue {
        do {
            try await operation()
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    } matching: { issue in
        issue.description.contains("State warning:")
            && issue.description.contains(expectedMessage)
    }
}

private final class LockedRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    var snapshot: [Value] {
        lock.withLock {
            values
        }
    }

    func append(_ value: Value) {
        lock.withLock {
            values.append(value)
        }
    }
}
