import Foundation

enum GoldenDirection: String, Sendable {
    case enToZh = "EN→ZH"
    case zhToEn = "ZH→EN"

    var sourceLanguageName: String {
        switch self {
        case .enToZh: "English"
        case .zhToEn: "Traditional Chinese"
        }
    }

    var targetLanguageName: String {
        switch self {
        case .enToZh: "Traditional Chinese"
        case .zhToEn: "English"
        }
    }
}

struct GoldenCase: Identifiable, Sendable {
    let id: String
    let direction: GoldenDirection
    let source: String
    let expectedMeaning: String
    let protectedTerms: [String]
}

enum GoldenCaseCatalog {
    static let all: [GoldenCase] = [
        GoldenCase(
            id: "en_rpc_failover",
            direction: .enToZh,
            source: "Our RPC gateway switches providers after three consecutive timeouts.",
            expectedMeaning: "The RPC gateway changes to another provider only after three timeouts in a row.",
            protectedTerms: ["RPC"]
        ),
        GoldenCase(
            id: "en_health_factor",
            direction: .enToZh,
            source: "The keeper liquidates the position when the health factor falls below one point zero.",
            expectedMeaning: "A keeper triggers liquidation when the position health factor is below 1.0.",
            protectedTerms: []
        ),
        GoldenCase(
            id: "en_uniswap_leverage",
            direction: .enToZh,
            source: "The Uniswap v3 position uses two point five times leverage and rebalances every six hours.",
            expectedMeaning: "The Uniswap v3 position has 2.5x leverage and rebalances once every six hours.",
            protectedTerms: ["Uniswap v3"]
        ),
        GoldenCase(
            id: "zh_morpho_liquidation",
            direction: .zhToEn,
            source: "我們用 Morpho 監控借款人的 health factor，低於一點零就準備清算。",
            expectedMeaning: "Morpho is used to monitor a borrower's health factor, and liquidation is prepared when it drops below 1.0.",
            protectedTerms: ["Morpho"]
        ),
        GoldenCase(
            id: "zh_rpc_failover",
            direction: .zhToEn,
            source: "RPC 連續三次逾時後，gateway 會切換到備援 provider。",
            expectedMeaning: "After three consecutive RPC timeouts, the gateway switches to a backup provider.",
            protectedTerms: ["RPC"]
        ),
        GoldenCase(
            id: "zh_uniswap_rebalance",
            direction: .zhToEn,
            source: "這個 Uniswap v3 部位使用一點五倍槓桿，並且每六小時執行一次 rebalancing。",
            expectedMeaning: "The Uniswap v3 position uses 1.5x leverage and performs rebalancing every six hours.",
            protectedTerms: ["Uniswap v3"]
        )
    ]
}
