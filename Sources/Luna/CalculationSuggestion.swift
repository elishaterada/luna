import Foundation

/// Bounded, local evaluation. Note text is parsed as data, never executed.
enum CalculationSuggestion {
    static func result(for line: String, context: String = "", now: Date = Date()) -> String? {
        guard line.utf16.count <= 1024 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("=") else { return nil }
        let expression = String(trimmed.dropLast().split(separator: ":", omittingEmptySubsequences: false).last ?? "").trimmingCharacters(in: .whitespaces)
        if let date = dateResult(expression, now: now) { return date }
        var references: [String: Quantity] = [:]
        // Only earlier definitions participate. Resolve in order, preventing cycles.
        for line in context.suffix(32_768).components(separatedBy: .newlines) where line.count <= 1024 {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, name.count <= 80, name.first?.isLetter == true else { continue }
            let rhs = String(line[line.index(after: colon)...].split(separator: "=", omittingEmptySubsequences: false)[0])
            // An invalid redefinition must not silently reuse an older value.
            references[name] = evaluate(rhs, references: references)?.value
        }
        guard let evaluated = evaluate(expression, references: references), evaluated.active else { return nil }
        return format(evaluated.value, target: evaluated.target)
    }

    private enum Dimension { case scalar, money, length, mass, volume, time }
    private struct Unit {
        let dimension: Dimension
        let scale: Double
        let symbol: String
    }
    private struct Quantity {
        var amount: Double
        var dimension: Dimension = .scalar
        var unit: Unit? = nil
        var percent = false
    }
    private static let units: [String: Unit] = {
        var result: [String: Unit] = [:]
        func add(_ names: String, _ dimension: Dimension, _ scale: Double, _ symbol: String) {
            for name in names.split(separator: " ") { result[String(name)] = Unit(dimension: dimension, scale: scale, symbol: symbol) }
        }
        add("mm millimeter millimeters", .length, 0.001, "mm")
        add("cm centimeter centimeters", .length, 0.01, "cm")
        add("m meter meters", .length, 1, "m")
        add("km kilometer kilometers", .length, 1000, "km")
        add("in inch inches", .length, 0.0254, "in")
        add("ft foot feet", .length, 0.3048, "ft")
        add("yd yard yards", .length, 0.9144, "yd")
        add("mi mile miles", .length, 1609.344, "mi")
        add("mg milligram milligrams", .mass, 0.000001, "mg")
        add("g gram grams", .mass, 0.001, "g")
        add("kg kilogram kilograms", .mass, 1, "kg")
        add("oz ounce ounces", .mass, 0.028349523125, "oz")
        add("lb lbs pound pounds", .mass, 0.45359237, "lb")
        add("ml milliliter milliliters", .volume, 0.001, "ml")
        add("l liter liters", .volume, 1, "L")
        add("s sec secs second seconds", .time, 1, "s")
        add("min mins minute minutes", .time, 60, "min")
        add("h hr hrs hour hours", .time, 3600, "h")
        add("d day days", .time, 86400, "d")
        add("w week weeks", .time, 604800, "w")
        return result
    }()

    private struct Evaluation { let value: Quantity; let target: String?; let active: Bool }
    private static func evaluate(_ expression: String, references: [String: Quantity]) -> Evaluation? {
        var input = expression.trimmingCharacters(in: .whitespaces).lowercased()
        var target: String?
        for separator in [" as ", " in ", " to "] {
            if let range = input.range(of: separator, options: .backwards) {
                let candidate = String(input[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if candidate == "%" || units[candidate] != nil {
                    target = candidate
                    input = String(input[..<range.lowerBound])
                    break
                }
            }
        }
        var parser = Parser(characters: Array(input), references: references)
        // In duration expressions, compact `m` means minutes regardless of operand order.
        parser.durationContext = input.range(of: #"[0-9]\s*(?:h|hr|hrs|hours?|min|mins|minutes?|s|sec|secs|seconds?|d|days?|w|weeks?)(?![a-z])"#, options: .regularExpression) != nil
        guard let value = parser.sum(), parser.finished, value.amount.isFinite, abs(value.amount) < 1e15 else { return nil }
        if let target {
            if target == "%" { guard value.dimension == .scalar else { return nil } }
            else { guard units[target]?.dimension == value.dimension else { return nil } }
        }
        return Evaluation(value: value, target: target, active: parser.operations > 0 || parser.usedReference || target != nil)
    }

    private static func number(_ value: Double, digits: Int = 6) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value == 0 ? 0 : value)) ?? ""
    }
    private static func format(_ value: Quantity, target: String?) -> String {
        if target == "%" { return number(value.amount * 100, digits: 2) + "%" }
        if let target, let unit = units[target] {
            if target == "feet" {
                let inches = (abs(value.amount) / 0.0254 * 100).rounded() / 100
                return (value.amount < 0 ? "-" : "") + "\(number(floor(inches / 12))) ft \(number(inches.truncatingRemainder(dividingBy: 12), digits: 2)) in"
            }
            return number(value.amount / unit.scale) + " " + unit.symbol
        }
        if value.dimension == .time {
            var remaining = (abs(value.amount) * 1e6).rounded() / 1e6
            var parts: [String] = []
            for (size, suffix) in [(86400.0, "d"), (3600.0, "h"), (60.0, "m")] {
                let count = floor(remaining / size)
                if count > 0 { parts.append(number(count) + suffix); remaining -= count * size }
            }
            if remaining > 0 || parts.isEmpty { parts.append(number(remaining) + "s") }
            return (value.amount < 0 ? "-" : "") + parts.joined(separator: " ")
        }
        if let unit = value.unit { return number(value.amount / unit.scale) + " " + unit.symbol }
        if value.percent { return number(value.amount * 100) + "%" }
        return (value.dimension == .money ? "$" : "") + number(value.amount)
    }

    private struct Parser {
        let characters: [Character]
        let references: [String: Quantity]
        var index = 0
        var operations = 0
        var usedReference = false
        var durationContext = false
        mutating func skipSpaces() { while index < characters.count && characters[index].isWhitespace { index += 1 } }
        var finished: Bool { mutating get { skipSpaces(); return index == characters.count } }
        mutating func take(_ choices: String) -> Character? {
            skipSpaces()
            guard index < characters.count, choices.contains(characters[index]) else { return nil }
            defer { index += 1 }
            return characters[index]
        }
        mutating func word() -> String {
            skipSpaces()
            let start = index
            while index < characters.count && characters[index].isLetter { index += 1 }
            return String(characters[start..<index])
        }
        mutating func sum() -> Quantity? {
            guard var value = product() else { return nil }
            while let op = take("+-") {
                guard var rhs = product() else { return nil }
                operations += 1
                if rhs.percent && !value.percent {
                    rhs.amount *= value.amount; rhs.dimension = value.dimension
                }
                guard value.dimension == rhs.dimension else { return nil }
                value.amount += (op == "+" ? rhs.amount : -rhs.amount)
            }
            return value
        }
        mutating func product() -> Quantity? {
            guard var value = factor() else { return nil }
            while true {
                let op: Character
                if let symbol = take("*x×/÷") { op = symbol }
                else {
                    let saved = index
                    guard word() == "of" else { index = saved; break }
                    op = "*"
                }
                guard let rhs = factor() else { return nil }
                operations += 1
                if op == "/" || op == "÷" {
                    guard rhs.amount != 0 else { return nil }
                    if rhs.dimension == .scalar { value.amount /= rhs.amount; value.percent = false }
                    else if value.dimension == rhs.dimension { value = Quantity(amount: value.amount / rhs.amount) }
                    else { return nil }
                } else {
                    guard value.dimension == .scalar || rhs.dimension == .scalar else { return nil }
                    if value.dimension == .scalar { value = Quantity(amount: value.amount * rhs.amount, dimension: rhs.dimension, unit: rhs.unit) }
                    else { value.amount *= rhs.amount; value.percent = false }
                }
            }
            return value
        }
        mutating func factor() -> Quantity? {
            if let sign = take("+-") {
                guard var value = factor() else { return nil }
                if sign == "-" { value.amount = -value.amount }
                return value
            }
            if take("(") != nil {
                guard var value = sum(), take(")") != nil else { return nil }
                if take("%") != nil {
                    guard value.dimension == .scalar else { return nil }
                    value.amount /= 100; value.percent = true
                }
                return value
            }
            skipSpaces()
            for name in references.keys.sorted(by: { $0.count > $1.count }) {
                let letters = Array(name)
                let end = index + letters.count
                if end <= characters.count, Array(characters[index..<end]) == letters,
                   end == characters.count || (!characters[end].isLetter && !characters[end].isNumber && characters[end] != "_") {
                    index = end; usedReference = true
                    if references[name]?.dimension == .time { durationContext = true }
                    return references[name]
                }
            }
            guard var value = literal(timeContext: false) else { return nil }
            // Adjacent quantities form one mixed-unit operand, e.g. 5 ft 8 in or 1h 25m.
            while value.unit != nil {
                let saved = index
                skipSpaces()
                guard index < characters.count, characters[index].isNumber,
                      let next = literal(timeContext: value.dimension == .time), next.unit != nil else { index = saved; break }
                guard next.dimension == value.dimension else { return nil }
                value.amount += next.amount; operations += 1
            }
            return value
        }
        mutating func literal(timeContext: Bool) -> Quantity? {
            let currency = take("$") != nil
            skipSpaces()
            let start = index
            while index < characters.count && "0123456789.,".contains(characters[index]) { index += 1 }
            let token = String(characters[start..<index])
            guard token.range(of: #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?$|^\.[0-9]+$"#, options: .regularExpression) != nil,
                  let amount = Double(token.replacingOccurrences(of: ",", with: "")) else { return nil }
            if take("%") != nil { return currency ? nil : Quantity(amount: amount / 100, percent: true) }
            let saved = index
            let name = word()
            let unit = name == "m" && (timeContext || durationContext) ? units["min"] : units[name]
            if let unit {
                guard !currency else { return nil }
                if unit.dimension == .time { durationContext = true }
                return Quantity(amount: amount * unit.scale, dimension: unit.dimension, unit: unit)
            }
            index = saved
            return Quantity(amount: amount, dimension: currency ? .money : .scalar)
        }
    }

    private static func dateResult(_ expression: String, now: Date) -> String? {
        let pattern = #"^(.+?)\s+([+-])\s*(\d+)\s+(days?|weeks?|months?|years?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: expression, range: NSRange(expression.startIndex..., in: expression)) else { return nil }
        let source = expression as NSString
        let dateText = source.substring(with: match.range(at: 1))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        var date: Date?
        if dateText.lowercased() == "today" { date = now }
        else {
            for format in ["yyyy-MM-dd", "MMM d, yyyy", "MMMM d, yyyy", "MMM d", "MMMM d"] {
                formatter.dateFormat = format
                formatter.defaultDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1))
                if let parsed = formatter.date(from: dateText), formatter.string(from: parsed).lowercased() == dateText.lowercased() { date = parsed; break }
            }
        }
        guard let date, let count = Int(source.substring(with: match.range(at: 3))), count <= 100_000 else { return nil }
        let unit = source.substring(with: match.range(at: 4)).lowercased()
        let component: Calendar.Component = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear : unit.hasPrefix("month") ? .month : .year
        let sign = source.substring(with: match.range(at: 2)) == "-" ? -1 : 1
        guard let result = calendar.date(byAdding: component, value: sign * count, to: date), (1...9999).contains(calendar.component(.year, from: result)) else { return nil }
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: result)
    }
}
