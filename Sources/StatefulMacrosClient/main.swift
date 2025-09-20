import CasePaths
import Foundation
import StatefulMacros

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
        case load
        case test(message: String)
        case error

        var transition: Transition {
            switch self {
            case .load:
                //                return .to(.loading, then: .content)
                .background(.loading)
            default:
                .to(.initial)
            }
        }
    }

    enum Event {
        case error
        case otherEvent
    }

    enum BackgroundState {
        case loading
    }

    enum State {
        case initial
        case content
//        case error
    }

    @Published
    var value: Int

    init(_ value: Int) {
        self.value = value
    }

    @Function(\Action.Cases.load)
    private func aload() async throws {
        print("Loading...")

        try await Task.sleep(for: .seconds(2))

        events.send(.otherEvent)
        self.error(ErrorType.generic)

        print("Loading done")
    }

    @Function(\Action.Cases.test)
    private func printTest(_ string: String) async throws {
        print("In printTest with string: \(string)")
    }
}

asyncMain {
    let vm = MyViewModel<Int>(1)

    let c = vm.events.sink { event in
        print(event, vm.error)
    }

//    let c = vm.$error.sink { error in
//        print("Error published: \(String(describing: error))")
//    }

    let d = vm.$value.sink { newValue in
        print("Value changed to \(newValue)")
    }

    let a = Task { await vm.load() }

    try await Task.sleep(for: .seconds(0.5))

    if vm.backgroundStates.contains(.loading) {
        print("Background loading is in progress")
    } else {
        print("No background loading")
    }

    await a.value

    c.cancel()
    d.cancel()
}
