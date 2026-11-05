import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - True-black chrome (Apple Notes / X style)

/// Pure black app surface. System dark mode still uses gray grouped backgrounds; we pin black instead.
enum BrainChrome {
    /// Absolute black for lists, editors, and window chrome.
    static let canvas = Color.black

    /// Call once at launch so UIKit scroll views match SwiftUI.
    @MainActor
    static func applySystemAppearances() {
        #if os(iOS)
        let black = UIColor.black
        UITableView.appearance().backgroundColor = black
        UICollectionView.appearance().backgroundColor = black
        UITextView.appearance().backgroundColor = black
        UIScrollView.appearance().backgroundColor = black
        UINavigationBar.appearance().barTintColor = black
        UINavigationBar.appearance().isTranslucent = true
        #endif
    }
}

extension View {
    /// Dark interface on a true-black canvas. Liquid Glass bars stay system-drawn on top.
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
            .preferredColorScheme(.dark)
            .background(BrainChrome.canvas.ignoresSafeArea())
        #endif
    }

    /// Hide the gray list/form wash and sit on black. Forces dark so label text stays light
    /// (ScreenWalk and other hosts can show lists without the app-wide chrome).
    func brainBlackList() -> some View {
        self
            .preferredColorScheme(.dark)
            .scrollContentBackground(.hidden)
            .background(BrainChrome.canvas)
    }
}
