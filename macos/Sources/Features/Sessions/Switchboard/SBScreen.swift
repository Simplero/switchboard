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
    static let permission = re(#"Do you want to (proceed|make this edit|create|run)|❯ 1\. Yes|Allow command\?|approve this"#)
    static let noise = re(#"^[\s─━╭╰│▔▁]*$|⏵⏵|bypass permissions|shift\+tab|esc to interrupt|ctrl\+b to run|Tip:|/focus to show|disable recaps"#)
    static let rule = re(#"^\s*[─━]{20,}"#)
    static let footer = re(#"⏵⏵|bypass permissions|shift\+tab|esc to|Update installed|ctrl\+|^\s*[⏺◯] (main|general-purpose)|^\s*\S\s+[A-Z][\w'-]+… \(|Tip:"#)
    static let shellTitle = re(#"^[\w.-]+@[\w.-]+:|^(claude|zsh|bash|sh|-zsh|new session|terminal|switchboard)$"#, .caseInsensitive)
    static let titleLead = re(#"^[^\w(\[]+"#)

    static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Lines like Python's str.splitlines(): no empty last line for a trailing newline.
    static func lines(_ s: String) -> [String] {
        var out = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if out.last == "" { out.removeLast() }
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

    /// "permission", "working" or "idle".
    static func state(_ screen: String) -> String {
        let last = Array(lines(screen).filter { !strip($0).isEmpty }.suffix(25))
        if matches(permission, last.joined(separator: "\n")) { return "permission" }
        for l in last.suffix(12) where matches(spinner, l) || matches(codexWorking, l) { return "working" }
        return "idle"
    }

    /// The agent's own "working" line (spinner and what it does).
    static func workingLine(_ screen: String) -> String {
        for l in lines(screen).filter({ !strip($0).isEmpty }).reversed() where matches(spinner, l) || matches(codexWorking, l) {
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
