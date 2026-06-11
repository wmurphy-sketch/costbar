import AppKit
import SwiftUI
import Charts

// MARK: - ccusage JSON models

struct CCModelBreakdown: Decodable {
    let modelName: String
    let cost: Double
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
}

struct CCDailyEntry: Decodable {
    let period: String
    let totalCost: Double
    let modelBreakdowns: [CCModelBreakdown]
}

struct CCDailyResponse: Decodable {
    let daily: [CCDailyEntry]
}

// MARK: - OAuth usage (true billing)

struct ExtraUsage: Codable {
    let is_enabled: Bool
    let monthly_limit: Double   // cents
    let used_credits: Double    // cents
    let utilization: Double     // percent

    var usedDollars: Double { used_credits / 100 }
    var capDollars: Double { monthly_limit / 100 }
}

struct RateWindow: Codable {
    let utilization: Double
    let resets_at: String
}

struct OAuthUsage: Codable {
    let five_hour: RateWindow?
    let seven_day: RateWindow?
    let extra_usage: ExtraUsage?
}

// MARK: - Display models

struct ModelAgg: Identifiable {
    let id: String
    let name: String
    var cost: Double
    var tokens: Int
}

struct DayUsage: Identifiable {
    let id: String       // yyyy-MM-dd
    let cost: Double
    let models: [ModelAgg]

    var date: Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: id) ?? .distantPast
    }

    var displayDate: String {
        let inF = DateFormatter()
        inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: id) else { return id }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        let outF = DateFormatter()
        outF.dateFormat = "EEE, MMM d"
        return outF.string(from: d)
    }
}

struct MonthUsage: Identifiable {
    let id: String       // yyyy-MM
    let days: [DayUsage] // ascending by date
    var total: Double { days.reduce(0) { $0 + $1.cost } }

    var label: String {
        let inF = DateFormatter()
        inF.dateFormat = "yyyy-MM"
        guard let d = inF.date(from: id) else { return id }
        let outF = DateFormatter()
        outF.dateFormat = "MMMM yyyy"
        return outF.string(from: d)
    }
}

// MARK: - Store

struct UsageError: Error { let message: String }

final class UsageStore: ObservableObject {
    @Published var months: [MonthUsage] = []
    @Published var selectedIndex: Int = 0
    @Published var oauthUsage: OAuthUsage?
    @Published var lastUpdated: Date?
    @Published var errorText: String?
    @Published var isLoading = false

    /// True once we've ever loaded real billing (from disk cache or a live fetch).
    @Published var billingEverLoaded = false
    /// True when the displayed billing is from cache because the latest live fetch failed.
    @Published var billingStale = false

    var onStatusUpdate: ((String) -> Void)?

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CostBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("billing.json")
    }()

    init() {
        // Seed billing from disk so the real number shows instantly on launch and
        // survives a rate-limited fetch (the endpoint rate-limits intermittently).
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode(OAuthUsage.self, from: data),
           cached.extra_usage?.is_enabled == true {
            oauthUsage = cached
            billingEverLoaded = true
            billingStale = true   // until a live fetch confirms it
        }
    }

    var selected: MonthUsage? {
        months.indices.contains(selectedIndex) ? months[selectedIndex] : nil
    }

    var currentMonthKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Self.runCCUsage()
            let oauth = Self.runOAuthUsage()
            DispatchQueue.main.async {
                self.isLoading = false
                // Only replace billing on a valid fetch; otherwise keep the last-good
                // value (a rate-limited/failed fetch returns nil — don't blank the real number).
                if let oauth, oauth.extra_usage?.is_enabled == true {
                    self.oauthUsage = oauth
                    self.billingEverLoaded = true
                    self.billingStale = false
                    if let data = try? JSONEncoder().encode(oauth) {
                        try? data.write(to: Self.cacheURL)
                    }
                } else if self.oauthUsage != nil {
                    self.billingStale = true   // fetch failed, showing cached value
                }
                switch result {
                case .success(let resp):
                    self.apply(resp)
                    self.lastUpdated = Date()
                case .failure(let err):
                    self.errorText = err.message
                }
                self.updateStatus()
            }
        }
    }

    private func updateStatus() {
        // Only ever show real billing. Never the API-equivalent estimate.
        let title: String
        if let eu = oauthUsage?.extra_usage, eu.is_enabled {
            let d = eu.usedDollars
            title = money(d, decimals: d >= 100 ? 0 : 2)
        } else {
            title = "$…"
        }
        onStatusUpdate?(title)
    }

    private func apply(_ resp: CCDailyResponse) {
        // Aggregate entries by day (ccusage may emit one row per agent per day)
        var byDay: [String: (cost: Double, models: [String: ModelAgg])] = [:]
        for entry in resp.daily {
            var bucket = byDay[entry.period] ?? (0, [:])
            bucket.cost += entry.totalCost
            for mb in entry.modelBreakdowns {
                var m = bucket.models[mb.modelName]
                    ?? ModelAgg(id: mb.modelName, name: Self.shortModelName(mb.modelName), cost: 0, tokens: 0)
                m.cost += mb.cost
                m.tokens += mb.totalTokens
                bucket.models[mb.modelName] = m
            }
            byDay[entry.period] = bucket
        }
        let allDays = byDay
            .map { DayUsage(id: $0.key, cost: $0.value.cost,
                            models: $0.value.models.values.sorted { $0.cost > $1.cost }) }
            .sorted { $0.id < $1.id }

        let grouped = Dictionary(grouping: allDays) { String($0.id.prefix(7)) }
        let keepID = selected?.id
        months = grouped
            .map { MonthUsage(id: $0.key, days: $0.value) }
            .sorted { $0.id < $1.id }
        if let keep = keepID, let idx = months.firstIndex(where: { $0.id == keep }) {
            selectedIndex = idx
        } else {
            selectedIndex = max(0, months.count - 1)
        }
    }

    static func shortModelName(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "claude-", with: "")
        // strip trailing -YYYYMMDD snapshot suffix
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s
    }

    private static func runOAuthUsage() -> OAuthUsage? {
        // Retry on 429/transient errors with backoff — the usage endpoint enforces a
        // short rolling rate limit, so a single attempt often loses the race.
        let cmd = #"""
        TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("claudeAiOauth",{}).get("accessToken",""))' 2>/dev/null)
        [ -z "$TOKEN" ] && exit 1
        for attempt in 1 2 3 4 5; do
          body=$(curl -s -w "\n%{http_code}" --max-time 15 "https://api.anthropic.com/api/oauth/usage" -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20")
          code=$(printf '%s' "$body" | tail -n1)
          if [ "$code" = "200" ]; then
            printf '%s' "$body" | sed '$d'
            exit 0
          fi
          sleep $attempt
        done
        exit 1
        """#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(OAuthUsage.self, from: data)
    }

    private static func runCCUsage() -> Result<CCDailyResponse, UsageError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "ccusage daily --json"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return .failure(UsageError(message: "Couldn't launch zsh: \(error.localizedDescription)"))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(UsageError(message: "ccusage failed: \(msg.prefix(200))"))
        }
        do {
            return .success(try JSONDecoder().decode(CCDailyResponse.self, from: data))
        } catch {
            return .failure(UsageError(message: "Couldn't parse ccusage output: \(error.localizedDescription)"))
        }
    }
}

// MARK: - Formatting helpers

func money(_ v: Double, decimals: Int = 2) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.maximumFractionDigits = decimals
    f.minimumFractionDigits = decimals
    return f.string(from: NSNumber(value: v)) ?? "$\(v)"
}

func tokens(_ n: Int) -> String {
    let v = Double(n)
    switch v {
    case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
    case 1_000_000...:     return String(format: "%.1fM", v / 1_000_000)
    case 1_000...:         return String(format: "%.0fK", v / 1_000)
    default:               return "\(n)"
    }
}

// MARK: - Model colors

func modelColor(_ name: String) -> Color {
    let n = name.lowercased()
    if n.contains("fable")  { return Color(red: 1.00, green: 0.58, blue: 0.25) }
    if n.contains("opus")   { return Color(red: 0.72, green: 0.48, blue: 1.00) }
    if n.contains("sonnet") { return Color(red: 0.36, green: 0.64, blue: 1.00) }
    if n.contains("haiku")  { return Color(red: 0.25, green: 0.83, blue: 0.74) }
    if n.contains("gpt")    { return Color(red: 0.55, green: 0.85, blue: 0.45) }
    return .gray
}

// MARK: - Glass card

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(
                                colors: [.white.opacity(0.10), .white.opacity(0.02)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(LinearGradient(
                                colors: [.white.opacity(0.45), .white.opacity(0.06), .white.opacity(0.18)],
                                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            )
    }
}

// MARK: - Views

struct UsageView: View {
    @ObservedObject var store: UsageStore
    @State private var selectedDate: Date?

    private var days: [DayUsage] { store.selected?.days ?? [] }
    private var apiMonthTotal: Double { store.selected?.total ?? 0 }
    private var isCurrentMonth: Bool { store.selected?.id == store.currentMonthKey }

    // Real extra-usage billing for the current month, else the API-equivalent (past months
    // have no billing data). This is the number shown prominently — no estimate on screen.
    private var monthTotal: Double {
        if isCurrentMonth, let eu = store.oauthUsage?.extra_usage, eu.is_enabled {
            return eu.usedDollars
        }
        return apiMonthTotal
    }
    private var showingRealBilling: Bool {
        isCurrentMonth && (store.oauthUsage?.extra_usage?.is_enabled == true)
    }
    // Headline: real billing (current month) or the month's API-equiv (past months).
    // Current month with no billing yet → "loading", never the estimate.
    private var headlineText: String {
        if isCurrentMonth && !showingRealBilling {
            return store.billingEverLoaded ? money(monthTotal) : "Billing…"
        }
        return money(monthTotal)
    }
    // Factor that rescales this month's API-equivalent figures to the real bill (1 otherwise).
    private var scale: Double {
        (showingRealBilling && apiMonthTotal > 0) ? monthTotal / apiMonthTotal : 1
    }
    private func scaledDays(_ ds: [DayUsage]) -> [DayUsage] {
        guard scale != 1 else { return ds }
        return ds.map { d in
            DayUsage(id: d.id, cost: d.cost * scale,
                     models: d.models.map { ModelAgg(id: $0.id, name: $0.name, cost: $0.cost * scale, tokens: $0.tokens) })
        }
    }

    private var chartDays: [DayUsage] { scaledDays(days) }

    private var selectedDay: DayUsage? {
        guard let sel = selectedDate else { return nil }
        return chartDays.first { Calendar.current.isDate($0.date, inSameDayAs: sel) }
    }

    private var modelOrder: [String] {
        var totals: [String: Double] = [:]
        for d in days { for m in d.models { totals[m.name, default: 0] += m.cost } }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    private var monthModels: [ModelAgg] {
        var agg: [String: ModelAgg] = [:]
        for d in chartDays {
            for m in d.models {
                var a = agg[m.name] ?? ModelAgg(id: m.name, name: m.name, cost: 0, tokens: 0)
                a.cost += m.cost
                a.tokens += m.tokens
                agg[m.name] = a
            }
        }
        return agg.values.sorted { $0.cost > $1.cost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            billingCard
            header
            if let err = store.errorText {
                GlassCard {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else if days.isEmpty {
                GlassCard {
                    Text(store.isLoading ? "Loading…" : "No usage this month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(24)
                }
            } else {
                GlassCard { chart.padding(12) }
                GlassCard { breakdown.padding(12) }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(width: 360, height: 640)
        .background(.ultraThinMaterial)
        .animation(.smooth(duration: 0.25), value: selectedDate)
        .animation(.smooth(duration: 0.25), value: store.selectedIndex)
    }

    // True billing (current month, from Claude OAuth endpoint)
    @ViewBuilder
    private var billingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Extra usage billed")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text("true billing")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary.opacity(0.5)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                }
                if let eu = store.oauthUsage?.extra_usage, eu.is_enabled {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(money(eu.usedDollars))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("of \(money(eu.capDollars, decimals: 0)) cap")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.4))
                            Capsule()
                                .fill(LinearGradient(colors: [.teal, .orange, .red],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, geo.size.width * min(eu.utilization / 100, 1)))
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text(String(format: "%.1f%% of monthly cap", eu.utilization))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if let s = store.oauthUsage?.five_hour, let w = store.oauthUsage?.seven_day {
                            Text("Session \(Int(s.utilization))% · Week \(Int(w.utilization))%")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("Billing data unavailable — sign in to Claude Code to refresh the token. Showing API-equivalent only.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
    }

    // Month nav + big number + pace
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Button { step(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.selectedIndex <= 0)
                    .opacity(store.selectedIndex <= 0 ? 0.25 : 0.8)

                    Text(store.selected?.label ?? "Claude Usage")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 92)

                    Button { step(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.selectedIndex >= store.months.count - 1)
                    .opacity(store.selectedIndex >= store.months.count - 1 ? 0.25 : 0.8)
                }
                Text(headlineText)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(paceLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(pillText)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary.opacity(0.5)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        }
    }

    private var pillText: String {
        if isCurrentMonth {
            return store.billingStale ? "cached" : "billed"
        }
        return "API-equivalent"
    }

    private func step(_ delta: Int) {
        let next = store.selectedIndex + delta
        guard store.months.indices.contains(next) else { return }
        store.selectedIndex = next
        selectedDate = nil
    }

    private var paceLine: String {
        guard monthTotal > 0, !days.isEmpty else { return " " }
        if isCurrentMonth {
            let cal = Calendar.current
            let dayOfMonth = cal.component(.day, from: Date())
            let daysInMonth = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
            let avg = monthTotal / Double(max(dayOfMonth, 1))
            let pace = avg * Double(daysInMonth)
            return "avg \(money(avg, decimals: 0))/day · pacing \(money(pace, decimals: 0))"
        } else {
            let avg = monthTotal / Double(days.count)
            return "avg \(money(avg, decimals: 0))/day · \(days.count) active days"
        }
    }

    // Stacked bar chart, hover to scrub
    private var chart: some View {
        Chart {
            ForEach(chartDays) { day in
                ForEach(day.models) { m in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Cost", m.cost)
                    )
                    .foregroundStyle(by: .value("Model", m.name))
                    .cornerRadius(2.5)
                    .opacity(selectedDate == nil ||
                             Calendar.current.isDate(day.date, inSameDayAs: selectedDate ?? .distantPast)
                             ? 1.0 : 0.35)
                }
            }
        }
        .chartForegroundStyleScale(domain: modelOrder, range: modelOrder.map(modelColor))
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days.count > 16 ? 5 : 2)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel(format: .dateTime.day(), centered: true)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v >= 1000 ? String(format: "$%.1fk", v / 1000) : String(format: "$%.0f", v))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(height: 150)
    }

    // Detail: hovered day, or month totals by model
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedDay?.displayDate ?? "By model")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text(money(selectedDay?.cost ?? monthTotal))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            ForEach(selectedDay?.models ?? monthModels) { m in
                HStack(spacing: 7) {
                    Circle()
                        .fill(modelColor(m.name))
                        .frame(width: 7, height: 7)
                        .shadow(color: modelColor(m.name).opacity(0.7), radius: 3)
                    Text(m.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(tokens(m.tokens)) tok")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(money(m.cost))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(width: 70, alignment: .trailing)
                        .contentTransition(.numericText())
                }
            }
            if selectedDay == nil {
                Text("Hover the chart for a single day")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.quaternary)
                    .padding(.top, 2)
            }
        }
    }

    private var footer: some View {
        HStack {
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else if let t = store.lastUpdated {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit")
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = UsageStore()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "$…"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageView(store: store))

        store.onStatusUpdate = { [weak self] title in
            self?.statusItem.button?.title = title
        }

        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Refresh only if data is stale (>2 min). The billing endpoint rate-limits,
            // so don't re-fetch on every open — the 10-min timer + cache cover it.
            if store.lastUpdated == nil || Date().timeIntervalSince(store.lastUpdated!) > 120 {
                store.refresh()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
