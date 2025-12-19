import CasePaths
import Foundation
import StatefulMacros

// TODO: background struct holds background states
// TODO: background state with ids
// TODO: cancel with id

@MainActor
func asyncMain(execute work: @escaping () async throws -> Void) {
    class State {
        var done = false
    }

    let s = State()

    Task {
        do {
            try await work()
        } catch {
            print("Error: \(error)")
        }
        s.done = true
    }

    while s.done == false {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
}

@MainActor
protocol WithRefresh {

    associatedtype Background: WithRefresh = VoidWithRefresh

    func refresh()
    func refresh() async

    var background: Background { get set }
}

extension WithRefresh where Background == VoidWithRefresh {

    var background: VoidWithRefresh {
        get { .init() }
        set {}
    }
}

struct VoidWithRefresh: WithRefresh {
    func refresh() {}
    func refresh() async throws {}

    var background: VoidWithRefresh {
        get { .init() }
        set {}
    }
}

@MainActor
@Stateful(conformances: [WithRefresh.self])
class MyViewModel<P: Equatable>: ObservableObject, WithRefresh {

    typealias Background = _BackgroundActions

    enum ErrorType: Error {
        case generic
        case fromSmile
    }

    @CasePathable
    enum Action {
        case cancel
        case refresh
        case _privateLoad(String)

        var transition: Transition {
            switch self {
            case .refresh:
                .to(.loading, then: .content)
                    .whenBackground(.loading)
            case ._privateLoad, .cancel:
                .none
            }
        }
    }

    enum BackgroundState {
        case loading
    }

    enum Event {
        case foo
    }

    enum State {
        case error
        case initial
        case loading
        case content
    }

    @Published
    var value: Int

    init(_ value: Int) {
        self.value = value
    }

    @Function(\Action.Cases.refresh)
    private func _load() async throws {
        print("Loading... \(Task.isCancelled)")

        try await Task.sleep(for: .seconds(2))

        print("😊")

        print("+ Is task cancelled: \(Task.isCancelled)")

        await _privateLoad("asdf")
    }

    @Function(\Action.Cases._privateLoad)
    private func onPrivateLoad(_ asdf: String) async throws {
        print("Private loading... \(asdf)")

        try await Task.sleep(for: .seconds(1))

        print("🔒")
    }
}

asyncMain {
    let vm = MyViewModel<Int>(1)

    let c = vm.$state.sink { state in
        print("++ State changed to \(state)")
    }

    let b = vm.$background.sink { newValue in
        print(">> Background states changed to \(newValue.states)")
    }

    let aa = vm.actions.sink { action in
        print("-- Action: \(action)")
    }

    let d = Task {
        await vm.refresh()
        print("Refreshed")
    }

    try await Task.sleep(for: .seconds(1))

//    await vm.cancel()

    c.cancel()
    b.cancel()
    aa.cancel()

    await d.value
}
