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

    @CasePathable
    enum Action {
        case load
        case test(message: String)
        case cancel
        case error(Error)

        var transition: Transition {
            switch self {
            case .load:
//                return .to(.loading, then: .content)
                .background(.loading)
            case .test:
                .background(.loading)
            default:
                .to(.initial)
            }
        }
    }

    enum BackgroundState {
        case loading
    }

    enum State {
        case initial
        case loading
        case content
        case error
    }

    init(_ value: Int) {
        setupPublisherAssignments()
    }

    @Function(\Action.Cases.load)
    private func aload() async throws {
        print("Loading...")

        try await Task.sleep(for: .seconds(2))

        print("Loading done")
    }

    @Function(\Action.Cases.test)
    private func printTest(string: String) async throws {
        print("In printTest with string: \(string)")
//        try await Task.sleep(for: .seconds(2))
    }
}

asyncMain {
    let vm = MyViewModel<Int>(1)

    let a = Task { await vm.load() }

    try await Task.sleep(for: .seconds(1))

    if vm.backgroundStates.contains(.loading) {
        print("Background loading is in progress")
    } else {
        print("No background loading")
    }

    await a.value
}
