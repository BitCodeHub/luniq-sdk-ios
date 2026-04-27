import Foundation
import UIKit

enum DeviceInfo {
    static var model: String {
        var sys = utsname()
        uname(&sys)
        let machineMirror = Mirror(reflecting: sys.machine)
        return machineMirror.children.reduce("") { acc, el in
            guard let v = el.value as? Int8, v != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(v)))
        }
    }
}

enum Logger {
    static var enabled = true
    static func log(_ msg: @autoclosure () -> String) {
        guard enabled else { return }
        #if DEBUG
        print("[Luniq] \(msg())")
        #endif
    }
}
