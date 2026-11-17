import Foundation

final class PCMStreamClock: @unchecked Sendable {
    private let lock = NSLock()
    private var byteCount = 0

    func append(byteCount bytes: Int) {
        lock.lock()
        byteCount += max(0, bytes)
        lock.unlock()
    }

    var elapsedMilliseconds: Int {
        lock.lock()
        defer { lock.unlock() }
        let samples = Double(byteCount) / Double(MemoryLayout<Int16>.size)
        return Int((samples / 24_000.0) * 1_000.0)
    }
}
