import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Surfaces

/// iPhone stays true black. Mac follows the system appearance: Apple Notes charcoal in dark mode, and the
/// native light pages in light mode. The sidebar, the note list, and the editor are separate colors.
enum BrainChrome {
    #if os(iOS)
    /// Absolute black for lists, editors, and window chrome.
    static let canvas = Color.black
    #else
    static let canvas = Color(nsColor: MacNotesPalette.editor)
    static let sidebar = Color(nsColor: MacNotesPalette.sidebar)
    static let list = Color(nsColor: MacNotesPalette.list)
    #endif

    /// Call once at launch so UIKit scroll views match SwiftUI on iPhone.
    @MainActor
    static func applySystemAppearances() {
        #if os(iOS)
        let black = UIColor.black
        UITableView.appearance().backgroundColor = black
        UICollectionView.appearance().backgroundColor = black
        UITextView.appearance().backgroundColor = black
        // No global UIScrollView black proxy. The iOS 26 `.searchable` field draws its liquid-glass capsule over
        // private scroll views, and a global `UIScrollView.appearance()` black painted an opaque #000 plate inside
        // that glass. Appearance containment (`whenContainedInInstancesOf: [UISearchTextField.self]`) does not reach
        // those private views, so it can't opt them out. Lists stay black through the table and collection
        // appearances above plus SwiftUI's `brainBlackChrome` / `brainBlackList`; the keyboard bar clears its own scroller.
        UINavigationBar.appearance().barTintColor = black
        UINavigationBar.appearance().isTranslucent = true
        #endif
    }
}

#if os(macOS)
/// Apple Notes' dark columns, measured from the Mac reference, and the light pages beside them.
/// Sidebar is the lighter column in the dark, and the slightly gray one in the light. The list sits
/// between that and the editor page.
enum MacNotesPalette {
    static let sidebar = adaptive(named: "BrainNotes.sidebar", dark: srgb(40, 40, 39), light: srgb(236, 236, 236))
    static let list = adaptive(named: "BrainNotes.list", dark: srgb(31, 31, 31), light: srgb(246, 246, 247))
    static let editor = adaptive(named: "BrainNotes.editor", dark: srgb(30, 30, 30), light: srgb(255, 255, 255))

    static func adaptive(named name: String, dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name), dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}
#endif

extension View {
    /// iPhone: dark interface on a true-black canvas. Liquid Glass bars stay system-drawn on top.
    /// Mac: no forced scheme, so light mode stays light and the columns use `MacNotesPalette`.
    @ViewBuilder
    func brainBlackChrome() -> some View {
        #if os(iOS)
        self
            .preferredColorScheme(.dark)
            .background(BrainChrome.canvas.ignoresSafeArea())
            .toolbarBackground(BrainChrome.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }

    /// iPhone lists sit on black. Mac lists sit on the note-list surface, which is not the sidebar or the editor.
    @ViewBuilder
    func brainBlackList() -> some View {
        #if os(iOS)
        self
            .preferredColorScheme(.dark)
            .scrollContentBackground(.hidden)
            .background(BrainChrome.canvas)
        #else
        self
            .scrollContentBackground(.hidden)
            .background(BrainChrome.list)
        #endif
    }
}
