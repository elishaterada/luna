import Foundation

struct CurrencyConversion: Equatable {
    let amount: Double
    let base: String
    let quote: String
    var pair: String { "\(base)/\(quote)" }

    private static let aliases = [
        "baht": "THB", "thai baht": "THB", "฿": "THB",
        "dollar": "USD", "dollars": "USD", "us dollars": "USD", "$": "USD",
        "euro": "EUR", "euros": "EUR", "€": "EUR",
        "pound": "GBP", "pounds": "GBP", "sterling": "GBP", "£": "GBP",
        "yen": "JPY", "yuan": "CNY", "renminbi": "CNY",
        "rupee": "INR", "rupees": "INR", "₹": "INR",
        "won": "KRW", "australian dollars": "AUD", "canadian dollars": "CAD",
        "singapore dollars": "SGD", "swiss francs": "CHF"
    ]
    private static func code(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let alias = aliases[name] { return alias }
        let code = name.uppercased()
        return Locale.commonISOCurrencyCodes.contains(code) ? code : nil
    }
    static func parse(_ line: String) -> CurrencyConversion? {
        guard line.utf16.count <= 1024 else { return nil }
        let expression = line.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? line
        let number = #"[+-]?(?:(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?|\.[0-9]+)"#
        let pattern = "^\\s*(?:([A-Za-z$€£฿₹ ]+?)\\s*(" + number + ")|(" + number + ")\\s*([A-Za-z$€£฿₹ ]+?))\\s+(?:in|to|as)\\s+([A-Za-z$€£฿₹ ]+)\\s*=\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: expression, range: NSRange(expression.startIndex..., in: expression)) else { return nil }
        let source = expression as NSString
        let prefix = match.range(at: 1).location != NSNotFound
        guard let base = code(source.substring(with: match.range(at: prefix ? 1 : 4))),
              let quote = code(source.substring(with: match.range(at: 5))),
              let amount = Double(source.substring(with: match.range(at: prefix ? 2 : 3)).replacingOccurrences(of: ",", with: "")),
              amount.isFinite, abs(amount) < 1e15 else { return nil }
        return CurrencyConversion(amount: amount, base: base, quote: quote)
    }
    func result(rate: Double) -> String? {
        let converted = amount * rate
        guard rate.isFinite, rate > 0, converted.isFinite, abs(converted) < 1e15 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = quote
        formatter.currencySymbol = ""
        guard let number = formatter.string(from: NSNumber(value: converted))?.trimmingCharacters(in: .whitespaces) else { return nil }
        return (base == quote ? "" : "≈ ") + number + " " + quote
    }
}

/// Shared across editor windows. Only currency codes leave the device.
@MainActor
final class ExchangeRates {
    struct Rate: Codable {
        let date: String
        let base: String
        let quote: String
        let rate: Double
    }
    private struct Entry: Codable { let rate: Rate; let fetched: Date }
    static let shared = ExchangeRates()
    private static let cacheKey = "calculation.exchangeRates.v1"
    private let defaults: UserDefaults
    private let now: () -> Date
    private let enabled: () -> Bool
    private let fetch: (URL) async throws -> Data
    private var entries: [String: Entry]
    private var pending: [String: Task<Rate?, Never>] = [:]
    private var failures: [String: Date] = [:]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         enabled: @escaping () -> Bool = { EditorPreferences.currencyConversionEnabled },
         fetch: @escaping (URL) async throws -> Data = { url in
             var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
             request.setValue("application/json", forHTTPHeaderField: "Accept")
             let (data, response) = try await URLSession.shared.data(for: request)
             guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4096 else { throw URLError(.badServerResponse) }
             return data
         }) {
        self.defaults = defaults; self.now = now; self.fetch = fetch; self.enabled = enabled
        entries = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    func cached(_ conversion: CurrencyConversion) -> Rate? {
        guard enabled(), let entry = entries[conversion.pair], valid(entry.rate, for: conversion),
              (0..<86400).contains(now().timeIntervalSince(entry.fetched)) else { return nil }
        return entry.rate
    }
    private func valid(_ rate: Rate, for conversion: CurrencyConversion) -> Bool {
        guard rate.base == conversion.base, rate.quote == conversion.quote, rate.rate.isFinite, rate.rate > 0 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: rate.date), formatter.string(from: date) == rate.date else { return false }
        // Allow weekends/holidays, but never silently use obsolete or future quotes.
        return (-86400...7 * 86400).contains(now().timeIntervalSince(date))
    }
    func rate(for conversion: CurrencyConversion) async -> Rate? {
        guard enabled() else { return nil }
        if let cached = cached(conversion) { return cached }
        if let pending = pending[conversion.pair] { return await pending.value }
        if let failure = failures[conversion.pair], now().timeIntervalSince(failure) < 300 { return nil }
        let task = Task<Rate?, Never> {
            do {
                try Task.checkCancellation()
                guard enabled() else { return nil }
                let url = URL(string: "https://api.frankfurter.dev/v2/rate/\(conversion.pair)")!
                let rate = try JSONDecoder().decode(Rate.self, from: await fetch(url))
                try Task.checkCancellation()
                guard enabled() else { return nil }
                guard valid(rate, for: conversion) else { throw URLError(.cannotParseResponse) }
                entries = entries.filter { (0..<86400).contains(now().timeIntervalSince($0.value.fetched)) }
                entries[conversion.pair] = Entry(rate: rate, fetched: now())
                if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.cacheKey) }
                failures[conversion.pair] = nil
                return rate
            } catch {
                if !Task.isCancelled && enabled() { failures[conversion.pair] = now() }
                return nil
            }
        }
        pending[conversion.pair] = task
        let result = await task.value
        pending[conversion.pair] = nil
        return result
    }
    func cancelPendingRequests() {
        for task in pending.values { task.cancel() }
    }
}
