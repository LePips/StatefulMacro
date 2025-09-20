import Combine

public struct EventPublisher<T>: Publisher {
    public typealias Output = T
    public typealias Failure = Never

    private let subject = PassthroughSubject<T, Never>()

    public func receive<S>(subscriber: S) where S: Subscriber, Never == S.Failure, T == S.Input {
        subject.receive(subscriber: subscriber)
    }

    public func send(_ value: T) {
        subject.send(value)
    }
}
