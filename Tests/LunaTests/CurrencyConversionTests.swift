import AppKit
import XCTest
@testable import Luna

final class CurrencyConversionTests: XCTestCase {
    @MainActor func testCurrencyIsOptInAndDisabledEditorNeverFetches() async throws {
        _ = NSApplication.shared
        enableCurrency()
        UserDefaults.standard.removeObject(forKey: EditorPreferences.currencyConversionKey)
        XCTAssertFalse(EditorPreferences.currencyConversionEnabled)
        var calls = 0
        let rates = ExchangeRates(defaults: defaults(), now: { self.today }, fetch: { _ in
            calls += 1
            return self.response
        })
        let conversion = try XCTUnwrap(CurrencyConversion.parse("100 baht in USD ="))
        let disabled = await rates.rate(for: conversion)
        XCTAssertNil(disabled)
        XCTAssertEqual(calls, 0)
        let editor = EditorView(usingTextLayoutManager: true)
        editor.exchangeRates = rates
        editor.string = "100 baht in USD ="
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertNil(editor.calculationSuggestion)
        XCTAssertTrue(editor.toolTip?.contains("external service") == true)
        UserDefaults.standard.set(true, forKey: EditorPreferences.currencyConversionKey)
        _ = await rates.rate(for: conversion)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(editor.calculationSuggestion)
        UserDefaults.standard.set(false, forKey: EditorPreferences.currencyConversionKey)
        editor.currencyPreferencesChanged()
        XCTAssertNil(editor.calculationSuggestion)
        XCTAssertNil(rates.cached(conversion))
        XCTAssertEqual(calls, 1)
        editor.string = "2 + 3 ="
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertEqual(editor.calculationSuggestion, " 5")
    }

    @MainActor func testDisablingCancelsPendingRateAndDoesNotCacheItsResponse() async throws {
        var enabled = true
        let started = expectation(description: "Request started")
        var continuation: CheckedContinuation<Data, Never>?
        let rates = ExchangeRates(defaults: defaults(), now: { self.today }, enabled: { enabled }, fetch: { _ in
            await withCheckedContinuation { pending in
                continuation = pending
                started.fulfill()
            }
        })
        let conversion = try XCTUnwrap(CurrencyConversion.parse("100 baht in USD ="))
        let request = Task { await rates.rate(for: conversion) }
        await fulfillment(of: [started], timeout: 2)
        enabled = false
        rates.cancelPendingRequests()
        continuation?.resume(returning: response)
        let result = await request.value
        XCTAssertNil(result)
        enabled = true
        XCTAssertNil(rates.cached(conversion))
    }

    private let today = Date(timeIntervalSince1970: 1_789_300_800) // 2026-09-13 12:00 UTC
    private let response = Data(#"{"date":"2026-09-13","base":"THB","quote":"USD","rate":0.03025}"#.utf8)
    private func enableCurrency() {
        let key = EditorPreferences.currencyConversionKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        addTeardownBlock {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
    private func defaults() -> UserDefaults {
        let name = "CurrencyConversionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testCurrencyAliasesAndFormatting() throws {
        for input in ["100,000 baht in USD = ", "Trip: 100000 Thai baht to dollars =", "THB 100000 as USD =", "฿100000 in USD ="] {
            let conversion = try XCTUnwrap(CurrencyConversion.parse(input), input)
            XCTAssertEqual(conversion.base, "THB")
            XCTAssertEqual(conversion.quote, "USD")
            XCTAssertEqual(conversion.amount, 100000)
            XCTAssertEqual(conversion.result(rate: 0.03025), "≈ 3,025.00 USD")
        }
        XCTAssertEqual(CurrencyConversion.parse("$100 in EUR =")?.base, "USD")
        XCTAssertEqual(CurrencyConversion.parse("100 USD in JPY =")?.result(rate: 150.123), "≈ 15,012 JPY")
        XCTAssertEqual(CurrencyConversion.parse("100 THB in THB =")?.result(rate: 1), "100.00 THB")
        for input in ["100,00 baht in USD =", "hello 100 baht in USD =", "100 baht in USD = 3", "100 ABC in USD =", "180 cm in ft =", "2 pounds in kg ="] {
            XCTAssertNil(CurrencyConversion.parse(input), input)
        }
    }
    @MainActor func testRequestsContainOnlyCodesAndCacheAcrossAmountsAndRestarts() async throws {
        let prefs = defaults()
        var urls: [URL] = []
        let rates = ExchangeRates(defaults: prefs, now: { self.today }, enabled: { true }, fetch: { url in
            urls.append(url)
            return self.response
        })
        let conversion = try XCTUnwrap(CurrencyConversion.parse("100,000 baht in USD ="))
        let first = await rates.rate(for: conversion)
        XCTAssertEqual(first?.rate, 0.03025)
        _ = await rates.rate(for: CurrencyConversion(amount: 12, base: "THB", quote: "USD"))
        XCTAssertEqual(urls.map(\.absoluteString), ["https://api.frankfurter.dev/v2/rate/THB/USD"])
        let restored = ExchangeRates(defaults: prefs, now: { self.today }, enabled: { true }, fetch: { _ in
            XCTFail("Fresh persistent cache should avoid a request")
            throw URLError(.notConnectedToInternet)
        })
        XCTAssertEqual(restored.cached(conversion)?.rate, 0.03025)
    }
    @MainActor func testExpiredCacheAndFailureBackoff() async throws {
        var time = today
        var calls = 0
        let rates = ExchangeRates(defaults: defaults(), now: { time }, enabled: { true }, fetch: { _ in
            calls += 1
            if calls == 1 { return self.response }
            throw URLError(.notConnectedToInternet)
        })
        let conversion = try XCTUnwrap(CurrencyConversion.parse("100 baht in USD ="))
        _ = await rates.rate(for: conversion)
        time = time.addingTimeInterval(86401)
        XCTAssertNil(rates.cached(conversion))
        let failed = await rates.rate(for: conversion)
        XCTAssertNil(failed)
        _ = await rates.rate(for: conversion)
        XCTAssertEqual(calls, 2)
        time = time.addingTimeInterval(301)
        _ = await rates.rate(for: conversion)
        XCTAssertEqual(calls, 3)
    }
    @MainActor func testConcurrentRequestsCoalesceAndRejectInvalidRates() async throws {
        var calls = 0
        let rates = ExchangeRates(defaults: defaults(), now: { self.today }, enabled: { true }, fetch: { _ in
            calls += 1
            await Task.yield()
            return self.response
        })
        let conversion = try XCTUnwrap(CurrencyConversion.parse("100 baht in USD ="))
        async let first = rates.rate(for: conversion)
        async let second = rates.rate(for: conversion)
        let values = await (first, second)
        XCTAssertEqual(values.0?.rate, values.1?.rate)
        XCTAssertEqual(calls, 1)
        for invalid in [
            #"{"date":"2026-09-13","base":"USD","quote":"THB","rate":33}"#,
            #"{"date":"2026-09-13","base":"THB","quote":"USD","rate":0}"#,
            #"{"date":"2020-01-01","base":"THB","quote":"USD","rate":0.03}"#,
            #"{"date":"bad","base":"THB","quote":"USD","rate":0.03}"#,
            "not JSON"
        ] {
            let invalidRates = ExchangeRates(defaults: defaults(), now: { self.today }, enabled: { true }, fetch: { _ in Data(invalid.utf8) })
            let value = await invalidRates.rate(for: conversion)
            XCTAssertNil(value, invalid)
        }
    }
    @MainActor func testEditorAcceptsCachedConversionAndDoesNotInsertLoadingText() async throws {
        _ = NSApplication.shared
        enableCurrency()
        let rates = ExchangeRates(defaults: defaults(), now: { self.today }, enabled: { true }, fetch: { _ in self.response })
        let conversion = try XCTUnwrap(CurrencyConversion.parse("100,000 baht in USD = "))
        _ = await rates.rate(for: conversion)
        let editor = EditorView(usingTextLayoutManager: true)
        editor.exchangeRates = rates
        editor.string = "100,000 baht in USD = "
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertEqual(editor.calculationSuggestion, "≈ 3,025.00 USD")
        XCTAssertTrue(editor.toolTip?.contains("2026-09-13") == true)
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "100,000 baht in USD = ≈ 3,025.00 USD")
        editor.string = "100 USD in EUR = "
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertNil(editor.calculationSuggestion)
        editor.cancelOperation(nil)
        XCTAssertNil(editor.calculationSuggestion)
        editor.string = "2 + 3 ="
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertEqual(editor.calculationSuggestion, " 5")
    }

    @MainActor func testLateNetworkResponseCannotReplaceCurrentSuggestion() async throws {
        _ = NSApplication.shared
        enableCurrency()
        let started = expectation(description: "Exchange request started")
        var responseContinuation: CheckedContinuation<Data, Never>?
        let rates = ExchangeRates(defaults: defaults(), now: { self.today }, enabled: { true }, fetch: { _ in
            await withCheckedContinuation { continuation in
                responseContinuation = continuation
                started.fulfill()
            }
        })
        let editor = EditorView(usingTextLayoutManager: true)
        editor.exchangeRates = rates
        editor.string = "100 baht in USD ="
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertNil(editor.calculationSuggestion)
        await fulfillment(of: [started], timeout: 2)
        editor.string = "20 + 30 ="
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        responseContinuation?.resume(returning: response)
        let conversion = try XCTUnwrap(CurrencyConversion.parse("100 baht in USD ="))
        _ = await rates.rate(for: conversion)
        XCTAssertEqual(editor.calculationSuggestion, " 50")
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "20 + 30 = 50")
    }
}
