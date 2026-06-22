import WebKit

/// uBlock Origin filter lists compiled into a WKContentRuleList. iOS can't
/// run the full uBlock extension, so we ship the same default network lists
/// (uBlock filters + EasyList + EasyPrivacy + Peter Lowe) as a compiled
/// content rule set. Regenerate with `scripts/generate_ios_ublock_rules.py`.
enum ContentBlocker {

    static let identifier = "com.sephr.ios.ublock"

    private static let bannerSelectors = [
        "#onetrust-banner-sdk", "#onetrust-consent-sdk",
        ".qc-cmp2-container", "#didomi-host", "#usercentrics-root",
        "#sp_message_container", ".sp_message_container",
        "#cookie-banner", ".cookie-banner", "#cookie-consent",
        ".cookie-consent", "#CybotCookiebotDialog", ".cc-window",
        "#gdpr-banner", ".gdpr-banner", "#truste-consent-track",
    ]

    private static var json: String {
        if let url = Bundle.main.url(
            forResource: "ublock-content-rules", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           var rules = try? JSONSerialization.jsonObject(with: data)
            as? [[String: Any]] {
            rules.append([
                "trigger": ["url-filter": ".*"],
                "action": [
                    "type": "css-display-none",
                    "selector": bannerSelectors.joined(separator: ", "),
                ],
            ])
            let out = try! JSONSerialization.data(withJSONObject: rules)
            return String(data: out, encoding: .utf8)!
        }
        return fallbackJSON
    }

    /// Minimal fallback when the generated bundle isn't present (dev builds
    /// that skipped `scripts/generate_ios_ublock_rules.py`).
    private static var fallbackJSON: String {
        let hosts = [
            "doubleclick.net", "googlesyndication.com", "googleadservices.com",
            "google-analytics.com", "googletagmanager.com", "adnxs.com",
            "taboola.com", "outbrain.com", "scorecardresearch.com",
        ]
        var rules: [[String: Any]] = hosts.map { host in
            [
                "trigger": [
                    "url-filter": "^https?://([^/]*\\.)?"
                        + host.replacingOccurrences(of: ".", with: "\\.")
                        + "/.*",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": bannerSelectors.joined(separator: ", "),
            ],
        ])
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(data: data, encoding: .utf8)!
    }

    /// Compile (or fetch the cached compilation of) the rule list.
    @MainActor
    static func ruleList() async -> WKContentRuleList? {
        let store = WKContentRuleListStore.default()
        if let cached = try? await store?.contentRuleList(
            forIdentifier: identifier), cached != nil {
            return cached
        }
        return try? await store?.compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: json)
    }
}
