import BrainNotesKit
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Times `MarkdownStyler` on a synthetic note the size of the largest real one, in a real text view's storage,
/// TextKit 2 attached. `EditorSpikeTests` runs it on the Mac; the `-BNScreen editor-spike` screen shows the same
/// numbers on the device, which is where the budgets apply.
@MainActor
enum StyleTiming {
    struct Result {
        var bytes: Int
        var paragraphs: Int
        /// The first pass over the note, as when it opens.
        var firstFull: Double
        var medianFull: Double
        var medianParagraph: Double
        var worstParagraph: Double
        /// Not styling, and not in the budget, but on the same keystroke: the text view hands over the whole
        /// note and the model compares it with what it has. Edited in the middle, so it stops halfway.
        var medianTextAndCompare: Double

        var summary: String {
            let f = { (ms: Double) in ms.formatted(.number.precision(.fractionLength(ms < 10 ? 2 : 0))) }
            return "\(bytes / 1000) KB, \(paragraphs) paragraphs: full \(f(firstFull)) ms first, \(f(medianFull)) ms median (budget 150). Paragraph \(f(medianParagraph)) ms median, \(f(worstParagraph)) ms worst (budget 2). Text and compare per keystroke \(f(medianTextAndCompare)) ms."
        }
    }

    /// Mixed Hebrew and English, headings, bold and tasks. All generated here: no real note's text.
    static func syntheticNote(targetBytes: Int = 271_000) -> String {
        var out = "# הערה סינתטית לבדיקת זמנים\n"
        var line = 0
        while out.utf8.count < targetBytes {
            if line % 55 == 0 { out += "\n## Heading \(line / 55) כותרת\n" }
            switch line % 4 {
            case 0: out += "Line \(line) with a **bold phrase** and enough words to read like a real paragraph.\n"
            case 1: out += "שורה \(line) עם **מילים מודגשות** ועוד כמה מילים כדי שתיראה כמו פסקה אמיתית.\n"
            case 2: out += "- [ ] משימה \(line) with an English word, כמו SwiftUI, באמצע השורה\n"
            default: out += "- [x] Task \(line) that is already done, ואחריו קצת עברית\n"
            }
            line += 1
        }
        return out
    }

    static func measure(text: String = syntheticNote(), fullPasses: Int = 3, paragraphSamples: Int = 100) -> Result? {
        #if os(iOS)
        let view = UITextView(usingTextLayoutManager: true)
        view.text = text
        let storage: NSTextStorage? = view.textStorage
        let currentText = { view.text ?? "" }
        #else
        let view = NSTextView.scrollableTextView().documentView as? NSTextView
        view?.string = text
        let storage = view?.textStorage
        let currentText = { view?.string ?? "" }
        #endif
        guard let storage, storage.length > 0 else { return nil }

        let clock = ContinuousClock()
        func milliseconds(_ work: () -> Void) -> Double {
            let (seconds, attoseconds) = clock.measure(work).components
            return Double(seconds) * 1000 + Double(attoseconds) / 1e15
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

        let whole = NSRange(location: 0, length: storage.length)
        var context = MarkdownStyler.Context()
        context.fences = FencedCode(text: storage.string as NSString)
        let styling = context
        let full = (0..<fullPasses).map { _ in milliseconds { MarkdownStyler.style(storage, in: whole, context: styling) } }
        let single = (0..<paragraphSamples).map { i in
            milliseconds { MarkdownStyler.style(storage, in: NSRange(location: storage.length * i / paragraphSamples, length: 1), context: styling) }
        }
        var paragraphs = 0
        (storage.string as NSString).enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, _, _, _ in paragraphs += 1 }
        var previous = currentText()
        let compare = (0..<21).map { _ in
            storage.replaceCharacters(in: NSRange(location: storage.length / 2, length: 0), with: "x")
            return milliseconds {
                let now = currentText()
                _ = sameBytes(now, previous)
                previous = now
            }
        }
        return withExtendedLifetime(view) {
            Result(bytes: text.utf8.count, paragraphs: paragraphs, firstFull: full[0], medianFull: median(full),
                   medianParagraph: median(single), worstParagraph: single.max() ?? 0, medianTextAndCompare: median(compare))
        }
    }
}

/// `-BNScreen editor-spike` only: this device's numbers, under the status line.
struct StyleTimingLine: View {
    @State private var line = "Timing the style pass…"

    var body: some View {
        Text(line)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .accessibilityIdentifier("spike.timing")
            .task {
                // After the keyboard is up: this holds the main thread for as long as the passes take.
                try? await Task.sleep(for: .seconds(1.5))
                line = StyleTiming.measure()?.summary ?? "No timing."
            }
    }
}
