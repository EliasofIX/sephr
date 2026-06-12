import WebKit

/// Always-on (toggleable) blocking of common ad/tracker hosts and cookie
/// banners, compiled once into a WKContentRuleList and attached to every
/// page's user content controller. Blocking is a speed feature as much as
/// a privacy one — fewer requests, cleaner first paint.
enum ContentBlocker {

    static let identifier = "com.sephr.ios.blocklist"

    private static let trackerHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "adservice.google.com",
        "scorecardresearch.com", "quantserve.com", "outbrain.com",
        "taboola.com", "criteo.com", "criteo.net", "adnxs.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "moatads.com",
        "amazon-adsystem.com", "facebook.net", "hotjar.com",
        "mouseflow.com", "fullstory.com", "chartbeat.com", "parsely.com",
        "branch.io", "adjust.com", "appsflyer.com",
    ]

    private static let bannerSelectors = [
        "#onetrust-banner-sdk", "#onetrust-consent-sdk",
        ".qc-cmp2-container", "#didomi-host", "#usercentrics-root",
        "#sp_message_container", ".sp_message_container",
        "#cookie-banner", ".cookie-banner", "#cookie-consent",
        ".cookie-consent", "#CybotCookiebotDialog", ".cc-window",
        "#gdpr-banner", ".gdpr-banner", "#truste-consent-track",
    ]

    private static var json: String {
        var rules: [[String: Any]] = trackerHosts.map { host in
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
            "action": ["type": "css-display-none",
                       "selector": bannerSelectors.joined(separator: ", ")],
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
