import SwiftUI
import WidgetKit

struct MediumWidgetView: View {
    let entry: LutronWidgetEntry

    private let columnCount = 4
    private let maxRows = 2

    /// Show up to 8 cells (2 rows of 4) — same columnCount as the main-app
    /// dashboard. Alarming cells are bumped to the front so they always render.
    private var visibleCells: [AppGroupManager.StatusCellSnapshot] {
        let prioritized = entry.statusCells.sorted { $0.isAlarming && !$1.isAlarming }
        return Array(prioritized.prefix(columnCount * maxRows))
    }

    private var hasAlarmTriggered: Bool {
        entry.statusCells.contains { $0.isAlarming }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if visibleCells.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("LUTRON HOME")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            Link(destination: URL(string: "lutronhome://voice")!) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Grid

    private var rows: [[AppGroupManager.StatusCellSnapshot]] {
        stride(from: 0, to: visibleCells.count, by: columnCount).map {
            Array(visibleCells[$0..<min($0 + columnCount, visibleCells.count)])
        }
    }

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 0, alignment: .leading),
            count: columnCount
        )
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                if rowIdx > 0 {
                    Divider().overlay(Color(.separator).opacity(0.2))
                }
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { index, cell in
                        cellView(cell, showRightBorder: index < columnCount - 1)
                    }
                    if row.count < columnCount {
                        ForEach(row.count..<columnCount, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    hasAlarmTriggered ? Color.red.opacity(0.3) : Color(.separator).opacity(0.25),
                    lineWidth: 0.5
                )
        )
    }

    @ViewBuilder
    private func cellView(
        _ cell: AppGroupManager.StatusCellSnapshot,
        showRightBorder: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.label)
                .font(.system(size: 8, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(labelColor(for: cell))
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(cell.value)
                    .font(.system(size: 12, weight: cell.isAlarming ? .heavy : cell.isActive ? .bold : .medium))
                    .foregroundStyle(valueColor(for: cell))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let suffix = cell.suffix {
                    Text(suffix)
                        .font(.system(size: 8))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(cellBackground(for: cell))
        .overlay(alignment: .trailing) {
            if showRightBorder {
                Rectangle()
                    .fill(Color(.separator).opacity(0.2))
                    .frame(width: 0.5)
            }
        }
    }

    // MARK: - Styling

    private func labelColor(for cell: AppGroupManager.StatusCellSnapshot) -> Color {
        if cell.isAlarming { return Color.red.opacity(0.8) }
        if cell.isActive { return Color.blue.opacity(0.7) }
        return Color.primary.opacity(0.4)
    }

    private func valueColor(for cell: AppGroupManager.StatusCellSnapshot) -> Color {
        if cell.isAlarming { return .red }
        if cell.isActive { return .blue }
        return Color.primary.opacity(0.4)
    }

    @ViewBuilder
    private func cellBackground(for cell: AppGroupManager.StatusCellSnapshot) -> some View {
        if cell.isAlarming {
            Color.red.opacity(0.12)
        } else if cell.isActive {
            Color.blue.opacity(0.08)
        } else {
            Color.clear
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "house")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("Open Lutron Home to set up")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
