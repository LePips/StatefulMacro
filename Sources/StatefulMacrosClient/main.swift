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
@Stateful
class MyViewModel<P: Equatable>: ObservableObject {

    enum ErrorType: Error {
        case generic
    }

    @CasePathable
    enum Action {
        case cancel
        case error
        case load
        case smile

        var transition: Transition {
            switch self {
            case .error, .cancel: .none
            case .load:
                .to(.loading, then: .content)
                    .whenBackground(.loading)
                    .required(.initial)
                    .invalid(.loading)
            case .smile: .background(.loading)
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

    @Function(\Action.Cases.error)
    private func onError(_ error: Error) {
        print("onError")
    }

    @Function(\Action.Cases.error)
    private func onError2(_ error: Error) {
        print("onError2")
    }

    @Function(\Action.Cases.load)
    private func _load() async throws {
        print("Loading... \(Task.isCancelled)")

        try await Task.sleep(for: .seconds(2))

//        await self.error(ErrorType.generic)

        print("SHOULD NOT HAVE PRINTED, \(Task.isCancelled)")
    }

    @Function(\Action.Cases.smile)
    private func _smile() async throws {
        try await Task.sleep(for: .seconds(0.5))
        print("Smile! \(Task.isCancelled)")
    }
}

asyncMain {
    let vm = MyViewModel<Int>(1)

    let c = vm.$state.sink { state in
        print("State changed to \(state)")
    }

    let b = vm.background.$states.sink { state in
        print("Background states changed to \(state)")
    }

    let aa = vm.actions.sink { action in
        print("-- Action: \(action)")
    }

    await vm.smile()
    await vm.load()

    c.cancel()
    b.cancel()
    aa.cancel()
//    d.cancel()
}
