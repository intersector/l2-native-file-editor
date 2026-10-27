import SwiftUI

/// Small spinner bound to an operation's in-flight state. It appears only when the operation lasts
/// longer than 250 ms and then stays at least 400 ms, so fast operations never flash it; its space
/// is always reserved so nothing shifts.
struct BusyIndicator: View {
    let isBusy: Bool

    @State private var visible = false
    @State private var shownAt: ContinuousClock.Instant?

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(visible ? 1 : 0)
            .frame(width: 16, height: 16)
            .accessibilityLabel("Working")
            .accessibilityHidden(!visible)
            .task(id: isBusy) {
                if isBusy {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    visible = true
                    shownAt = .now
                } else if visible {
                    if let shownAt {
                        let remaining = Duration.milliseconds(400) - (ContinuousClock.now - shownAt)
                        if remaining > .zero { try? await Task.sleep(for: remaining) }
                    }
                    guard !Task.isCancelled else { return }
                    visible = false
                }
            }
    }
}
