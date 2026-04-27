import Foundation
import Combine
import os.log

final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: String
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    private let maxEntries = 500
    private let osLog = OSLog(subsystem: "com.user.btswitch", category: "general")
    private let queue = DispatchQueue(label: "com.user.btswitch.logger")

    private init() {}

    func info(_ msg: String) { append(level: "INFO", message: msg) }
    func warn(_ msg: String) { append(level: "WARN", message: msg) }
    func error(_ msg: String) { append(level: "ERROR", message: msg) }

    private func append(level: String, message: String) {
        let entry = Entry(timestamp: Date(), level: level, message: message)
        os_log("%{public}@ %{public}@", log: osLog, type: .default, level, message)

        // Mutate on main so SwiftUI updates correctly.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }

    func formattedDump() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { e in
            "[\(f.string(from: e.timestamp))] [\(e.level)] \(e.message)"
        }.joined(separator: "\n")
    }
}
