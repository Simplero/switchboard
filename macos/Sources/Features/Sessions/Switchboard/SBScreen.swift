import CryptoKit
import Foundation

/// Reading a coding agent's terminal: is it working, asking for permission, or idle;
/// what it is doing; the part of the screen that is the conversation.
enum SBScreen {
    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: opts.union(.anchorsMatchLines))
    }

    static let spinner = re(#"^\s*\S\s+[A-Z][\w'-]+…\s*\("#)
    static let codexWorking = re(#"^\s*\S?\s*Working \(\d|Waiting for \d+ background agent"#, .caseInsensitive)
    /// Antigravity CLI (agy) while it works: "esc to cancel" under the prompt box, and a
    /// braille spinner in front of what it thinks.
    static let agyWorking = re(#"^\s*esc to cancel\s*$"#)
    static let brailleSpinner = re(#"^\s*[\x{2801}-\x{28FF}]\s+\S"#)
    static let permission = re(#"Do you want to (proceed|make this edit|create|run)|❯ 1\. Yes|Allow command\?|approve this|Do you trust the contents of this project\?"#)
    static let noise = re(#"^[\s─━╭╰│▔▁]*$|⏵⏵|bypass permissions|shift\+tab|esc to interrupt|esc to cancel|\? for shortcuts|ctrl\+b to run|Tip:|/focus to show|disable recaps"#)
    static let rule = re(#"^\s*[─━]{20,}"#)
    static let footer = re(#"⏵⏵|bypass permissions|shift\+tab|esc to|Update installed|\? for shortcuts|ctrl\+|^\s*[⏺◯] (main|general-purpose)|^\s*\S\s+[A-Z][\w'-]+… \(|Tip:"#)
    static let shellTitle = re(#"^[\w.-]+@[\w.-]+:|^(claude|zsh|bash|sh|-zsh|new session|terminal|switchboard)$"#, .caseInsensitive)
    static let titleLead = re(#"^[^\w(\[]+"#)

    static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Lines like Python's str.splitlines(): no empty last line for a trailing newline.
    static func lines(_ s: String) -> [String] {
        // The same line ends as Python: \n \r \r\n \v \f \x1c \x1d \x1e \x85 \u2028 \u2029.
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        while let c = pending ?? it.next() {
            pending = nil
            switch c.value {
            case 0x0D:
                out.append(String(cur)); cur = .init()
                if let n = it.next(), n.value != 0x0A { pending = n }
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                out.append(String(cur)); cur = .init()
            default:
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    static func strip(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func rstrip(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let before = s.index(before: end)
            guard s[before].isWhitespace else { break }
            end = before
        }
        return String(s[..<end])
    }

    /// The screen without Claude's input box and status lines below it, so typing,
    /// clicking or a blinking cursor does not count as a new agent message.
    static func conversationPart(_ screen: String) -> String {
        var ls = lines(screen)
        let rules = ls.indices.filter { matches(rule, ls[$0]) }
        let tailRules = rules.filter { $0 >= ls.count - 25 }
        if tailRules.count >= 2 {
            ls = Array(ls[..<tailRules[tailRules.count - 2]])
        } else if let last = tailRules.last {
            ls = Array(ls[..<last])
        }
        return ls.filter { !strip($0).isEmpty && !matches(footer, $0) }.map(rstrip).joined(separator: "\n")
    }

    /// The last lines of the screen without the agent's chrome, for the summary.
    static func cleanTail(_ screen: String, _ n: Int = 70) -> String {
        let ls = lines(screen).map(rstrip).filter { !matches(noise, $0) }
        return strip(ls.suffix(n).joined(separator: "\n"))
    }

    /// Work that goes on after Claude's turn: its footer counts background shells, monitors
    /// and agents ("· 2 shells", "· 1 monitor"), and a running agent's row starts with ◯.
    static let backgroundWork = re(#"·\s*\d+\s+(shells?|background tasks?|monitors?|agents?)\b|^\s*◯ "#)

    static func backgroundBusy(_ screen: String) -> Bool {
        lines(screen).filter { !strip($0).isEmpty }.suffix(5).contains { matches(backgroundWork, $0) }
    }

    /// What is in Claude's prompt box: "" when it is empty, else its text (what you typed, or
    /// Claude's grey suggestion of your next message). Nil when no prompt box shows (a menu
    /// or a dialog is open).
    static func promptText(_ screen: String) -> String? {
        let ls = lines(screen)
        guard let i = ls.lastIndex(where: { $0.hasPrefix("❯") }), i > 0, matches(rule, ls[i - 1]) else { return nil }
        var parts = [String(ls[i].dropFirst())]
        var j = i + 1
        while j < ls.count, !matches(rule, ls[j]) { parts.append(ls[j]); j += 1 }
        guard j < ls.count else { return nil }   // no line under it: not the prompt box
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// "permission", "working" or "idle".
    static func state(_ screen: String) -> String {
        let last = Array(lines(screen).filter { !strip($0).isEmpty }.suffix(25))
        if matches(permission, last.joined(separator: "\n")) { return "permission" }
        for l in last.suffix(12) where matches(spinner, l) || matches(codexWorking, l) || matches(agyWorking, l) { return "working" }
        return "idle"
    }

    /// The agent's own "working" line (spinner and what it does).
    static func workingLine(_ screen: String) -> String {
        for l in lines(screen).filter({ !strip($0).isEmpty }).reversed() where matches(spinner, l) || matches(codexWorking, l) || matches(brailleSpinner, l) {
            return strip(l)
        }
        return ""
    }

    /// Claude's terminal title without its status mark (✳, spinner); nil for a shell
    /// prompt or a placeholder.
    static func cleanTerminalTitle(_ t: String?) -> String? {
        let s0 = strip(t ?? "")
        let s = strip(titleLead.stringByReplacingMatches(in: s0, range: NSRange(s0.startIndex..., in: s0), withTemplate: ""))
        if s.isEmpty || matches(shellTitle, s) { return nil }
        return String(s.prefix(60))
    }

    /// The summary cache key of a screen: its last 40 conversation lines.
    static func summaryKey(_ screen: String) -> String {
        let convo = conversationPart(screen)
        let text = lines(convo).suffix(40).joined(separator: "\n")
        return Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
