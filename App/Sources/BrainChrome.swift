import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Which column a Mac surface belongs to. On iPhone every one is the true-black canvas.
enum BrainSurface {
    case sidebar, list, editor

    #if os(macOS)
    var macRole: MacNotesPalette.Role {
        switch self {
        case .sidebar: .sidebar
        case .list: .list
        case .editor: .editor
        }
    }
    #endif
}

// MARK: - Surfaces

/// iPhone stays true black. Mac follows the system appearance: Apple Notes charcoal in dark mode, and the
/// native light pages in light mode. The sidebar, the note list, and the editor are separate colors.
enum BrainChrome {
    #if os(iOS)
    /// Absolute black for lists, editors, and window chrome.
    static let canvas = Color.black
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
///
/// SwiftUI reads `ColorScheme` and AppKit reads the view's own appearance. A named dynamic `NSColor`
/// can resolve against the app's appearance instead of the window's, which paints a dark page under
/// light text (or the reverse) and the words disappear.
enum MacNotesPalette {
    enum Role { case sidebar, list, editor }

    static func color(_ role: Role, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch role {
        case .sidebar: return rgb(dark ? 40 : 236, dark ? 40 : 236, dark ? 39 : 236)
        case .list: return rgb(dark ? 31 : 246, dark ? 31 : 246, dark ? 31 : 247)
        case .editor: return rgb(dark ? 30 : 255, dark ? 30 : 255, dark ? 30 : 255)
        }
    }

    static func nsColor(_ role: Role, _ appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        switch role {
        case .sidebar: return srgb(dark ? 40 : 236, dark ? 40 : 236, dark ? 39 : 236)
        case .list: return srgb(dark ? 31 : 246, dark ? 31 : 246, dark ? 31 : 247)
        case .editor: return srgb(dark ? 30 : 255, dark ? 30 : 255, dark ? 30 : 255)
        }
    }

    /// The editor page, matched to the scroll view's appearance at the moment it is in a window.
    static func paintEditor(in scroll: NSScrollView) {
        let color = nsColor(.editor, scroll.effectiveAppearance)
        scroll.drawsBackground = true
        scroll.backgroundColor = color
        guard let view = scroll.documentView as? NSTextView else { return }
        view.drawsBackground = true
        view.backgroundColor = color
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    private static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}

/// Fill and type from one scheme. A sidebar list was painting light-mode black onto the charcoal page.
private struct MacSurfaceModifier: ViewModifier {
    var surface: BrainSurface
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(MacNotesPalette.color(surface.macRole, scheme))
            .foregroundStyle(scheme == .dark ? Color.white : Color.primary)
            .background(MacListAppearance(dark: scheme == .dark))
    }
}

/// Source-list labels follow the AppKit appearance. Pin it to the same scheme as the fill.
private struct MacListAppearance: NSViewRepresentable {
    var dark: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        DispatchQueue.main.async {
            guard let root = nsView.superview else { return }
            func walk(_ view: NSView, depth: Int) {
                guard depth < 12 else { return }
                if view is NSScrollView || view is NSTableView {
                    view.appearance = appearance
                }
                view.subviews.forEach { walk($0, depth: depth + 1) }
            }
            walk(root, depth: 0)
        }
    }
}
#endif

extension View {
    /// iPhone: true black. Mac: the Notes surface for this column, matched to the text's color scheme.
    @ViewBuilder
    func brainSurface(_ surface: BrainSurface) -> some View {
        #if os(iOS)
        self.background(BrainChrome.canvas)
        #else
        self.modifier(MacSurfaceModifier(surface: surface))
        #endif
    }

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
        self.modifier(MacSurfaceModifier(surface: .list))
        #endif
    }
}
