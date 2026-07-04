import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Menu — declarative, JSON-driven menu system.
//
// Loading precedence (first hit wins):
//   1. ~/.zush/menus.json          (user override — hand-edit to reorder/add)
//   2. Bundle: menus.default.json  (shipped with the app)
//   3. Hard-coded minimal fallback (if everything else fails)
//
// Powers both the menubar and the terminal right-click popup from ONE spec, so
// there is one place to add a new action.
//
// Action dispatch: every menu item routes through a single Objective-C
// selector on the AppDelegate (`dispatchMenuAction:`). The item's
// `representedObject` carries the action name, which is looked up in a
// closure registry the delegate populates at launch. Add a new action = one
// entry in the registry + one line in menus.default.json.
// ─────────────────────────────────────────────────────────────────────────────

struct MenuNode: Decodable {
    var title: String?
    var isAppMenu: Bool?
    var separator: Bool?
    var shortcut: String?
    var action: String?
    var items: [MenuNode]?
}

struct MenuSpec: Decodable {
    var menubar: [MenuNode]
    var contextMenu: [MenuNode]
}

enum MenuLoader {
    static func load() -> MenuSpec {
        // 1. User override
        let userURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zush/menus.json")
        if let data = try? Data(contentsOf: userURL),
           let spec = try? JSONDecoder().decode(MenuSpec.self, from: data) {
            return spec
        }
        // 2. Bundled default (SPM resource)
        if let bundleURL = Bundle.module.url(forResource: "menus.default", withExtension: "json"),
           let data = try? Data(contentsOf: bundleURL),
           let spec = try? JSONDecoder().decode(MenuSpec.self, from: data) {
            return spec
        }
        // 3. Hard fallback (should never hit in a shipping build)
        return MenuSpec(
            menubar: [
                MenuNode(title: "Zupershell", isAppMenu: true, separator: nil, shortcut: nil, action: nil,
                         items: [MenuNode(title: "Quit", separator: nil, shortcut: "cmd+q", action: "quit", items: nil)]),
            ],
            contextMenu: [
                MenuNode(title: "Copy",  action: "copy"),
                MenuNode(title: "Paste", action: "paste"),
            ]
        )
    }
}

/// Parses shortcut strings like "cmd+shift+n" → (keyEquivalent, modifierFlags).
enum Shortcut {
    static func parse(_ s: String) -> (String, NSEvent.ModifierFlags) {
        var mods: NSEvent.ModifierFlags = []
        var key = ""
        for part in s.lowercased().split(separator: "+") {
            switch part {
            case "cmd", "command":       mods.insert(.command)
            case "opt", "option", "alt": mods.insert(.option)
            case "shift":                mods.insert(.shift)
            case "ctrl", "control":      mods.insert(.control)
            default:                     key = String(part)
            }
        }
        return (key, mods)
    }
}

/// Constructs NSMenu / NSMenuItem trees from a MenuSpec. All items route to a
/// single target/selector; the item's representedObject carries the action name.
enum MenuBuilder {
    static func buildMenubar(_ spec: MenuSpec, target: AnyObject, selector: Selector) -> NSMenu {
        let bar = NSMenu()
        for top in spec.menubar {
            let item = NSMenuItem()
            let sub = NSMenu(title: top.title ?? "")
            for child in top.items ?? [] {
                sub.addItem(makeItem(child, target: target, selector: selector))
            }
            item.submenu = sub
            bar.addItem(item)
        }
        return bar
    }

    static func buildPopup(_ spec: MenuSpec, target: AnyObject, selector: Selector) -> NSMenu {
        let m = NSMenu(title: "")
        for n in spec.contextMenu {
            m.addItem(makeItem(n, target: target, selector: selector))
        }
        return m
    }

    private static func makeItem(_ n: MenuNode, target: AnyObject, selector: Selector) -> NSMenuItem {
        if n.separator == true { return .separator() }
        let (key, mods) = n.shortcut.map(Shortcut.parse) ?? ("", [])
        let it = NSMenuItem(title: n.title ?? "", action: selector, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = target
        it.representedObject = n.action
        return it
    }
}
