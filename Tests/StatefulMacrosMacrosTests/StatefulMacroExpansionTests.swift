import MacroTesting
@testable import StatefulMacrosMacros
import Testing

@Suite(
    .macros([
        "Stateful": StatefulMacro.self,
        "Function": FunctionMacro.self,
    ])
)
struct StatefulMacroExpansionTests {

    @Test
    func pluginProvidesStatefulAndFunctionMacros() {
        let macroTypes = Set(StatefulMacrosPlugin().providingMacros.map(ObjectIdentifier.init))

        #expect(macroTypes == [
            ObjectIdentifier(StatefulMacro.self),
            ObjectIdentifier(FunctionMacro.self),
        ])
    }

    @Test
    func minimalStatefulExpansion() {
        assertMacro {
            """
            @Stateful
            final class ViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                }
            }
            """
        } expansion: {
            """
            final class ViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                }

                internal enum _State: CoreState {
                    case initial
                }

                @CasePathable internal enum _Action: StateAction {
                    internal typealias Transition = StateTransition<_State, Never>
                    case refresh
                    internal var transition: Transition {
                        return .none
                    }
                }

                internal typealias Transition = StateTransition<_State, Never>

                internal typealias _StateCore = StateCore<_State, _Action, Never>

                lazy var core: _StateCore = {
                    let core = _StateCore()
                    setupPublisherAssignments(core: core)
                    return core
                }()

                private func cancel() {
                    core.cancelAll()
                }

                private func cancel() async {
                    core.cancelAll()
                }

                internal func refresh() {
                    core.send(\\.refresh)
                }

                internal func refresh() async {
                    try? await core.send(\\.refresh)
                }

                @Published internal var state: _State = .initial

                internal var actions: EventPublisher<_Action> {
                    core.actionPublisher
                }

                private func setupPublisherAssignments(core: _StateCore) {
                    core.$state
                        .receive(on: DispatchQueue.main)
                        .assign(to: &self.$state)
                }
            }
            """
        }
    }

    @Test
    func statefulExpansionWithErrorsEventsBackgroundFunctionsAndPayloads() {
        assertMacro {
            """
            @Stateful(conformances: [WithRefresh.self, WithLoad.self])
            class ViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                    case cancel
                    case error
                    case unnamed(String)
                    case named(id: Int)
                    case pair(String, count: Int)
                    case _privateLoad(String)

                    var transition: Transition {
                        switch self {
                        case .refresh:
                            .to(.loading, then: .content)
                                .whenBackground(.loading)
                        case .error:
                            .none
                        case .cancel, .unnamed, .named, .pair, ._privateLoad:
                            .none
                        }
                    }
                }

                enum BackgroundState {
                    case loading
                }

                enum Event {
                    case started
                    case error
                }

                enum State {
                    case initial
                    case loading
                    case content
                    case error
                }

                @Function(\\Action.Cases.refresh)
                func load() async throws {}

                @Function(\\Action.Cases.unnamed)
                func onUnnamed(_ value: String) {}
            }
            """
        } expansion: {
            """
            class ViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                    case cancel
                    case error
                    case unnamed(String)
                    case named(id: Int)
                    case pair(String, count: Int)
                    case _privateLoad(String)

                    var transition: Transition {
                        switch self {
                        case .refresh:
                            .to(.loading, then: .content)
                                .whenBackground(.loading)
                        case .error:
                            .none
                        case .cancel, .unnamed, .named, .pair, ._privateLoad:
                            .none
                        }
                    }
                }

                enum BackgroundState {
                    case loading
                }

                enum Event {
                    case started
                    case error
                }

                enum State {
                    case initial
                    case loading
                    case content
                    case error
                }
                func load() async throws {}
                func onUnnamed(_ value: String) {}

                internal enum _Event: WithErrorEvent {
                    case started
                }

                internal enum _BackgroundState: Hashable, Sendable {
                    case loading
                }

                internal enum _State: CoreState, WithErrorState {
                    case initial
                    case loading
                    case content
                    case error
                }

                @CasePathable internal enum _Action: StateAction, WithCancelAction, WithErrorAction {
                    internal typealias Transition = StateTransition<_State, _BackgroundState>
                    case refresh
                    case cancel
                    case unnamed(String)
                    case named(id: Int)
                    case pair(String, count: Int)
                    case _privateLoad(String)
                    case error(Error)
                    var transition: Transition {
                        switch self {
                        case .refresh:
                            .to(.loading, then: .content)
                                .whenBackground(.loading)
                        case .cancel, .unnamed, .named, .pair, ._privateLoad:
                            .none
                        }
                    }
                    internal var isCancel: Bool {
                        if case .cancel = self {
                            return true
                        } else {
                            return false
                        }
                    }
                    internal var isError: Bool {
                        if case .error = self {
                            return true
                        } else {
                            return false
                        }
                    }
                }

                internal typealias Transition = StateTransition<_State, _BackgroundState>

                internal typealias _StateCore = StateCore<_State, _Action, _Event>

                lazy var core: _StateCore = {
                    let core = _StateCore()
                    core.addFunction(for: \\.refresh, function: { [weak self] in
                        try await self?.load()
                    })
                    core.addFunction(for: \\.unnamed, function: { [weak self] value in
                        self?.onUnnamed(value)
                    })
                    setupPublisherAssignments(core: core)
                    return core
                }()

                @MainActor
                internal struct _BackgroundActions: WithRefresh, WithLoad {
                    internal let states: Set<_BackgroundState>
                    internal func `is`(_ backgroundState: _BackgroundState) -> Bool {
                        states.contains(backgroundState)
                    }
                    private let core: _StateCore?
                    init(
                        core: _StateCore?,
                        states: Set<_BackgroundState> = []
                    ) {
                        self.core = core
                        self.states = states
                    }
                    internal func refresh() {
                        core?.send(\\.refresh, background: true)
                    }
                    internal func refresh() async {
                        try? await core?.send(\\.refresh, background: true)
                    }
                    internal func unnamed(_ arg1: String) {
                        core?.send(\\.unnamed, arg1, background: true)
                    }
                    internal func unnamed(_ arg1: String) async {
                        try? await core?.send(\\.unnamed, arg1, background: true)
                    }
                    internal func named(id: Int) {
                        core?.send(\\.named, id, background: true)
                    }
                    internal func named(id: Int) async {
                        try? await core?.send(\\.named, id, background: true)
                    }
                    internal func pair(_ arg1: String, count: Int) {
                        core?.send(\\.pair, (arg1, count), background: true)
                    }
                    internal func pair(_ arg1: String, count: Int) async {
                        try? await core?.send(\\.pair, (arg1, count), background: true)
                    }
                }

                internal func error(_ error: Error) {
                    core.send(\\.error, error)
                }

                internal func error(_ error: Error) async {
                    try? await core.send(\\.error, error)
                }

                internal func cancel() {
                    core.cancelAll()
                    core.send(\\.cancel)
                }

                internal func cancel() async {
                    core.cancelAll()
                    try? await core.send(\\.cancel)
                }

                internal func refresh() {
                    core.send(\\.refresh)
                }

                internal func refresh() async {
                    try? await core.send(\\.refresh)
                }

                internal func unnamed(_ arg1: String) {
                    core.send(\\.unnamed, arg1)
                }

                internal func unnamed(_ arg1: String) async {
                    try? await core.send(\\.unnamed, arg1)
                }

                internal func named(id: Int) {
                    core.send(\\.named, id)
                }

                internal func named(id: Int) async {
                    try? await core.send(\\.named, id)
                }

                internal func pair(_ arg1: String, count: Int) {
                    core.send(\\.pair, (arg1, count))
                }

                internal func pair(_ arg1: String, count: Int) async {
                    try? await core.send(\\.pair, (arg1, count))
                }

                private func _privateLoad(_ arg1: String) {
                    core.send(\\._privateLoad, arg1)
                }

                private func _privateLoad(_ arg1: String) async {
                    try? await core.send(\\._privateLoad, arg1)
                }

                @Published
                internal var background: _BackgroundActions = .init(core: nil, states: [])

                @Published internal var error: Error? = nil

                @Published internal var state: _State = .initial

                internal var actions: EventPublisher<_Action> {
                    core.actionPublisher
                }

                internal var events: EventPublisher<_Event> {
                    core.eventPublisher
                }

                private func setupPublisherAssignments(core: _StateCore) {
                    core.$state
                        .receive(on: DispatchQueue.main)
                        .assign(to: &self.$state)
                    core.$error
                        .receive(on: DispatchQueue.main)
                        .assign(to: &self.$error)
                    core.$backgroundStates
                        .receive(on: DispatchQueue.main)
                        .map { [weak self] newValue -> _BackgroundActions? in
                            return _BackgroundActions.init(
                                core: self?.core,
                                states: newValue
                            )
                        }
                        .compactMap({
                            $0
                        })
                        .assign(to: &self.$background)
                }
            }
            """
        }
    }

    @Test
    func functionRegistrationVariants() {
        assertMacro {
            """
            @Stateful
            final class FunctionsViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case sync
                    case async
                    case throwing
                    case payload(String)
                    case pair(String, Int)
                }

                @Function(\\Action.Cases.sync)
                func doSync() {}

                @Function(\\Action.Cases.async)
                func doAsync() async {}

                @Function(\\Action.Cases.throwing)
                func doThrowing() throws {}

                @Function(\\Action.Cases.payload)
                func doPayload(_ value: String) {}

                @Function(\\Action.Cases.pair)
                func doPair(_ value: String, _ count: Int) async throws {}
            }
            """
        } expansion: {
            """
            final class FunctionsViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case sync
                    case async
                    case throwing
                    case payload(String)
                    case pair(String, Int)
                }
                func doSync() {}
                func doAsync() async {}
                func doThrowing() throws {}
                func doPayload(_ value: String) {}
                func doPair(_ value: String, _ count: Int) async throws {}

                internal enum _State: CoreState {
                    case initial
                }

                @CasePathable internal enum _Action: StateAction {
                    internal typealias Transition = StateTransition<_State, Never>
                    case sync
                    case async
                    case throwing
                    case payload(String)
                    case pair(String, Int)
                    internal var transition: Transition {
                        return .none
                    }
                }

                internal typealias Transition = StateTransition<_State, Never>

                internal typealias _StateCore = StateCore<_State, _Action, Never>

                lazy var core: _StateCore = {
                    let core = _StateCore()
                    core.addFunction(for: \\.sync, function: { [weak self] in
                        self?.doSync()
                    })
                    core.addFunction(for: \\.async, function: { [weak self] in
                        await self?.doAsync()
                    })
                    core.addFunction(for: \\.throwing, function: { [weak self] in
                        try self?.doThrowing()
                    })
                    core.addFunction(for: \\.payload, function: { [weak self] value in
                        self?.doPayload(value)
                    })
                    core.addFunction(for: \\.pair, function: { [weak self] value, count in
                        try await self?.doPair(value, count)
                    })
                    setupPublisherAssignments(core: core)
                    return core
                }()

                private func cancel() {
                    core.cancelAll()
                }

                private func cancel() async {
                    core.cancelAll()
                }

                internal func sync() {
                    core.send(\\.sync)
                }

                internal func sync() async {
                    try? await core.send(\\.sync)
                }

                internal func async() {
                    core.send(\\.async)
                }

                internal func async() async {
                    try? await core.send(\\.async)
                }

                internal func throwing() {
                    core.send(\\.throwing)
                }

                internal func throwing() async {
                    try? await core.send(\\.throwing)
                }

                internal func payload(_ arg1: String) {
                    core.send(\\.payload, arg1)
                }

                internal func payload(_ arg1: String) async {
                    try? await core.send(\\.payload, arg1)
                }

                internal func pair(_ arg1: String, _ arg2: Int) {
                    core.send(\\.pair, (arg1, arg2))
                }

                internal func pair(_ arg1: String, _ arg2: Int) async {
                    try? await core.send(\\.pair, (arg1, arg2))
                }

                @Published internal var state: _State = .initial

                internal var actions: EventPublisher<_Action> {
                    core.actionPublisher
                }

                private func setupPublisherAssignments(core: _StateCore) {
                    core.$state
                        .receive(on: DispatchQueue.main)
                        .assign(to: &self.$state)
                }
            }
            """
        }
    }

    @Test
    func explicitTransitionGetterRemovesErrorCaseStructurally() {
        assertMacro {
            """
            @Stateful
            final class TransitionViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                    case error

                    var transition: Transition {
                        get {
                            switch self {
                            case .refresh:
                                .none
                            case .error:
                                .none
                            }
                        }
                    }
                }
            }
            """
        } expansion: {
            """
            final class TransitionViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                    case error

                    var transition: Transition {
                        get {
                            switch self {
                            case .refresh:
                                .none
                            case .error:
                                .none
                            }
                        }
                    }
                }

                internal enum _State: CoreState {
                    case initial
                }

                @CasePathable internal enum _Action: StateAction, WithErrorAction {
                    internal typealias Transition = StateTransition<_State, Never>
                    case refresh
                    case error(Error)
                    var transition: Transition {
                        switch self {
                        case .refresh:
                            .none
                        }
                    }
                    internal var isError: Bool {
                        if case .error = self {
                            return true
                        } else {
                            return false
                        }
                    }
                }

                internal typealias Transition = StateTransition<_State, Never>

                internal typealias _StateCore = StateCore<_State, _Action, Never>

                lazy var core: _StateCore = {
                    let core = _StateCore()
                    setupPublisherAssignments(core: core)
                    return core
                }()

                internal func error(_ error: Error) {
                    core.send(\\.error, error)
                }

                internal func error(_ error: Error) async {
                    try? await core.send(\\.error, error)
                }

                private func cancel() {
                    core.cancelAll()
                }

                private func cancel() async {
                    core.cancelAll()
                }

                internal func refresh() {
                    core.send(\\.refresh)
                }

                internal func refresh() async {
                    try? await core.send(\\.refresh)
                }

                @Published internal var error: Error? = nil

                @Published internal var state: _State = .initial

                internal var actions: EventPublisher<_Action> {
                    core.actionPublisher
                }

                private func setupPublisherAssignments(core: _StateCore) {
                    core.$state
                        .receive(on: DispatchQueue.main)
                        .assign(to: &self.$state)
                    core.$error
                        .receive(on: DispatchQueue.main)
                        .assign(to: &self.$error)
                }
            }
            """
        }
    }
}
