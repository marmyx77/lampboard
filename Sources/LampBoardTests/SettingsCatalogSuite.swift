import LampBoardCore
import Foundation
import TestKit

/// The Settings window's nine sections (U3), and the rule that every switch has
/// one name: the one it has in Settings is the one it has in every menu.
enum SettingsCatalogSuite {

    static let suite = TestSuite("Settings catalogue", [

        TestCase("Nine sections, in the order a person looks for things") { t in
            t.expectEqual(SettingsCatalog.sections.map(\.title), [
                "Panel", "Clicks & keys", "Alerts", "Claude Code & Codex", "Acting from the panel",
                "LampMaster", "Other Macs", "Privacy & data", "About & help",
            ])
        },

        TestCase("Every setting has one id and one name, and a line saying what it does") { t in
            let items = SettingsCatalog.sections.flatMap { $0.groups.flatMap(\.items) }
            t.expectEqual(Set(items.map(\.id)).count, items.count, "ids are unique")
            t.expectEqual(Set(items.map(\.label)).count, items.count, "names are unique")
            t.expect(items.filter { $0.help.isEmpty && $0.id.rawValue != "width" }.isEmpty,
                     "only the width speaks for itself: \(items.filter { $0.help.isEmpty }.map(\.label))")
        },

        TestCase("What acts on the sessions or leaves the Mac is marked") { t in
            t.expectEqual(SettingsCatalog.sections.filter(\.warns).map(\.title), ["Acting from the panel", "LampMaster"])
        },

        TestCase("A switch in a menu is called what Settings calls it") { t in
            let menu = Menus.panel(PanelMenuState(onlyWaiting: false, mutedUntil: nil, isAway: false, hiddenCount: 0),
                                   time: { _ in "" })
            let names = menu.compactMap { entry -> String? in
                if case .item(_, let title, _, _, _) = entry { return title }
                return nil
            }
            t.expect(names.contains(SettingsCatalog.item(.onlyWaiting).label), "only what's waiting")
            t.expect(names.contains(SettingsCatalog.item(.away).label), "away")
            t.expectEqual(SettingsCatalog.item(.sendMessages).label, "Send messages to sessions",
                          "not «answer»: that is the permissions' word")
        },
    ])
}
