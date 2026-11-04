// Linux scratch shim: NoteText.swift needs Apple-only AttributedString Markdown. Copy of isRightToLeft only.
public enum NoteText {
    public static func isRightToLeft(_ s: some StringProtocol) -> Bool {
        for u in s.unicodeScalars {
            switch u.value {
            case 0x200F: return true
            case 0x200E: return false
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                if u.properties.isAlphabetic || u.properties.generalCategory == .otherLetter { return true }
            default:
                if u.properties.isAlphabetic { return false }
            }
        }
        return false
    }
}
