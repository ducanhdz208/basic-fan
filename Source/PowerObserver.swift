import Foundation
import IOKit.ps

final class PowerObserver {
    private var source: CFRunLoopSource?
    private let changed: () -> Void
    init(changed: @escaping () -> Void) {
        self.changed = changed
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerObserver>.fromOpaque(context).takeUnretainedValue().changed()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }
    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
