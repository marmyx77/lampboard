import Foundation

/// One start a menu offers (D188): a new conversation or a fork of the row's,
/// whether it outlives its terminal, whether it skips permissions, and the
/// account it signs in with.
public struct StartPlan: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable { case new, fork }

    public let kind: Kind
    /// In tmux, where it outlives the Hub; else it ends when its terminal closes (D168).
    public let keepsRunning: Bool
    /// No permission asked, for this one (D185); Settings' choice otherwise.
    public let skipping: Bool
    /// The default account when `nil` (D187).
    public let account: NewSession.Account?

    public init(kind: Kind, keepsRunning: Bool = true, skipping: Bool = false, account: NewSession.Account? = nil) {
        self.kind = kind
        self.keepsRunning = keepsRunning
        self.skipping = skipping
        self.account = account
    }

    /// The mode a launcher is given: bypass when skipping, Settings' when `nil`.
    public var permissions: NewSession.Permissions? { skipping ? .bypass : nil }
}

/// A start as a menu names it.
public struct StartOffer: Equatable, Sendable {
    public let kind: StartPlan.Kind
    public let keepsRunning: Bool
    public let title: String

    public static let keepsRunning = StartOffer(kind: .new, keepsRunning: true, title: "Start a session that keeps running")
    public static let endsWhenClosed = StartOffer(kind: .new, keepsRunning: false, title: "Start a session that ends when closed")
    public static let fork = StartOffer(kind: .fork, keepsRunning: true, title: "Fork this conversation")
}

extension Menus {

    /// The starts a place offers (D188), in one shape wherever a session starts
    /// from a menu: a project in the Hub, a row, a conversation under a row.
    /// First its own starts; then the same skipping permissions; then, for each
    /// other account, the same again, skipping or not; and «New session here…»
    /// last, where the form takes a name, a folder typed or browsed, and any of
    /// these together. Before 2.4.7 a project offered the accounts but no way to
    /// skip permissions in one, a row offered neither, and the form was only in
    /// the panel's ⋯ (13 November 2026).
    public static func starts(_ offers: [StartOffer], accounts: [NewSession.Account], on host: String? = nil,
                              form: Bool = true) -> [MenuEntry] {
        let suffix = host.map { " on \($0)" } ?? ""
        func items(skipping: Bool, account: NewSession.Account?) -> [MenuEntry] {
            offers.map { offer in
                .item(.start(StartPlan(kind: offer.kind, keepsRunning: offer.keepsRunning, skipping: skipping, account: account)),
                      offer.title + suffix)
            }
        }
        var entries = items(skipping: false, account: nil)
        entries.append(.submenu("Skipping permissions", items(skipping: true, account: nil)))
        for account in accounts {
            entries.append(.submenu("As \(account.name)", items(skipping: false, account: account)
                + [.submenu("Skipping permissions", items(skipping: true, account: account))]))
        }
        if form { entries.append(.item(.newSessionHere, "New session here…")) }
        return entries
    }
}
