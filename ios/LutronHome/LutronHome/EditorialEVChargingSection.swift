import SwiftUI

struct EditorialEVChargingSection: View {
    @Environment(ChargePointManager.self) var chargePoint

    var body: some View {
        if chargePoint.isLinked, !chargePoint.chargers.isEmpty {
            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "EV CHARGING",
                    trailing: chargingSummary
                )

                ForEach(chargePoint.chargers) { charger in
                    EVChargerCard(charger: charger)
                }
            }
        }
    }

    private var chargingSummary: String? {
        let active = chargePoint.chargers.filter { $0.status == .charging }.count
        if active > 0 {
            return "\(active) CHARGING"
        }
        let plugged = chargePoint.chargers.filter { $0.isPluggedIn }.count
        if plugged > 0 {
            return "\(plugged) PLUGGED IN"
        }
        return nil
    }
}

private struct EVChargerCard: View {
    let charger: ChargePointCharger
    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 8) {
                Image(systemName: charger.status.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)

                Text(charger.nickname.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let stats = inlineStats {
                    Text(stats)
                        .font(EditorialTheme.monoValue(size: 10))
                        .foregroundStyle(EditorialTheme.secondaryText)
                        .lineLimit(1)
                }

                Text(statusLabel.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(EditorialTheme.cardBackground)
            .overlay(
                Rectangle()
                    .stroke(charger.status == .charging ? statusColor.opacity(0.3) : EditorialTheme.cardBorder, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                EVChargerDetailView(charger: charger)
                    .navigationTitle(charger.nickname)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showDetail = false }
                        }
                    }
            }
        }
    }

    private var statusColor: Color {
        switch charger.status {
        case .charging:  return .green
        case .pluggedIn: return .blue
        case .scheduled: return .indigo
        case .complete:  return .green
        case .error:     return .red
        default:         return EditorialTheme.secondaryText
        }
    }

    /// Status text, with the scheduled start time appended when waiting.
    private var statusLabel: String {
        if charger.status == .scheduled, let t = charger.scheduledFor {
            return "Starts \(t)"
        }
        return charger.status.label
    }

    /// Compact "12.4kWh · 1h 20m · 48A" readout for the single-row card. Leads
    /// with the live session energy, then whatever extras exist.
    private var inlineStats: String? {
        guard charger.isPluggedIn else { return nil }
        var parts: [String] = []
        if let s = charger.liveSession {
            if s.energyKwh > 0 { parts.append(String(format: "%.1fkWh", s.energyKwh)) }
            if s.durationSeconds > 0 { parts.append(EVFormat.duration(s.durationSeconds)) }
        } else if let kw = charger.powerKw, kw > 0 {
            parts.append(String(format: "%.1fkW", kw))
        }
        if charger.amperage > 0 { parts.append("\(charger.amperage)A") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Shared formatting helpers for EV session stats.
enum EVFormat {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Detail View — mirrors the native ChargePoint Home Charger screen

struct EVChargerDetailView: View {
    let charger: ChargePointCharger
    @Environment(ChargePointManager.self) var chargePoint
    @State private var sessions: [ChargePointSession] = []
    @State private var isLoadingSessions = false
    @State private var isToggling = false
    @State private var showAmperage = false

    var body: some View {
        List {
            heroSection
            actionSection
            settingsSection
            sessionsSection
        }
        .task {
            isLoadingSessions = true
            sessions = await chargePoint.fetchHistory(accountIndex: charger.accountIndex, chargerId: charger.chargerId)
            isLoadingSessions = false
        }
        .sheet(isPresented: $showAmperage) {
            NavigationStack {
                ChargeCurrentLimitView(charger: charger)
                    .navigationTitle("Charge Current Limit")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showAmperage = false }
                        }
                    }
            }
        }
    }

    // MARK: Sections

    private var heroSection: some View {
        Section {
            VStack(spacing: 16) {
                statusPill
                Image(systemName: charger.isPluggedIn ? "ev.charger.fill" : "ev.charger")
                    .font(.system(size: 80, weight: .regular))
                    .foregroundStyle(chargerArtworkColor)
                    .padding(.vertical, 8)
                if charger.isPluggedIn, let s = charger.liveSession {
                    // Live session stats — total energy first, then extras.
                    HStack(spacing: 24) {
                        statBlock(label: "ENERGY", value: String(format: "%.1f kWh", s.energyKwh))
                        if s.durationSeconds > 0 {
                            statBlock(label: "TIME", value: EVFormat.duration(s.durationSeconds))
                        }
                        if let avg = avgPowerKw(s) {
                            statBlock(label: "AVG POWER", value: String(format: "%.1f kW", avg))
                        }
                    }
                    if s.cost != nil || s.milesAdded != nil {
                        HStack(spacing: 24) {
                            if let cost = s.cost {
                                statBlock(label: "COST", value: String(format: "$%.2f", cost))
                            }
                            if let miles = s.milesAdded {
                                statBlock(label: "RANGE", value: String(format: "%.0f mi", miles))
                            }
                        }
                    }
                } else if charger.isPluggedIn, let kw = charger.powerKw, kw > 0 {
                    HStack(spacing: 24) {
                        statBlock(label: "POWER", value: String(format: "%.1f kW", kw))
                    }
                }
                if let avg = charger.weeklyAvgKwh, avg > 0 {
                    Text(String(format: "Avg %.1f kWh / week", avg))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    /// Average power over the session — there is no live-telemetry endpoint, so
    /// energy / elapsed time is the best available "power" figure.
    private func avgPowerKw(_ s: ChargePointSessionStats) -> Double? {
        let hours = s.durationSeconds / 3600
        guard hours > 0.02, s.energyKwh > 0 else { return nil }
        return s.energyKwh / hours
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await toggleCharging() }
            } label: {
                HStack {
                    Spacer()
                    if isToggling {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(toggleButtonLabel)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(toggleButtonColor)
            .disabled(isToggling || !charger.isPluggedIn)
        }
    }

    private var settingsSection: some View {
        Section {
            Button {
                showAmperage = true
            } label: {
                HStack {
                    Text("Charge Current Limit")
                        .foregroundStyle(.primary)
                    Spacer()
                    if charger.amperage > 0 {
                        Text("\(charger.amperage)A")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var sessionsSection: some View {
        Section("Recent Sessions") {
            if isLoadingSessions {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if sessions.isEmpty {
                Text("No recent sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions.prefix(10)) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.startTime, style: .date)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        HStack(spacing: 12) {
                            Text(String(format: "%.1f kWh", session.energyKwh))
                            if let cost = session.cost {
                                Text(String(format: "$%.2f", cost))
                            }
                            if let miles = session.milesAdded {
                                Text(String(format: "%.0f mi", miles))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Subviews

    private var statusPill: some View {
        Text(statusLabel)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(statusPillColor, in: Capsule())
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
        }
    }

    // MARK: Colors

    /// Status text, with the scheduled start time appended when waiting.
    private var statusLabel: String {
        if charger.status == .scheduled, let t = charger.scheduledFor {
            return "Starts \(t)"
        }
        return charger.status.label
    }

    private var statusPillColor: Color {
        switch charger.status {
        case .charging:  return .blue
        case .pluggedIn: return .blue
        case .scheduled: return .indigo
        case .complete:  return .green
        case .error:     return .red
        default:         return .gray
        }
    }

    private var chargerArtworkColor: Color {
        switch charger.status {
        case .charging:  return .blue
        case .pluggedIn: return .blue.opacity(0.6)
        case .complete:  return .green
        case .error:     return .red
        default:         return .secondary
        }
    }

    private var toggleButtonLabel: String {
        charger.status == .charging ? "Stop Charge" : "Start Charge"
    }

    private var toggleButtonColor: Color {
        charger.status == .charging ? .orange : .green
    }

    // MARK: Actions

    private func toggleCharging() async {
        isToggling = true
        defer { isToggling = false }
        let start = charger.status != .charging
        await chargePoint.setChargingState(
            accountIndex: charger.accountIndex,
            chargerId: charger.chargerId,
            start: start
        )
    }
}

// MARK: - Charge Current Limit subview

private struct ChargeCurrentLimitView: View {
    let charger: ChargePointCharger
    @Environment(ChargePointManager.self) var chargePoint
    @State private var localAmps: Double

    init(charger: ChargePointCharger) {
        self.charger = charger
        _localAmps = State(initialValue: Double(charger.amperage > 0 ? charger.amperage : charger.maxAmperage))
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Text("\(Int(localAmps))A")
                        .font(.system(size: 56, weight: .bold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)

                    Slider(
                        value: $localAmps,
                        in: 8...Double(max(charger.maxAmperage, 8)),
                        step: 1
                    ) { editing in
                        if !editing {
                            Task {
                                await chargePoint.setAmperage(
                                    accountIndex: charger.accountIndex,
                                    chargerId: charger.chargerId,
                                    amps: Int(localAmps)
                                )
                            }
                        }
                    }

                    HStack {
                        Text("8A")
                        Spacer()
                        Text("\(charger.maxAmperage)A")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } footer: {
                Text("Limits the current the charger will deliver. The actual draw is limited by both this value and the vehicle.")
            }
        }
        .onChange(of: charger.amperage) { _, newVal in
            localAmps = Double(newVal)
        }
    }
}
