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
    /// True when a fetch succeeded but extra-usage is not enabled on this account
    /// (e.g. a Pro-plan teammate). In that case we show the API-equivalent estimate.
    @Published var extraUsageUnavailable = false
    /// When billing was last successfully fetched (live), for the footer freshness line.
    @Published var billingUpdatedAt: Date?

    /// Manual refresh is allowed at most once per 10 min since the last successful sync,
    /// to avoid stacking requests against the shared rolling rate limit.
    static let manualCooldown: TimeInterval = 600
    var manualRefreshAllowed: Bool {
        guard let t = billingUpdatedAt else { return true }   // never synced → allow
        return Date().timeIntervalSince(t) >= Self.manualCooldown
    }
    /// Seconds until manual refresh becomes available again (0 if available now).
    var manualCooldownRemaining: TimeInterval {
        guard let t = billingUpdatedAt else { return 0 }
        return max(0, Self.manualCooldown - Date().timeIntervalSince(t))
    }

    var onStatusUpdate: ((String) -> Void)?

    private static func dir() -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CostBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static let cacheURL = dir().appendingPathComponent("billing.json")
    private static let ledgerURL = dir().appendingPathComponent("overage-ledger.json")

    // MARK: Real-overage daily ledger (forward-differencing of used_credits)

    /// Per-day high-water mark of used_credits (dollars), keyed by yyyy-MM-dd (local).
    /// Today's real overage = today's high-water − the prior day's high-water.
    @Published private(set) var overageEnd: [String: Double] = [:]   // date → end-of-day used_credits

    /// Real overage billed on a given local day, or nil if we don't yet have both
    /// that day's and the prior day's snapshots (so we never show a fabricated number).
    func realOverage(forDayKey key: String) -> Double? {
        guard let end = overageEnd[key] else { return nil }
        // Find the most recent prior recorded day.
        let priorKeys = overageEnd.keys.filter { $0 < key }.sorted()
        guard let prevKey = priorKeys.last, let prev = overageEnd[prevKey] else {
            return nil   // first day on record — no baseline to diff against
        }
        let delta = end - prev
        // Negative delta = monthly reset (counter rolled to ~0). On a reset day the
        // billed amount is just the new end value (spend since the reset).
        return delta < 0 ? end : delta
    }

    private func recordOverageSnapshot(_ usedDollars: Double) {
        let key = Self.localDayKey(Date())
        // Keep the high-water mark for the day (used_credits only rises within a month).
        if let existing = overageEnd[key], existing > usedDollars {
            // lower than what we already saw today → monthly reset mid-day; start fresh
            overageEnd[key] = usedDollars
        } else {
            overageEnd[key] = usedDollars
        }
        // Prune to ~90 days to keep the file small.
        if overageEnd.count > 100 {
            for k in overageEnd.keys.sorted().prefix(overageEnd.count - 90) { overageEnd[k] = nil }
        }
        if let data = try? JSONEncoder().encode(overageEnd) {
            try? data.write(to: Self.ledgerURL)
        }
    }

    static func localDayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

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
        // Load the overage ledger.
        if let data = try? Data(contentsOf: Self.ledgerURL),
           let led = try? JSONDecoder().decode([String: Double].self, from: data) {
            overageEnd = led
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
                if let oauth, let eu = oauth.extra_usage, eu.is_enabled {
                    self.oauthUsage = oauth
                    self.billingEverLoaded = true
                    self.billingStale = false
                    self.extraUsageUnavailable = false
                    self.billingUpdatedAt = Date()
                    self.recordOverageSnapshot(eu.usedDollars)   // bank a real daily data point
                    if let data = try? JSONEncoder().encode(oauth) {
                        try? data.write(to: Self.cacheURL)
                    }
                } else if oauth != nil {
                    // Fetch succeeded but extra-usage isn't enabled on this account.
                    self.extraUsageUnavailable = true
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
        // Prefer real billing. Fall back to the API-equivalent estimate only when
        // extra-usage genuinely isn't enabled on this account (e.g. a Pro-plan user).
        let title: String
        if let eu = oauthUsage?.extra_usage, eu.is_enabled {
            let d = eu.usedDollars
            title = money(d, decimals: d >= 100 ? 0 : 2)
        } else if extraUsageUnavailable {
            let cur = months.first { $0.id == currentMonthKey }?.total ?? 0
            title = "~" + money(cur, decimals: 0)   // estimate (no real billing on this account)
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

    private let r: CGFloat = 16

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: r, style: .continuous)
                            .fill(LinearGradient(
                                colors: [.white.opacity(0.09), .white.opacity(0.015)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: r, style: .continuous)
                            .strokeBorder(LinearGradient(
                                colors: [.white.opacity(0.40), .white.opacity(0.05), .white.opacity(0.14)],
                                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
            )
    }
}

// MARK: - Views

enum BreakdownScope: String, CaseIterable { case today = "Today", month = "Month" }

struct UsageView: View {
    @ObservedObject var store: UsageStore
    @State private var selectedDate: Date?
    @State private var breakdownScope: BreakdownScope = .today
    // Ticks every second while the popover is open so the manual-refresh cooldown
    // re-enables and its countdown updates without needing a state change.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
    // Headline:
    //  • current month, real billing available → real number
    //  • current month, extra-usage not enabled (e.g. Pro plan) → API-equivalent estimate
    //  • current month, billing not fetched yet → "Billing…"
    //  • past months → API-equivalent
    private var headlineText: String {
        if isCurrentMonth && !showingRealBilling {
            if store.extraUsageUnavailable { return money(monthTotal) }   // estimate
            return store.billingEverLoaded ? money(monthTotal) : "Billing…"
        }
        return money(monthTotal)
    }
    // Whether the current view is showing an estimate rather than real billing.
    private var showingEstimate: Bool {
        (isCurrentMonth && store.extraUsageUnavailable) || !isCurrentMonth
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

    private func aggModels(_ ds: [DayUsage]) -> [ModelAgg] {
        var agg: [String: ModelAgg] = [:]
        for d in ds {
            for m in d.models {
                var a = agg[m.name] ?? ModelAgg(id: m.name, name: m.name, cost: 0, tokens: 0)
                a.cost += m.cost
                a.tokens += m.tokens
                agg[m.name] = a
            }
        }
        return agg.values.sorted { $0.cost > $1.cost }
    }

    private var monthModels: [ModelAgg] { aggModels(chartDays) }
    private var todayModels: [ModelAgg] {
        aggModels(chartDays.filter { Calendar.current.isDateInToday($0.date) })
    }
    private var todayTotal: Double {
        chartDays.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = store.errorText, store.oauthUsage == nil {
                GlassCard {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                GlassCard { heroCard.padding(16) }
                GlassCard { breakdown.padding(.horizontal, 16).padding(.vertical, 14) }
            }
            footer
        }
        .padding(16)
        .frame(width: 368)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(ticker) { now = $0 }
    }

    // Unified hero: title + pill, the single big number, cap heat bar, limits, then chart.
    private var heroCard: some View {
        let eu = store.oauthUsage?.extra_usage
        return VStack(alignment: .leading, spacing: 14) {
            // Title row + month nav + chip
            HStack(spacing: 6) {
                Text(showingEstimate ? "Est. usage" : "Extra usage")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .disabled(store.selectedIndex <= 0)
                .opacity(store.selectedIndex <= 0 ? 0.2 : 0.6)
                Text(store.selected?.label ?? "—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Button { step(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .disabled(store.selectedIndex >= store.months.count - 1)
                .opacity(store.selectedIndex >= store.months.count - 1 ? 0.2 : 0.6)
                Spacer()
                if isCurrentMonth && store.extraUsageUnavailable {
                    chip("estimate")   // distinct meaning: not a real bill at all
                }
            }

            // Number + heat bar + stats — tightly grouped as one unit
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(headlineText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    if isCurrentMonth, let eu, eu.is_enabled {
                        Text("of \(money(eu.capDollars, decimals: 0)) cap")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                if isCurrentMonth, let eu, eu.is_enabled {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.35))
                            Capsule()
                                .fill(LinearGradient(colors: [.teal, .orange, .red],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, geo.size.width * min(eu.utilization / 100, 1)))
                                .shadow(color: .orange.opacity(0.35), radius: 4)
                        }
                    }
                    .frame(height: 5)
                    HStack(spacing: 0) {
                        Text("\(Int(eu.utilization))% of cap · \(paceLine)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        if let s = store.oauthUsage?.five_hour, let w = store.oauthUsage?.seven_day {
                            Text("Session \(Int(s.utilization))% · Week \(Int(w.utilization))%")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text(paceLine)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }

            // Chart — its own breathing room below the stats group
            if days.isEmpty {
                Text(store.isLoading ? "Loading…" : "No usage this month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
            } else {
                chart
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
    }

    private func step(_ delta: Int) {
        let next = store.selectedIndex + delta
        guard store.months.indices.contains(next) else { return }
        store.selectedIndex = next
        selectedDate = nil
        // "Today" only makes sense on the current month — default past months to Month,
        // and restore Today when returning to the current month.
        let nowCurrent = store.months[next].id == store.currentMonthKey
        breakdownScope = nowCurrent ? .today : .month
    }

    private var paceLine: String {
        guard monthTotal > 0, !days.isEmpty else { return " " }
        if isCurrentMonth {
            let cal = Calendar.current
            let dayOfMonth = cal.component(.day, from: Date())
            let daysInMonth = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
            let avg = monthTotal / Double(max(dayOfMonth, 1))
            let pace = avg * Double(daysInMonth)
            return "\(money(avg, decimals: 0))/day · pacing \(money(pace, decimals: 0))"
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
                AxisGridLine().foregroundStyle(.white.opacity(0.07))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v >= 1000 ? String(format: "$%.1fk", v / 1000) : String(format: "$%.0f", v))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.quaternary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.padding(.trailing, 4).padding(.leading, 2)
        }
        .frame(height: 132)
    }

    // Per-model breakdown. Defaults to today; toggle to month; hovering the chart
    // overrides to that day.
    // "Today" only applies on the current month; past months always use month totals.
    private var effectiveScopeIsToday: Bool { isCurrentMonth && breakdownScope == .today }
    private var breakdownModels: [ModelAgg] {
        if let d = selectedDay { return d.models }
        return effectiveScopeIsToday ? todayModels : monthModels
    }
    private var breakdownTotal: Double {
        if let d = selectedDay { return d.cost }
        return effectiveScopeIsToday ? todayTotal : monthTotal
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                if let d = selectedDay {
                    Text(d.displayDate)
                        .font(.system(size: 12, weight: .semibold))
                } else if isCurrentMonth {
                    // Today/Month toggle only on the current month
                    Picker("", selection: $breakdownScope) {
                        ForEach(BreakdownScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                } else {
                    // Past months: no "today" exists — just label the month total
                    Text("By model")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Text(money(breakdownTotal))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .frame(height: 22)
            // Fixed-height list (5 rows visible, scrolls if more) so the window
            // never resizes on hover/toggle — keeps it smooth.
            ScrollView {
                VStack(spacing: 11) {
                    if breakdownModels.isEmpty {
                        Text(effectiveScopeIsToday && selectedDay == nil
                             ? "No usage yet today" : "No usage")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                    ForEach(breakdownModels) { m in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(modelColor(m.name))
                                .frame(width: 7, height: 7)
                                .shadow(color: modelColor(m.name).opacity(0.6), radius: 3)
                            Text(m.name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.85))
                            Spacer()
                            Text("\(tokens(m.tokens)) tok")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.quaternary)
                            Text(money(m.cost))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .frame(width: 72, alignment: .trailing)
                                .contentTransition(.numericText())
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 120)
            .scrollIndicators(.never)

            // Real overage billed today — the exact, counter-differenced number.
            // Distinct from the API-list estimate above. Current month + no day hovered.
            if isCurrentMonth && selectedDay == nil {
                Divider().opacity(0.4)
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 8))
                    if let real = store.realOverage(forDayKey: UsageStore.localDayKey(Date())) {
                        Text("Billed today")
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text(money(real))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    } else {
                        Text("Real daily billing tracks from tomorrow")
                            .font(.system(size: 9.5))
                        Spacer()
                    }
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if store.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(footerStatus)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoading || !canManualRefresh)
            .opacity(store.isLoading || !canManualRefresh ? 0.35 : 1)
            .help(refreshTooltip)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit")
        }
    }

    // Manual-refresh gating, recomputed each tick via `now`.
    private var canManualRefresh: Bool {
        _ = now   // depend on the ticker so this re-evaluates over time
        return store.manualRefreshAllowed
    }
    private var refreshTooltip: String {
        _ = now
        let remaining = store.manualCooldownRemaining
        if remaining <= 0 { return "Refresh now" }
        let m = Int(remaining) / 60, s = Int(remaining) % 60
        return m > 0 ? "Refresh available in \(m)m \(s)s" : "Refresh available in \(s)s"
    }

    // Quiet freshness line. Shows last successful billing time, with a subtle
    // "· cached" when the latest live fetch failed (e.g. rate limited) and "· retrying"
    // while a refresh is in flight.
    private var footerStatus: String {
        let t = store.billingUpdatedAt ?? store.lastUpdated
        let stamp = t.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Loading…"
        if store.isLoading { return stamp + " · retrying" }
        if store.billingStale { return stamp + " · cached" }
        return stamp
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
        let host = NSHostingController(rootView: UsageView(store: store))
        host.sizingOptions = [.preferredContentSize]   // let SwiftUI drive the popover size
        popover.contentViewController = host

        store.onStatusUpdate = { [weak self] title in
            self?.statusItem.button?.title = title
        }

        store.refresh()
        // Background refresh every 30 min. No refresh-on-open — that endpoint shares a
        // rolling rate limit with the Claude Code CLI, so opening the popover never fetches.
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
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
