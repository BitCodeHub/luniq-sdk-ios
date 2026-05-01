import Foundation

// Captures uncaught Objective-C exceptions and select Unix signals. Emits
// $error events. Also exposes a public API on Luniq for apps to report
// Swift errors that they caught themselves.
final class ErrorCapture {
    private let emit: (String, [String: Any]) -> Void
    private static var installed = false

    init(emit: @escaping (String, [String: Any]) -> Void) {
        self.emit = emit
    }

    func install() {
        guard !Self.installed else { return }
        Self.installed = true
        ErrorCaptureStore.emit = emit

        NSSetUncaughtExceptionHandler { ex in
            ErrorCaptureStore.emit?("$error", [
                "kind": "exception",
                "name": ex.name.rawValue,
                "message": ex.reason ?? "",
                "stack": ex.callStackSymbols.prefix(20).joined(separator: "\n"),
                "fatal": true,
            ])
        }

        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE] {
            signal(sig) { signalNum in
                let name = ErrorCapture.signalName(signalNum)
                ErrorCaptureStore.emit?("$error", [
                    "kind": "signal",
                    "name": name,
                    "message": "Signal \(signalNum) (\(name))",
                    "stack": Thread.callStackSymbols.prefix(20).joined(separator: "\n"),
                    "fatal": true,
                ])
            }
        }
    }

    static func signalName(_ s: Int32) -> String {
        switch s {
        case SIGABRT: return "SIGABRT"
        case SIGILL:  return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGFPE:  return "SIGFPE"
        case SIGBUS:  return "SIGBUS"
        case SIGPIPE: return "SIGPIPE"
        default: return "SIG\(s)"
        }
    }

    // Apps call this when catching Swift errors.
    func report(_ error: Error, context: [String: Any] = [:]) {
        let ns = error as NSError
        var props: [String: Any] = [
            "kind": "error",
            "name": String(describing: type(of: error)),
            "domain": ns.domain,
            "code": ns.code,
            "message": ns.localizedDescription,
            "fatal": false,
        ]
        props.merge(context) { _, new in new }
        emit("$error", props)
    }
}

enum ErrorCaptureStore {
    static var emit: ((String, [String: Any]) -> Void)?
}
