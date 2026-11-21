import SwiftUI
import SwitchboardCore
import SwitchboardRender

/// Details of whatever is pinned: a process, a destination, or the connections between them.
struct InspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionTitle("Inspector")
                Spacer()
                if !model.selection.isEmpty {
                    Button("Clear") { model.select(nil) }
                        .buttonStyle(.plain)
                        .font(.mono(10))
                        .foregroundStyle(Color.dim)
                }
            }
            .padding(12)
            Rectangle().fill(Color.hairline).frame(height: 1)

            if let info = model.inspector {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(info.title)
                                .font(.mono(14, .semibold))
                                .foregroundStyle(Color.signal)
                                .textSelection(.enabled)
                            Text(info.subtitle).font(.mono(10)).foregroundStyle(Color.dim)
                        }
                        InfoRows(info: info)
                        if let footnote = info.footnote {
                            Text(footnote).font(.mono(10)).foregroundStyle(Color.caution)
                        }

                        HStack(spacing: 8) {
                            Button("Filter to this") { model.filterToSelection() }
                            Button(model.focused ? "Release focus" : "Focus") { model.toggleFocusOnSelection() }
                        }
                        .font(.mono(11))

                        SectionTitle("Connections (\(model.inspectorRows.count))")
                        // Lazy, so only the rows on screen are laid out each second.
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.inspectorRows.prefix(60)) { row in
                                ConnectionSummary(row: row)
                            }
                            if model.inspectorRows.count > 60 {
                                Text("+\(model.inspectorRows.count - 60) more — filter to see them in the table")
                                    .font(.mono(10))
                                    .foregroundStyle(Color.dim)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !model.selection.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not in view").font(.mono(12)).foregroundStyle(Color.readout)
                    Text("The selected item has no connections that match the current filter, or it has gone quiet. It will reappear here if that changes.")
                        .font(.mono(11))
                        .foregroundStyle(Color.dim)
                }
                .padding(12)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing selected").font(.mono(12)).foregroundStyle(Color.readout)
                    Text("Click a process, a destination, or a line in the graph, or a row in the Connections table, to pin its details here.")
                        .font(.mono(11))
                        .foregroundStyle(Color.dim)
                }
                .padding(12)
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.panel)
    }
}

/// One connection in two lines: where it goes, and how it is doing.
struct ConnectionSummary: View {
    let row: ConnectionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(row.proto) \(row.remote):\(row.remotePort)  \(row.service)")
                .foregroundStyle(Color.readout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(row.process) · \(row.state) · \(row.ageExact ? "" : "≥")\(ByteFormat.duration(row.age)) · ↓ \(ByteFormat.rate(row.rateIn)) ↑ \(ByteFormat.rate(row.rateOut))")
                .foregroundStyle(Color.dim)
                .lineLimit(1)
        }
        .font(.mono(10))
    }
}
