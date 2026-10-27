import AppKit
import SwiftUI

/// Hooks the window that hosts this view: `onAttach` receives it, `shouldClose` answers its
/// `windowShouldClose` (⌘W, the close button, File > Close) and `onClose` runs when it closes. SwiftUI does not call `onDisappear` when a
/// `WindowGroup` window is closed, so this observes that window's own `willCloseNotification` (filtered by
/// object, so closing another window never triggers it) and puts a proxy in front of SwiftUI's window
/// delegate that forwards every other delegate message.
struct WindowCloseObserver: NSViewRepresentable {
    let onAttach: @MainActor (NSWindow) -> Void
    let shouldClose: @MainActor (NSWindow) -> Bool
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.update(onAttach: onAttach, shouldClose: shouldClose, onClose: onClose)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.update(onAttach: onAttach, shouldClose: shouldClose, onClose: onClose)
    }

    /// Zero-size view whose `window` is the hosting `NSWindow`; re-registers whenever it moves to a window.
    final class HostView: NSView {
        private var onAttach: (@MainActor (NSWindow) -> Void)?
        private var onClose: (@MainActor () -> Void)?
        private let proxy = DelegateProxy()

        func update(
            onAttach: @escaping @MainActor (NSWindow) -> Void, shouldClose: @escaping @MainActor (NSWindow) -> Bool,
            onClose: @escaping @MainActor () -> Void
        ) {
            proxy.shouldClose = shouldClose
            self.onAttach = onAttach
            self.onClose = onClose
            installProxy()
            if let window { onAttach(window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
            installProxy()
            onAttach?(window)
        }

        /// Puts the proxy in front of the window's delegate again if SwiftUI replaced it.
        private func installProxy() {
            guard let window, window.delegate !== proxy else { return }
            proxy.original = window.delegate
            window.delegate = proxy
        }

        @objc private func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }

    /// Answers `windowShouldClose` (after SwiftUI's own delegate, if it implements it) and forwards every
    /// other message to SwiftUI's delegate.
    final class DelegateProxy: NSObject, NSWindowDelegate {
        nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
        var shouldClose: (@MainActor (NSWindow) -> Bool)?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if original?.windowShouldClose?(sender) == false { return false }
            return shouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
