import Foundation

/// Recovers a plan's absolute 168h token allowance from this machine's own logs.
///
/// Why this exists: the usage API publishes only a percentage (`used_percent`) and
/// never an absolute cap, so the allowance can only be recovered as a ratio. The
/// online analytics endpoint is a poor numerator — it serves whole-day buckets,
/// omits the current day, and does not align with the rolling window. The local
/// `token_count` events are a good numerator: they carry the turn's token delta,
/// the window's `resets_at`, and a millisecond timestamp, so tokens and percentage
/// can be sampled at the same instant.
///
/// The window that identifies an account is `(plan_type, window_minutes,
/// resets_at)`. `resets_at` survives 5-hour window rollovers, which is what lets
/// one account's samples be reassembled across sessions — and what keeps two
/// different accounts apart.
public struct LocalQuotaAllowanceScanner: Sendable {
    public var codexHome: URL

    /// Model → price, for turning tokens into dollars.
    ///
    /// Injected rather than read from the bundled table directly, so the app can
    /// pass the *same* price book its API-equivalent cost uses. The bundled table
    /// and the live one can disagree — `gpt-5.6-sol` is 5/0.5/30 built-in but
    /// 4/0.4/20 live — and quoting a different price here than the rest of the
    /// panel would make the two figures irreconcilable.
    public var priceForModel: @Sendable (String) -> PricingTable.Price?

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex"),
        priceForModel: @escaping @Sendable (String) -> PricingTable.Price? = { PricingTable.price(for: $0) })
    {
        self.codexHome = codexHome
        self.priceForModel = priceForModel
    }

    // Local logs are the only source; nothing is fetched.
    private var fileManager: FileManager { .default }

    /// Weekly window length. Named so callers do not repeat the magic number.
    public static let weeklyWindowMinutes = 10_080

    /// Scans local sessions and fits one allowance per distinct quota window.
    ///
    /// - Parameter lookbackDays: how far back to read. Session logs reach gigabytes,
    ///   and a window is at most a week long, so the default stays well clear.
    public func scan(
        now: Date = Date(),
        windowMinutes: Int = Self.weeklyWindowMinutes,
        lookbackDays: Int = 21
    ) -> [LocalQuotaAllowance] {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        var byKey: [WindowKey: [Segment]] = [:]

        for file in sessionFiles(since: cutoff, now: now) {
            for segment in segments(in: file, windowMinutes: windowMinutes, cutoff: cutoff) {
                byKey[segment.key, default: []].append(segment)
            }
        }

        return byKey.compactMap { key, group in
            Self.allowance(for: key, segments: group, now: now)
        }
        .sorted { $0.resetsAt > $1.resetsAt }
    }

    /// The window an account belongs to, independent of which session observed it.
    struct WindowKey: Hashable, Sendable {
        var plan: String
        var windowMinutes: Int
        /// The reset instant **in whole minutes since the epoch**. The server's
        /// value jitters by a few seconds between responses (observed ±5s), and
        /// treating that jitter as a new window would split one account into
        /// several, so the seconds are dropped here rather than stored verbatim.
        var resetsAtMinute: Int
    }

    /// One contiguous run of a single file that belongs to one window.
    struct Segment: Sendable {
        var key: WindowKey
        /// `(used_percent, cumulative tokens)` sampled together at one instant.
        var samples: [(percent: Double, tokens: Double)]
        /// Per-turn cost, index-aligned with `samples`. An unpriced turn holds nil
        /// rather than being skipped, so a missing price cannot shift the alignment
        /// of every later sample.
        var sampleCosts: [Double?] = []
        /// True once any turn in this segment used an unpriced model.
        var hasUnpricedModel = false
        /// Token parts consumed in this segment, for the mix breakdown.
        var uncachedInput = 0.0
        var cachedInput = 0.0
        var cacheWriteInput = 0.0
        var output = 0.0
        /// Instants matching `samples`, so points can be labelled with a time.
        var sampleTimes: [Date] = []
        /// Models seen in this segment.
        var models: Set<String> = []
    }

    // MARK: - Fitting

    static func allowance(
        for key: WindowKey,
        segments: [Segment],
        now: Date
    ) -> LocalQuotaAllowance? {
        // Each segment is fitted on its own and the slopes are pooled, because a
        // session's token counter has its own baseline: it restarts on a new session
        // and does not reset when the account flips mid-session. Rebasing and pooling
        // the raw points instead would need each session's absolute origin, which is
        // not recorded — a one-sample session carries no slope at all.
        var weightedSlope = 0.0
        var weightedRSquared = 0.0
        var totalWeight = 0.0
        var sampleCount = 0
        var minPercent = Double.infinity
        var maxPercent = -Double.infinity
        // The window's current position. The percentage only ever rises inside a
        // window, so the maximum observed is also the most recent.
        var usedPercent = 0.0

        for segment in segments {
            for sample in segment.samples {
                minPercent = min(minPercent, sample.percent)
                maxPercent = max(maxPercent, sample.percent)
                usedPercent = max(usedPercent, sample.percent)
            }
            sampleCount += segment.samples.count
            let tokenPoints = segment.samples.map { (x: $0.percent, y: $0.tokens) }
            guard let fit = fitLinear(tokenPoints) else { continue }
            // Weight by the percentage span: a segment covering 20 points pins the
            // slope far better than one covering 1.
            weightedSlope += fit.slope * fit.span
            weightedRSquared += fit.rSquared * fit.span
            totalWeight += fit.span
        }

        guard totalWeight > 0 else { return nil }
        let slope = weightedSlope / totalWeight
        guard slope.isFinite, slope > 0 else { return nil }

        // The USD allowance is fitted the same way, independently per segment. It
        // needs its own fit rather than `tokenSlope * price` because one window can
        // mix models at very different rates.
        var costSlopeNumerator = 0.0
        var costWeight = 0.0
        var hasUnpriced = false
        for segment in segments {
            if segment.hasUnpricedModel { hasUnpriced = true }
            // A segment's cost series is cumulative *within the segment*, because a
            // session's own counter restarts. Built here from the per-turn
            // increments so an unpriced turn cannot shift the alignment.
            var running = 0.0
            var costPoints: [(x: Double, y: Double)] = []
            for (index, cost) in segment.sampleCosts.enumerated() {
                guard let cost, index < segment.samples.count else { continue }
                running += cost
                costPoints.append((x: segment.samples[index].percent, y: running))
            }
            guard let fit = fitLinear(costPoints) else { continue }
            costSlopeNumerator += fit.slope * fit.span
            costWeight += fit.span
        }
        // A partial sum would understate the allowance, so an unpriced model
        // suppresses the figure instead of quietly dropping its cost.
        let allowanceUSD: Double? = (!hasUnpriced && costWeight > 0)
            ? (costSlopeNumerator / costWeight) * 100
            : nil

        // Aggregate the token mix and the observed points across every segment of
        // this window, so the detail view describes the window as a whole.
        var breakdown = LocalAllowanceBreakdown()
        var models = Set<String>()
        var collected: [(percent: Double, cost: Double?, at: Date)] = []
        for segment in segments {
            breakdown.uncachedInputTokens += Int(segment.uncachedInput)
            breakdown.cachedInputTokens += Int(segment.cachedInput)
            breakdown.cacheWriteInputTokens += Int(segment.cacheWriteInput)
            breakdown.outputTokens += Int(segment.output)
            models.formUnion(segment.models)
            for (index, sample) in segment.samples.enumerated() {
                let at = index < segment.sampleTimes.count
                    ? segment.sampleTimes[index]
                    : Date(timeIntervalSince1970: TimeInterval(key.resetsAtMinute) * 60)
                let cost = index < segment.sampleCosts.count ? segment.sampleCosts[index] : nil
                collected.append((sample.percent, cost, at))
            }
        }
        breakdown.models = models.sorted()

        // The figure shown must be cumulative across the *window*, not within one
        // session. A session's own cost counter restarts whenever a new rollout
        // begins, so presenting it raw made the spend appear to fall — $20.62 down to
        // $0.23 on an ordinary session change. Accumulating the increments in time
        // order gives the window-wide total, and a turn whose model was unpriced
        // simply leaves the running total where it was.
        collected.sort { $0.at < $1.at }
        var runningTotal = 0.0
        var points: [LocalAllowanceSamplePoint] = []
        for item in collected {
            if let cost = item.cost { runningTotal += cost }
            points.append(LocalAllowanceSamplePoint(
                percent: item.percent,
                cumulativeUSD: runningTotal,
                at: item.at))
        }

        return LocalQuotaAllowance(
            plan: key.plan,
            windowMinutes: key.windowMinutes,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(key.resetsAtMinute) * 60),
            allowanceTokens: slope * 100,
            allowanceUSD: allowanceUSD,
            unpricedTokens: 0,
            usedPercent: usedPercent,
            breakdown: breakdown,
            points: points,
            pricingVersion: PricingTable.version,
            sampleCount: sampleCount,
            rSquared: weightedRSquared / totalWeight,
            percentSpan: maxPercent - minPercent,
            computedAt: now)
    }

    /// Least squares of tokens against percentage, keeping the intercept so each
    /// segment's own baseline drops out.
    /// Least squares of `y` against `x`, where `x` is the meter's percentage.
    ///
    /// Axis-agnostic on purpose: the same fit recovers the allowance in tokens and
    /// in USD, and both need the identical treatment of the percentage axis.
    static func fitLinear(
        _ points: [(x: Double, y: Double)],
        minimumSpan: Double = 0.5
    ) -> (slope: Double, rSquared: Double, span: Double)? {
        // A slope needs the percentage to actually move.
        let percents = points.map(\.x)
        guard let low = percents.min(), let high = percents.max(), high - low >= minimumSpan else {
            return nil
        }
        let samples = points
        let n = Double(samples.count)
        guard samples.count >= 2 else { return nil }

        let sx = samples.reduce(0) { $0 + $1.x }
        let sy = samples.reduce(0) { $0 + $1.y }
        let sxx = samples.reduce(0) { $0 + $1.x * $1.x }
        let sxy = samples.reduce(0) { $0 + $1.x * $1.y }
        let denominator = n * sxx - sx * sx
        guard denominator != 0 else { return nil }

        let slope = (n * sxy - sx * sy) / denominator
        let intercept = (sy - slope * sx) / n
        let meanY = sy / n

        var ssRes = 0.0
        var ssTot = 0.0
        for sample in samples {
            let predicted = slope * sample.x + intercept
            ssRes += (sample.y - predicted) * (sample.y - predicted)
            ssTot += (sample.y - meanY) * (sample.y - meanY)
        }
        // A perfectly flat series has no variance to explain; treat it as a perfect
        // fit only if the residuals are also zero.
        let rSquared = ssTot > 0 ? 1 - ssRes / ssTot : (ssRes == 0 ? 1 : 0)
        return (slope, rSquared, high - low)
    }

    // MARK: - Parsing

    private func sessionFiles(since cutoff: Date, now: Date) -> [URL] {
        ["sessions", "archived_sessions"].flatMap { folder -> [URL] in
            let root = codexHome.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey])
            else { return [] }
            return enumerator.compactMap { $0 as? URL }
                .filter { url in
                    guard url.pathExtension == "jsonl" else { return false }
                    // Session paths are `…/YYYY/MM/DD/rollout-….jsonl`, so the day is
                    // free to read without opening the file.
                    guard let day = Self.dayFromPath(url) else { return true }
                    // A session started before the cutoff can still emit events
                    // inside it, hence the one-day pad.
                    return day >= cutoff.addingTimeInterval(-86_400) && day <= now.addingTimeInterval(86_400)
                }
        }
    }

    /// Walks one file, cutting it into runs of a single window.
    ///
    /// The cut matters: flipping accounts in the Codex app continues the *same*
    /// rollout file, so one file legitimately contains two different plans and two
    /// different windows back to back.
    func segments(
        in file: URL,
        windowMinutes: Int,
        cutoff: Date
    ) -> [Segment] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var finished: [Segment] = []
        var current: Segment?
        // The model in force. Codex emits a `turn_context` before the turns it
        // applies to, and `token_count` itself carries no model, so the active
        // model has to be carried forward from the enclosing turn context.
        var activeModel: String?

        func finishCurrent() {
            if let segment = current, !segment.samples.isEmpty {
                finished.append(segment)
            }
            current = nil
        }

        let newline = UInt8(ascii: "\n")
        var buffer = Data()

        // Read in chunks so a multi-megabyte rollout never lands in memory at once.
        while true {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)

            var start = buffer.startIndex
            while let index = buffer[start...].firstIndex(of: newline) {
                let line = buffer[start..<index]
                start = buffer.index(after: index)
                if let model = Self.modelContext(from: line) {
                    // The display name is what the price table keys on; an empty
                    // value clears the association rather than leaking the previous
                    // turn's model onto later turns.
                    activeModel = model.isEmpty ? nil : model
                } else if let sample = sample(
                    from: line,
                    windowMinutes: windowMinutes,
                    cutoff: cutoff,
                    formatter: formatter,
                    model: activeModel)
                {
                    if current?.key != sample.key {
                        finishCurrent()
                        current = Segment(key: sample.key, samples: [])
                    }
                    current?.samples.append((sample.percent, sample.tokens))
                    current?.sampleTimes.append(sample.at)
                    current?.uncachedInput += sample.uncachedInput
                    current?.cachedInput += sample.cachedInput
                    current?.cacheWriteInput += sample.cacheWriteInput
                    current?.output += sample.output
                    if let model = activeModel { current?.models.insert(model) }
                    current?.sampleCosts.append(sample.cost)
                    if sample.cost == nil { current?.hasUnpricedModel = true }
                }
            }
            buffer = Data(buffer[start...])
            // A single line this long is not a token_count event worth keeping.
            if buffer.count > 8 << 20 { buffer.removeAll(keepingCapacity: false) }
        }

        // A file whose final line lacks a newline still has a sample worth reading,
        // and it is the newest one — the sample the remaining figure most depends on.
        if !buffer.isEmpty {
            if let model = Self.modelContext(from: buffer) {
                activeModel = model.isEmpty ? nil : model
            } else if let sample = sample(
                from: buffer,
                windowMinutes: windowMinutes,
                cutoff: cutoff,
                formatter: formatter,
                model: activeModel)
            {
                if current?.key != sample.key {
                    finishCurrent()
                    current = Segment(key: sample.key, samples: [])
                }
                current?.samples.append((sample.percent, sample.tokens))
                current?.sampleTimes.append(sample.at)
                current?.uncachedInput += sample.uncachedInput
                current?.cachedInput += sample.cachedInput
                current?.cacheWriteInput += sample.cacheWriteInput
                current?.output += sample.output
                if let model = activeModel { current?.models.insert(model) }
                current?.sampleCosts.append(sample.cost)
                if sample.cost == nil { current?.hasUnpricedModel = true }
            }
        }
        finishCurrent()
        return finished
    }

    /// The model a `turn_context` line applies to, or nil when the line is not one.
    ///
    /// Note the asymmetry this handles: `turn_context` puts its type on the outer
    /// object (`{"type":"turn_context","payload":{…"model":…}}`), while
    /// `token_count` puts it inside the payload. Matching on both would misread one
    /// of them.
    static func modelContext(from line: Data) -> String? {
        guard line.count < 2 << 20, line.contains(ascii: "\"turn_context\"") else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "turn_context",
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        return payload["model"] as? String
    }

    struct Sample {
        var key: WindowKey
        var percent: Double
        var tokens: Double
        /// Cost of this turn under the public price table, or nil when the model is
        /// not priced.
        var cost: Double?
        /// Set when a turn's model could not be resolved to a price, so the caller
        /// can refuse to quote a partial USD figure.
        var priced: Bool
        /// Token parts, kept for the segmented cost series.
        var uncachedInput: Double
        var cachedInput: Double
        var cacheWriteInput: Double
        var output: Double
        var at: Date
    }

    /// Extracts one observation, or nil when the line is unrelated.
    func sample(
        from line: Data,
        windowMinutes: Int,
        cutoff: Date,
        formatter: ISO8601DateFormatter,
        model: String?
    ) -> Sample? {
        // Cheap reject before paying for JSON parsing: most lines are tool traffic.
        guard line.count < 2 << 20, line.contains(ascii: "\"token_count\"") else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any],
              let plan = rateLimits["plan_type"] as? String,
              let info = payload["info"] as? [String: Any],
              let totals = info.getTotalTokenUsage(),
              let timestamp = object["timestamp"] as? String,
              let date = formatter.date(from: timestamp),
              date >= cutoff
        else { return nil }

        // Only the window we care about (weekly), from whichever slot holds it: a
        // plan may expose it as primary (team) or secondary (plus).
        guard let window = Self.window(of: rateLimits, minutes: windowMinutes) else { return nil }
        guard let percent = window["used_percent"] as? Double,
              let resetsAt = window["resets_at"] as? Double,
              resetsAt > 0
        else { return nil }

        let parts = Self.tokenParts(from: info)
        // Reuses the app's single pricing implementation, so this figure and the
        // API-equivalent cost in the rest of the panel can never drift apart.
        var cost: Double?
        if let model, let price = priceForModel(model) {
            // Costed with the injected table, so this agrees with the API-equivalent
            // cost shown elsewhere in the panel.
            let money = Decimal(parts.uncached) / 1_000_000 * price.inputPerMillion
                + Decimal(parts.cached) / 1_000_000 * price.cachedInputPerMillion
                + Decimal(parts.cacheWrite) / 1_000_000 * (price.cacheWritePerMillion ?? price.inputPerMillion)
                + Decimal(parts.output) / 1_000_000 * price.outputPerMillion
            cost = NSDecimalNumber(decimal: money).doubleValue
        }

        return Sample(
            key: WindowKey(
                plan: plan,
                windowMinutes: windowMinutes,
                resetsAtMinute: Int(resetsAt) / 60),
            percent: percent,
            tokens: totals,
            cost: cost,
            priced: cost != nil,
            uncachedInput: parts.uncached,
            cachedInput: parts.cached,
            cacheWriteInput: parts.cacheWrite,
            output: parts.output,
            at: date)
    }

    /// This turn's token parts. `input_tokens` already includes the cached portion,
    /// so the uncached part is the difference.
    static func tokenParts(from info: [String: Any]) -> (
        uncached: Double, cached: Double, cacheWrite: Double, output: Double
    ) {
        let usage = (info["last_token_usage"] as? [String: Any]) ?? [:]
        let input = number(usage["input_tokens"])
        let cached = number(usage["cached_input_tokens"])
        return (
            uncached: max(0, input - cached),
            cached: cached,
            cacheWrite: number(usage["cache_write_input_tokens"]),
            output: number(usage["output_tokens"]))
    }

    static func number(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return 0
    }

    static func window(of rateLimits: [String: Any], minutes: Int) -> [String: Any]? {
        for slot in ["primary", "secondary"] {
            guard let candidate = rateLimits[slot] as? [String: Any],
                  let declared = candidate["window_minutes"] as? Double,
                  Int(declared) == minutes
            else { continue }
            return candidate
        }
        return nil
    }

    static func dayFromPath(_ url: URL) -> Date? {
        // …/sessions/YYYY/MM/DD/rollout-….jsonl
        let parts = url.pathComponents
        guard let dayIndex = parts.lastIndex(of: "sessions") ?? parts.lastIndex(of: "archived_sessions"),
              dayIndex + 3 < parts.count,
              let year = Int(parts[dayIndex + 1]),
              let month = Int(parts[dayIndex + 2]),
              let day = Int(parts[dayIndex + 3])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// `total_tokens` is the cumulative counter; `input_tokens` already includes
    /// cached input, so this plus `output_tokens` is the complete billable figure.
    func getTotalTokenUsage() -> Double? {
        guard let usage = self["total_token_usage"] as? [String: Any] else { return nil }
        if let total = usage["total_tokens"] as? Double { return total }
        if let total = usage["total_tokens"] as? Int { return Double(total) }
        return nil
    }
}

private extension Data {
    /// Substring test without materialising a String for every line.
    func contains(ascii needle: String) -> Bool {
        range(of: Data(needle.utf8)) != nil
    }
}
