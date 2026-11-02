import Foundation

@main
struct CostPricingTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            failures += 1
            print("FAIL \(label)")
        }
    }

    static func check(_ model: String, expected: Double) {
        let event = TokenEvent(
            provider: .codex,
            timestamp: Date(timeIntervalSince1970: 0),
            model: model,
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheCreationTokens: 1_000_000,
            cacheReadTokens: 1_000_000
        )
        expect(Pricing.isKnown(model), "\(model) is priced")
        expect(abs(Pricing.cost(for: event) - expected) < 0.000001,
               "\(model) uses current per-token rates")
    }

    static func main() {
        check("gpt-6.1-sol", expected: 14.6)
        check("gpt-6-luna", expected: 0.735)
        check("gpt-6.1-terra", expected: 7.3)
        check("gpt-6-astra", expected: 73.5)
        check("gpt-6-sol", expected: 14.7)
        check("gpt-5.6-sol", expected: 29.4)
        check("gpt-5.6-terra", expected: 16.7)
        check("gpt-5.6-luna", expected: 1.67)

        if failures > 0 { exit(1) }
        print("Cost pricing tests passed")
    }
}
