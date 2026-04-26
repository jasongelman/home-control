import SwiftUI
import WidgetKit

/// Editorial design constants for the widget extension.
/// Duplicated from the main app's EditorialTheme because widget
/// extensions are a separate target that cannot share app sources.
enum WidgetTheme {
    static let accent = Color(red: 0.93, green: 0.36, blue: 0.13)  // #ED5B21
    static let secondaryText = Color(white: 0, opacity: 0.45)
    static let border = Color(white: 0, opacity: 0.12)
    static let cardRadius: CGFloat = 8
}

struct MediumWidgetView: View {
    let entry: LutronWidgetEntry

    private let columnCount = 4
    private let maxRows = 2

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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("LUTRON HOME")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.black)
                Spacer()
                Link(destination: URL(string: "lutronhome://voice")!) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetTheme.accent)
                }
            }
            // Accent rule
            Rectangle()
                .fill(WidgetTheme.accent)
                .frame(height: 1.5)
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
                    Rectangle()
                        .fill(WidgetTheme.border)
                        .frame(height: 0.5)
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
            RoundedRectangle(cornerRadius: WidgetTheme.cardRadius)
                .stroke(
                    hasAlarmTriggered ? Color.red.opacity(0.4) : WidgetTheme.border,
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
                .font(.system(size: 8, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(labelColor(for: cell))
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(cell.value)
                    .font(.system(size: 12, weight: cell.isAlarming ? .heavy : cell.isActive ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(valueColor(for: cell))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let suffix = cell.suffix {
                    Text(suffix)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(WidgetTheme.secondaryText)
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
                    .fill(WidgetTheme.border)
                    .frame(width: 0.5)
            }
        }
    }

    // MARK: - Styling

    private func labelColor(for cell: AppGroupManager.StatusCellSnapshot) -> Color {
        if cell.isAlarming { return Color.red.opacity(0.8) }
        if cell.isActive { return WidgetTheme.accent }
        return WidgetTheme.secondaryText
    }

    private func valueColor(for cell: AppGroupManager.StatusCellSnapshot) -> Color {
        if cell.isAlarming { return .red }
        if cell.isActive { return Color.black }
        return WidgetTheme.secondaryText
    }

    @ViewBuilder
    private func cellBackground(for cell: AppGroupManager.StatusCellSnapshot) -> some View {
        if cell.isAlarming {
            Color.red.opacity(0.08)
        } else {
            Color.clear
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "house")
                .font(.system(size: 20))
                .foregroundStyle(WidgetTheme.secondaryText)
            Text("OPEN LUTRON HOME TO SET UP")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(WidgetTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
