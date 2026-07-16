import AppKit

/// 使用統計 pane — a privacy-preserving usage dashboard. Reads
/// `UsageStatsStore` (counts only, never transcript content) and lays the
/// numbers out in the same System Settings grouped-card language as the other
/// panes: 今日 / 近 7 日 (a monochrome bar chart) / 累計.
extension PreferencesWindowController {

    func makeDashboardContent() -> NSView {
        // ── Group 1: 今日 ─────────────────────────────────────
        let todayChars    = statValueLabel("0")
        let todaySegments = statValueLabel("0")
        let todayDuration = statValueLabel("0 分鐘")
        dashboardTodayChars    = todayChars
        dashboardTodaySegments = todaySegments
        dashboardTodayDuration = todayDuration
        let todayCard = DesignTokens.groupCard([
            DesignTokens.row(title: "輸入字數", control: todayChars),
            DesignTokens.row(title: "聽寫次數", control: todaySegments),
            DesignTokens.row(title: "語音時長", control: todayDuration),
        ])

        // ── Group 2: 近 7 日 (bar chart) ──────────────────────
        let chart = UsageBarChartView()
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 140).isActive = true
        dashboardChart = chart
        let chartWrap = NSView()
        chartWrap.translatesAutoresizingMaskIntoConstraints = false
        chartWrap.addSubview(chart)
        NSLayoutConstraint.activate([
            chart.topAnchor.constraint(equalTo: chartWrap.topAnchor, constant: 14),
            chart.bottomAnchor.constraint(equalTo: chartWrap.bottomAnchor, constant: -14),
            chart.leadingAnchor.constraint(equalTo: chartWrap.leadingAnchor, constant: 16),
            chart.trailingAnchor.constraint(equalTo: chartWrap.trailingAnchor, constant: -16),
        ])
        let weekCard = DesignTokens.groupCard([chartWrap])

        // ── Group 3: 累計 ─────────────────────────────────────
        let totalChars    = statValueLabel("0")
        let totalSegments = statValueLabel("0")
        let totalDuration = statValueLabel("0 分鐘")
        let avgChars      = statValueLabel("0")
        dashboardTotalChars    = totalChars
        dashboardTotalSegments = totalSegments
        dashboardTotalDuration = totalDuration
        dashboardAvgChars      = avgChars
        let totalCard = DesignTokens.groupCard([
            DesignTokens.row(title: "總字數", control: totalChars),
            DesignTokens.row(title: "總次數", control: totalSegments),
            DesignTokens.row(title: "總語音時長", control: totalDuration),
            DesignTokens.row(title: "平均每次字數", control: avgChars),
        ])

        let hint = DesignTokens.caption(
            "只統計數字，絕不儲存轉錄內容。右 ⌥ 聽寫與右 ⌘ 翻譯各計一次；" +
            "口頭修正（右 Shift）與選字潤飾（Option＋P）不列入統計。")

        // ── Assemble ──────────────────────────────────────────
        let stack = NSStackView(views: [
            DesignTokens.group(title: "今日", card: todayCard),
            DesignTokens.group(title: "近 7 日", card: weekCard),
            DesignTokens.group(title: "累計", card: totalCard, footnote: hint),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.section
        for group in stack.arrangedSubviews {
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        refreshDashboard()
        return stack
    }

    /// Reload every value from `UsageStatsStore`. Nil-safe: the dashboard pane
    /// may not have been built yet when this is called from showPane/showPreferences.
    func refreshDashboard() {
        guard dashboardTodayChars != nil else { return }
        let store = UsageStatsStore.shared
        let today = store.today()

        setStatValue(dashboardTodayChars, Self.grouped(today.chars))
        setStatValue(dashboardTodaySegments, Self.grouped(today.segments))
        setStatValue(dashboardTodayDuration, Self.formatDuration(today.durationMs))

        setStatValue(dashboardTotalChars, Self.grouped(store.totalChars))
        setStatValue(dashboardTotalSegments, Self.grouped(store.totalSegments))
        setStatValue(dashboardTotalDuration, Self.formatDuration(store.totalDurationMs))
        let avg = store.totalSegments > 0 ? store.totalChars / store.totalSegments : 0
        setStatValue(dashboardAvgChars, Self.grouped(avg))

        dashboardChart?.setData(store.last7Days())
    }

    // MARK: - Value formatting

    /// A right-hand value label styled like a status-row value.
    private func statValueLabel(_ text: String) -> NSTextField {
        DesignTokens.styledLabel(text, size: 13, weight: .semibold, kern: -0.2,
                                 color: DesignTokens.Palette.ink)
    }

    /// Rebuild an attributed value in place (setting `stringValue` on an
    /// attributed label would drop the kerning/weight).
    private func setStatValue(_ label: NSTextField?, _ text: String) {
        label?.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: DesignTokens.uiFont(13, weight: .semibold),
            .kern: -0.2,
            .foregroundColor: DesignTokens.Palette.ink,
        ])
    }

    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// Thousands-separated integer.
    static func grouped(_ n: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// < 60 min → "N 分鐘"; otherwise "H 小時 M 分".
    static func formatDuration(_ ms: Int) -> String {
        let totalMinutes = ms / 60_000
        if totalMinutes < 60 { return "\(totalMinutes) 分鐘" }
        return "\(totalMinutes / 60) 小時 \(totalMinutes % 60) 分"
    }
}

/// Monochrome 7-bar chart of daily character counts. Pure `draw(_:)` (no
/// CALayer fills) so colours re-resolve correctly on light/dark switches —
/// drawing runs inside the view's current appearance context.
final class UsageBarChartView: NSView {

    private var days: [UsageStatsStore.DayStat] = []

    func setData(_ days: [UsageStatsStore.DayStat]) {
        self.days = days
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let maxChars = days.map(\.chars).max() ?? 0

        // Empty state: nothing recorded in the last 7 days.
        guard maxChars > 0 else {
            drawCentered("還沒有資料", color: DesignTokens.Palette.inkMuted(0.45),
                         font: DesignTokens.uiFont(12))
            return
        }

        let count = max(days.count, 1)
        let labelStripH: CGFloat = 18   // date labels along the bottom
        let topPad: CGFloat = 6
        let sidePad: CGFloat = 2
        let gap: CGFloat = 10
        let chartH = max(bounds.height - labelStripH - topPad, 1)
        let barW = max((bounds.width - 2 * sidePad - gap * CGFloat(count - 1)) / CGFloat(count), 1)

        let barColor = DesignTokens.Palette.ink.withAlphaComponent(0.82)
        let dateColor = DesignTokens.Palette.inkMuted(0.4)
        let dateFont = DesignTokens.uiFont(11)

        for (i, day) in days.enumerated() {
            let x = sidePad + CGFloat(i) * (barW + gap)

            // Bar (nonzero days get at least a 3-pt sliver so a light day is visible).
            let ratio = CGFloat(day.chars) / CGFloat(maxChars)
            let barHeight = day.chars > 0 ? max(chartH * ratio, 3) : 0
            if barHeight > 0 {
                let rect = NSRect(x: x, y: labelStripH, width: barW, height: barHeight)
                let radius = min(4, barW / 2)
                barColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }

            // Date label (M/d) centred under the bar.
            let label = Self.monthDay(day.date)
            let attrs: [NSAttributedString.Key: Any] = [.font: dateFont, .foregroundColor: dateColor]
            let size = label.size(withAttributes: attrs)
            let labelX = x + (barW - size.width) / 2
            let labelY = (labelStripH - size.height) / 2
            label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)
        }
    }

    private func drawCentered(_ text: String, color: NSColor, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }

    /// "yyyy-MM-dd" → "M/d" (leading zeros stripped).
    private static func monthDay(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return date }
        return "\(m)/\(d)"
    }
}
