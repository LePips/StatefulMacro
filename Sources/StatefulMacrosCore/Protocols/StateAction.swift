import CasePaths

public protocol StateAction: StateTransitional, CasePathIterable {}

public protocol WithCancelAction: StateAction {
    static var cancel: Self { get }

    var isCancel: Bool { get }
}

public protocol WithErrorAction: StateAction {
    var isError: Bool { get }
}
