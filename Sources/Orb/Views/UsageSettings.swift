import SwiftUI
import Charts

// Ajustes → Uso: what the Orbs spent, by period, Orb, model and hour of the day. Everything comes from the history the app keeps
// on this Mac (`uso/`, see `UsageRecord.swift`); the page reads it when it opens, when the period changes and when the app
// comes back to the front, never on a timer.

/// The words and numbers of the page.
enum UsageFormat {
    private static let locale = Locale.app

    /// "US$ 12,40"; below a cent "< US$ 0,01".
    static func dollars(_ value: Double) -> String {
        if value > 0 && value < 0.005 { return "< US$ 0,01" }
        return "US$ " + value.formatted(.number.precision(.fractionLength(2)).locale(locale))
    }

    /// "3,5 mil tokens", "1,8 milhão de tokens".
    static func tokens(_ count: Int) -> String {
        let said = ContextWords.approx(count)
        return said + (said.hasSuffix("lhão") || said.hasSuffix("lhões") ? " de tokens" : " tokens")
    }

    static func requests(_ count: Int) -> String { count == 1 ? "1 pedido" : "\(count.formatted(.number.locale(locale))) pedidos" }

    /// "42%"; below one percent "< 1%".
    static func share(_ fraction: Double) -> String {
        fraction > 0 && fraction < 0.005 ? "< 1%" : "\(Int((fraction * 100).rounded()))%"
    }

    /// "14h": the hour of the day.
    static func hour(_ value: Int) -> String { "\(value)h" }

    /// A price the user typed: "2,5" and "2.5" are the same; nothing else is a number.
    static func parsePrice(_ text: String) -> Double? {
        let clean = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !clean.isEmpty, let value = Double(clean), value.isFinite, value >= 0, value <= ModelPrice.highestAllowed else { return nil }
        return value
    }

    static func priceText(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...4)).locale(locale).grouping(.never)) } ?? ""
    }
}

/// Loads and holds the report of the page. The reading and the sums happen off the main thread; a slower answer to an older
/// request never replaces a newer one.
@MainActor @Observable
final class UsageModel {
    private(set) var report: UsageReport?
    private var generation = 0

    func reload(model: AppModel, period: UsagePeriod, now: Date = .now, calendar: Calendar = .current, animation: Animation?) async {
        generation += 1
        let mine = generation
        model.usageLog.flush() // what the turns just used is on its way to the disk: the read below waits for it
        let interval = period.interval(now: now, calendar: calendar)
        let read = await model.store.readUsage(from: interval.start, to: interval.end, calendar: calendar)
        let orbs = Dictionary(model.bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let book = model.priceBook
        let made = await Task.detached(priority: .userInitiated) {
            UsageReport.make(buckets: read.buckets, period: period, now: now, calendar: calendar, book: book, orbNames: orbs,
                             rememberedNames: read.names)
        }.value
        guard mine == generation else { return }
        for notice in read.notices { model.addNotice(AppModel.described(notice, bots: model.bots, routines: model.routines)) }
        withAnimation(animation) { report = made }
    }
}

struct UsageSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("usagePeriod") private var storedPeriod = UsagePeriod.week.rawValue
    @AppStorage("usageChartBy") private var chartBy = UsageChartBy.orb.rawValue
    @State private var usage = UsageModel()
    @State private var editingPrice: String?

    private var period: UsagePeriod { UsagePeriod(rawValue: storedPeriod) ?? .week }
    private var animation: Animation? { reduceMotion ? nil : Motion.content }

    var body: some View {
        Form {
            Section {
                Picker("Período", selection: $storedPeriod) {
                    ForEach(UsagePeriod.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(Tip.usagePeriod)
            }
            if let report = usage.report {
                if report.isEmpty {
                    emptyState(report)
                } else {
                    totalSection(report)
                    chartSection(report)
                    rowsSection("Por Orb", rows: report.orbRows, report: report, isModel: false)
                    rowsSection("Por modelo", rows: report.modelRows, report: report, isModel: true)
                    hourSection(report)
                }
                Section {} footer: { FormFootnote { note } }
            }
        }
        .formStyle(.grouped)
        .orbFormBackground()
        .task(id: storedPeriod) { await reload() }
        .onChange(of: model.priceCorrections) { Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await reload() } }
    }

    private func reload() async {
        await usage.reload(model: model, period: period, animation: animation)
    }

    // MARK: Pieces

    private func emptyState(_ report: UsageReport) -> some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 26))
                    .foregroundStyle(Palette.hint)
                    .accessibilityHidden(true)
                Text(report.period == .today ? "Nada gasto hoje" : "Nada gasto neste período")
                    .font(.headline)
                Text("Cada resposta dos seus Orbs aparece aqui, com o que custou. Isso fica só neste Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private func totalSection(_ report: UsageReport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(UsageFormat.dollars(report.totalCost))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                Text("estimado · \(UsageFormat.tokens(report.totalTokens)) · \(UsageFormat.requests(report.totalRequests))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                if report.totalEquivalent > 0 {
                    Text("Mais ≈ \(UsageFormat.dollars(report.totalEquivalent)) no que os planos cobrem, pelo preço da API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if report.totalCost == 0 && !report.hasUnpriced {
                    Text("Nada foi cobrado: só planos e modelos no seu Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if report.hasUnpriced {
                    Label("Parte do uso é de modelos sem preço. Defina o preço em “Por modelo”.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .animation(animation, value: report.totalCost)
        }
    }

    private func chartSection(_ report: UsageReport) -> some View {
        let byOrb = chartBy == UsageChartBy.orb.rawValue
        let series = byOrb ? report.orbSeries : report.modelSeries
        let points = byOrb ? report.orbPoints : report.modelPoints
        let colors = series.enumerated().map { seriesColor($0.element, index: $0.offset, byOrb: byOrb) }
        let unit = report.period.barUnit
        let end = Calendar.current.dateInterval(of: unit, for: report.interval.end)?.end ?? report.interval.end
        return Section {
            Picker("Cores por", selection: $chartBy) {
                ForEach(UsageChartBy.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(Tip.usageChartBy)
            Chart(points) { point in
                BarMark(x: .value(unit == .hour ? "Hora" : "Dia", point.date, unit: unit),
                        y: .value(report.measure == .cost ? "Dólares" : "Tokens", point.value))
                    .foregroundStyle(by: .value("Série", point.series))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: series.map(\.id), range: colors)
            .chartLegend(.hidden)
            .environment(\.locale, .app)
            .chartXScale(domain: report.interval.start...end)
            .chartXAxis {
                AxisMarks(values: unit == .hour ? .stride(by: .hour, count: 3) : .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(Palette.line)
                    AxisValueLabel(format: unit == .hour ? .dateTime.hour() : .dateTime.day().month(.abbreviated))
                        .foregroundStyle(Palette.faint)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Palette.line)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(report.measure == .cost ? UsageFormat.dollars(number) : ContextWords.approx(Int(number)))
                                .foregroundStyle(Palette.faint)
                        }
                    }
                }
            }
            .frame(height: 150)
            .animation(animation, value: points)
            .accessibilityLabel("Gráfico do uso por \(unit == .hour ? "hora" : "dia")")
            .accessibilityValue(chartSummary(report))
            legend(series, colors: colors)
        } header: {
            Text(report.measure == .cost ? "Gasto por \(unit == .hour ? "hora" : "dia")" : "Tokens por \(unit == .hour ? "hora" : "dia")")
        }
    }

    private func legend(_ series: [UsageSeries], colors: [Color]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 6) {
                    Circle().fill(colors[index]).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func chartSummary(_ report: UsageReport) -> String {
        "Total de \(UsageFormat.dollars(report.totalCost)) e \(UsageFormat.tokens(report.totalTokens))"
    }

    /// An Orb's chart color is its own; models take a fixed sequence, and "Outros" the quiet gray.
    private func seriesColor(_ series: UsageSeries, index: Int, byOrb: Bool) -> Color {
        if series.id == UsageReport.othersID { return Palette.hint }
        if byOrb, let id = UUID(uuidString: series.id), let bot = model.bot(id) { return OrbCatalog.shared.palette(bot.orb.color).core }
        if byOrb { return Palette.faint }
        return Self.modelColors[index % Self.modelColors.count]
    }

    private static let modelColors = [Palette.accentText, Color(hex: 0x8F7BFF), Color(hex: 0x2BC4A0), Color(hex: 0xFF8A3D), Color(hex: 0xFF7AB6)]

    private func rowsSection(_ title: String, rows: [UsageRow], report: UsageReport, isModel: Bool) -> some View {
        Section {
            ForEach(rows) { row in
                UsageRowView(row: row, measure: report.measure, isModel: isModel) { editingPrice = row.id }
                    .popover(isPresented: Binding(get: { editingPrice == row.id }, set: { if !$0 { editingPrice = nil } }),
                             arrowEdge: .trailing) {
                        PriceEditor(modelID: row.id, title: row.name) { editingPrice = nil }
                    }
            }
        } header: {
            Text(title)
        }
        .animation(animation, value: rows)
    }

    private func hourSection(_ report: UsageReport) -> some View {
        let peak = report.hourly.max() ?? 0
        let busiest = peak > 0 ? report.hourly.firstIndex(of: peak) : nil
        return Section {
            VStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { hour in
                        let fraction = peak > 0 ? Double(report.hourly[hour]) / Double(peak) : 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(hour == busiest ? Palette.ink : Palette.faint.opacity(0.55))
                            .frame(height: max(3, 44 * fraction))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 44, alignment: .bottom)
                .animation(animation, value: report.hourly)
                HStack {
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text(UsageFormat.hour(hour)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("24h").frame(alignment: .trailing)
                }
                .font(.caption2)
                .foregroundStyle(Palette.faint)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Uso por hora do dia")
            .accessibilityValue(busiest.map { "Mais uso entre \(UsageFormat.hour($0)) e \(UsageFormat.hour(($0 + 1) % 24))" } ?? "Sem uso")
        } header: {
            Text("Por horário")
        } footer: { FormFootnote {
            if let busiest {
                Text("Você usa mais entre \(UsageFormat.hour(busiest)) e \(UsageFormat.hour((busiest + 1) % 24)).")
            }
        } }
    }

    private var note: some View {
        Text("Estimativa pelos preços públicos de \(PriceTable.consultedText); o valor cobrado pelo provedor pode variar. "
            + "Os preços das listas do OpenRouter e da OpenCode vêm delas. A DeepSeek cobra o dobro nos horários de pico (dias úteis, 01h às 04h e 06h às 10h UTC); a conta já separa os dois. Assinaturas e modelos no seu Mac não são cobrados por token.")
    }
}

/// What the chart's colors are by.
enum UsageChartBy: String, CaseIterable, Identifiable {
    case orb, model

    var id: String { rawValue }
    var title: String { self == .orb ? "Por Orb" : "Por modelo" }
}

/// A line of "Por Orb" or "Por modelo": the name, what it used, what it cost (or why not), its share.
private struct UsageRowView: View {
    let row: UsageRow
    let measure: UsageMeasure
    let isModel: Bool
    let editPrice: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 2) {
                    amount
                    if let share = row.share, row.state == .billed || measure == .tokens {
                        Text(UsageFormat.share(share)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isModel && row.state != .free {
                    Button(action: editPrice) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(row.isCorrected ? Palette.accentText : Palette.muted)
                    .help(row.isCorrected ? Tip.priceCorrected : Tip.priceCorrect)
                    .accessibilityLabel("Corrigir o preço de \(row.name)")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var amount: some View {
        switch row.state {
        case .billed:
            Text(UsageFormat.dollars(row.cost)).monospacedDigit()
        case .included:
            Text("Incluído no plano").foregroundStyle(Palette.secondary)
            if row.equivalent > 0 {
                Text("≈ \(UsageFormat.dollars(row.equivalent)) pela API").font(.caption).foregroundStyle(.secondary)
            }
        case .free:
            Text("Grátis").foregroundStyle(Palette.secondary)
        case .unpriced:
            if isModel {
                Button("Sem preço", action: editPrice).buttonStyle(.link).foregroundStyle(Palette.warn)
                    .help(Tip.priceMissing)
            } else {
                Text("Sem preço").foregroundStyle(Palette.warn)
            }
        }
        if row.state == .billed && row.hasUnpriced {
            Text("e uso sem preço").font(.caption).foregroundStyle(Palette.warn)
        }
    }

    private var detail: String {
        var parts = [UsageFormat.tokens(row.tokens), UsageFormat.requests(row.requests)]
        if let provider = row.detail { parts.append(provider) }
        return parts.joined(separator: " · ")
    }
}

/// The four prices of the editor as the person sees them (text), and the price they say.
struct PriceDraft: Equatable {
    var input = "", cacheRead = "", cacheWrite = "", output = ""

    init(_ price: ModelPrice?) {
        guard let price else { return }
        input = UsageFormat.priceText(price.input)
        cacheRead = UsageFormat.priceText(price.cacheRead)
        cacheWrite = UsageFormat.priceText(price.cacheWrite)
        output = UsageFormat.priceText(price.output)
    }

    /// nil while a field is not a number. A cache field left empty means "same as the input". The hour-long cache write,
    /// which has no field, keeps its proportion to the five-minute one of `was`, so editing never drops a part of the price.
    func price(replacing was: ModelPrice?) -> ModelPrice? {
        func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let input = UsageFormat.parsePrice(input), let output = UsageFormat.parsePrice(output) else { return nil }
        let read = blank(cacheRead) ? nil : UsageFormat.parsePrice(cacheRead)
        let write = blank(cacheWrite) ? nil : UsageFormat.parsePrice(cacheWrite)
        if (!blank(cacheRead) && read == nil) || (!blank(cacheWrite) && write == nil) { return nil }
        var hourLong: Double?
        if let write, let oldWrite = was?.cacheWrite, oldWrite > 0, let oldHour = was?.cacheWrite1h { hourLong = write * oldHour / oldWrite }
        return ModelPrice(input: input, cacheRead: read, cacheWrite: write, cacheWrite1h: hourLong, output: output)
    }
}

/// The popover that corrects one model's price: four numbers, in dollars per million tokens.
private struct PriceEditor: View {
    @Environment(AppModel.self) private var model
    let modelID: String
    let title: String
    let close: () -> Void
    @State private var draft = PriceDraft(nil)
    @State private var opened = PriceDraft(nil)
    @FocusState private var focus: Field?

    private enum Field { case input, cacheRead, cacheWrite, output }

    private var current: (price: ModelPrice, source: PriceSource)? { model.priceBook.price(for: modelID, at: .now) }
    private var typed: ModelPrice? { draft.price(replacing: current?.price) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preço de \(title)").font(.headline).lineLimit(1)
                Text(sourceText).font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                field("Entrada", text: $draft.input, focus: .input)
                field("Entrada do cache", text: $draft.cacheRead, focus: .cacheRead, placeholder: "igual à entrada")
                field("Gravação no cache", text: $draft.cacheWrite, focus: .cacheWrite, placeholder: "igual à entrada")
                field("Saída", text: $draft.output, focus: .output)
            }
            Text("Em dólares por milhão de tokens. Vale também para o que já foi gasto.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.priceCorrections[modelID] != nil {
                    Button("Restaurar") { model.correctPrice(of: modelID, to: nil); close() }
                        .help(Tip.priceRestore)
                }
                Spacer()
                Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    if let typed, draft != opened { model.correctPrice(of: modelID, to: typed) }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(typed == nil)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            draft = PriceDraft(current?.price)
            opened = draft
            focus = .input
        }
    }

    private func field(_ label: String, text: Binding<String>, focus field: Field, placeholder: String = "0") -> some View {
        GridRow {
            Text(label).font(.callout)
            TextField(label, text: text, prompt: Text(placeholder))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: field)
                .frame(width: 110)
        }
    }

    private var sourceText: String {
        switch current?.source {
        case .corrected?: "Corrigido por você."
        case .catalog?: "O preço vem da lista do provedor."
        case .table?: "O preço vem da tabela do Orb, de \(PriceTable.consultedText)."
        case nil: "O Orb não conhece o preço deste modelo."
        }
    }
}
