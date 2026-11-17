import Foundation

final class PCMRelay: @unchecked Sendable {
    typealias Sink = @Sendable (Data) -> Void

    private let lock = NSLock()
    private var sink: Sink?

    func update(_ sink: Sink?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func send(_ data: Data) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(data)
    }
}
