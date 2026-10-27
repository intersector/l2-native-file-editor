import SwiftUI

/// The "Program Log" pane: read-only monospaced lines, errors in red, newest line kept in view.
struct LogView: View {
    let session: DocumentSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Program Log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { session.clearLog() }
                    .controlSize(.small)
                    .disabled(session.log.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(session.log) { line in
                            Text(line.text)
                                .foregroundStyle(color(of: line.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.log.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottomLeading) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(of level: LogLine.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
