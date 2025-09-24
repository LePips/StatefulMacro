public protocol CoreState: Equatable {
    static var initial: Self { get }
}

public protocol WithErrorState: CoreState {
    static var error: Self { get }
}
