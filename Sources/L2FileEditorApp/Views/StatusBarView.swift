import SwiftUI

/// Bottom status bar: progress and current step while busy, the last error in red, or the opened
/// file with its record/column counts and timing.
struct StatusBarView: View {
    let session: DocumentSession

    var body: some View {
        let status = session.status
        HStack(spacing: 10) {
            BusyIndicator(isBusy: session.isBusy)
            message(status)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let name = status.fileName {
                Text(session.isDirty ? "\(name) — edited" : name)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            if let records = status.recordCount {
                Text("\(records) records")
            }
            if let columns = status.columnCount {
                Text("\(columns) columns")
            }
            if let elapsed = status.elapsed {
                Text(StepTimer.format(elapsed))
            }
            if let detail = status.detail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func message(_ status: DocumentSession.Status) -> some View {
        if case let .busy(step) = session.state {
            Text(step)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        } else if status.isError {
            Label(status.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(status.message)
        } else {
            Text(status.message)
        }
    }
}
