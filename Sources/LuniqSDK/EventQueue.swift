import Foundation

final class EventQueue {
    private var buffer: [Event] = []
    private let lock = NSLock()
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = dir.appendingPathComponent("Luniq", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("queue.json")
    }()

    func enqueue(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(event)
        if buffer.count > 10_000 { buffer.removeFirst(buffer.count - 10_000) }
        persist()
    }

    func dequeueBatch(max: Int) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        let n = Swift.min(max, buffer.count)
        let batch = Array(buffer.prefix(n))
        buffer.removeFirst(n)
        persist()
        return batch
    }

    func requeue(_ events: [Event]) {
        lock.lock(); defer { lock.unlock() }
        buffer.insert(contentsOf: events, at: 0)
        persist()
    }

    func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        buffer = (try? decoder.decode([Event].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(buffer) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
