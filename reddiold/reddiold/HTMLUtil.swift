import UIKit

/// Text measuring for manual layout and `heightForRowAt` — the iOS 6-safe way.
/// Everything more modern is unavailable on this project's targets:
/// `UITableViewAutomaticDimension`/`estimatedRowHeight` are iOS 8+,
/// `boundingRect(with:options:attributes:context:)` is iOS 7+, and NSString's old
/// `sizeWithFont:` family is marked explicitly unavailable in Swift (a compile error, not a
/// deprecation) even though the ObjC selector exists on iOS 6. `UILabel.sizeThatFits(_:)` has
/// been there since iOS 2 and is what actually works on the hardware.
/// Measure with the same font AND numberOfLines the real label uses, or rows won't match.
struct TextMeasure {
    static func height(text: String, font: UIFont, width: CGFloat, numberOfLines: Int) -> CGFloat {
        let label = UILabel()
        label.font = font
        label.numberOfLines = numberOfLines
        label.lineBreakMode = .byWordWrapping
        label.text = text
        return label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    static func width(text: String, font: UIFont) -> CGFloat {
        let label = UILabel()
        label.font = font
        label.numberOfLines = 1
        label.text = text
        let unbounded = CGFloat.greatestFiniteMagnitude
        return ceil(label.sizeThatFits(CGSize(width: unbounded, height: unbounded)).width)
    }
}

/// Shared layout metrics. Screens were hand-laid-out one at a time with whatever inset
/// looked right (8, 12, 16, 18, 20 and 24 were all in use), which reads as sloppy when you
/// navigate between them. One constant so they can't drift apart again; 16 was already the
/// most common and lines up closely with UITableViewCell's own ~15pt text inset.
struct Layout {
    static let margin: CGFloat = 16

    /// Total horizontal space a default UITableViewCell's own labels give up (~15pt each
    /// side). Row heights have to measure text against `tableWidth - cellTextInset` or the
    /// measured height won't match what the cell actually renders, and rows overlap. This
    /// was an unexplained literal `30` in four separate row-height functions.
    static let cellTextInset: CGFloat = 30

    /// Height of the app's standard full-width action button (Go / Retry / Show Comments /
    /// Clear Cache / Load more) — see Theme.actionButton. Also the iOS minimum comfortable
    /// tap target, so the running-`y` layouts advance by it rather than a literal 44.
    static let buttonHeight: CGFloat = 44

    /// Y of the first usable point below the navigation bar, in `vc.view`'s own coordinate
    /// space. The starting `y` for every hand-laid-out screen, and what a full-height table's
    /// frame has to be offset by.
    ///
    /// This must be *measured*, because the two OS versions this single binary runs on
    /// disagree about where a pushed view controller's view begins. On iOS 6,
    /// UINavigationController sizes the view to start below the bar, so the answer is 0. Since
    /// iOS 7, `edgesForExtendedLayout` defaults to `.all` and the view is full-screen *under*
    /// a translucent bar, so the answer is ~64 — or 44 with the status bar hidden, or more
    /// during an in-call banner. Converting the bar's own bounds yields every one of those
    /// without enumerating them, which is why the same expression is correct on both.
    ///
    /// Note what this deliberately is not. `edgesForExtendedLayout` and
    /// `automaticallyAdjustsScrollViewInsets` are the conventional iOS 7+ answer, and both are
    /// iOS 7+ *properties* that crash with "unrecognized selector" on real iOS 6 — confirmed
    /// via two isolated repros, since vtool patches the deployment gate but cannot add a
    /// missing UIKit selector. It also isn't a version check or one of the `-D IOS*_TARGET`
    /// build flags: geometry is what actually differs, so geometry is what to ask.
    ///
    /// Returns 0 when there is no navigation controller (a full-screen modal such as
    /// ImagePreviewVC) and when the bar is hidden — in both cases the bar sits at or above the
    /// view's own origin, so the conversion is <= 0 and `max` clamps it.
    static func contentTop(in vc: UIViewController) -> CGFloat {
        guard let bar = vc.navigationController?.navigationBar else { return 0 }
        return max(0, bar.convert(bar.bounds, to: vc.view).maxY)
    }
}

/// Every colour the app uses, and the builders for the controls whose styling was previously
/// copy-pasted. Nothing here reads a user preference: the values are exactly what used to be
/// hardcoded at ~79 call sites, so this change is visually a no-op. It exists so a dark mode
/// only has to touch this one type plus a re-style path, rather than hunting `UIColor`
/// literals across ten view controllers.
///
/// Deliberately plain static members, not `UITraitCollection`/semantic colours (iOS 13+) and
/// not `.systemOrange`-style dynamic colours — none of that exists on iOS 6/7/8. That also
/// means nothing re-styles itself when the theme changes; views are built once in
/// `viewDidAppear`, so switching will need an explicit rebuild (PostListVC.resetForReload is
/// the existing precedent).
struct Theme {
    // MARK: - Surfaces

    static var pageBackground: UIColor { return UIColor.white }
    static var tableBackground: UIColor { return UIColor.white }
    static var cellBackground: UIColor { return UIColor.white }

    /// Read off a throwaway table view rather than hardcoded, so applying it explicitly is
    /// exactly the platform default today (no visual change) while still giving a dark theme
    /// one place to override it. Nothing set `separatorColor` before, which is precisely the
    /// kind of implicit light-mode default a dark background would expose.
    static let separator: UIColor = UITableView().separatorColor ?? UIColor.lightGray

    // MARK: - Text

    static var primaryText: UIColor { return UIColor.black }
    /// Section headings in Settings — the one place that used `.darkGray`. Kept as its own
    /// role rather than folded into `secondaryText`, since a heading legitimately wants more
    /// weight than a hint (and a dark theme will want to keep that distinction).
    static var headingText: UIColor { return UIColor.darkGray }
    static var secondaryText: UIColor { return UIColor.gray }
    /// Orange is the app's identity — nav bar, buttons, cell subtitles, depth-0 thread bars.
    static var accent: UIColor { return UIColor.orange }
    /// Text/glyphs drawn on top of `accent`.
    static var onAccent: UIColor { return UIColor.white }
    static var link: UIColor { return UIColor.blue }
    /// Momentary "that worked" background on an action button that has no other result to show
    /// (Settings > Clear Cache). Green rather than `accent` so the flash actually reads as a
    /// change from the button's normal state.
    static var confirm: UIColor { return UIColor(red: 0.30, green: 0.69, blue: 0.31, alpha: 1) }
    /// Behind an image that hasn't loaded yet.
    static var imagePlaceholder: UIColor { return UIColor(white: 0.92, alpha: 1) }

    /// Cycled per depth level for PostVC's colored left "thread line" bars, mimicking
    /// Reddit's own nested-comment look. Explicit `UIColor(red:green:blue:)` literals, not
    /// `.systemBlue`/`.systemGreen` — those are iOS 13+ and unsafe on these targets.
    static var threadBars: [UIColor] {
        return [
            accent,
            UIColor(red: 0.20, green: 0.60, blue: 0.86, alpha: 1),
            UIColor(red: 0.30, green: 0.69, blue: 0.31, alpha: 1),
            UIColor(red: 0.61, green: 0.35, blue: 0.71, alpha: 1),
            UIColor(red: 0.90, green: 0.30, blue: 0.24, alpha: 1),
            UIColor(red: 0.10, green: 0.65, blue: 0.60, alpha: 1)
        ]
    }

    // MARK: - Fixed chrome (identical in every theme)

    // These are already dark by design and must NOT follow the theme: the side menu is a
    // dark panel over the light app, and the image viewer / media badges are dark so a photo
    // stays the brightest thing on screen. Kept here so they're visibly exempt rather than
    // looking like light-mode literals someone forgot to convert.
    static let menuBackground = UIColor(white: 0.12, alpha: 1)
    static let menuText = UIColor(white: 0.92, alpha: 1)
    static let menuSeparator = UIColor(white: 1, alpha: 0.08)
    static let menuDimOverlay = UIColor(white: 0, alpha: 0.5)
    static let viewerBackground = UIColor.black
    static let overlayBadgeBackground = UIColor(white: 0, alpha: 0.6)
    static let overlayButtonBackground = UIColor(white: 0, alpha: 0.45)
    static var onOverlay: UIColor { return UIColor.white }

    // MARK: - Spinners

    /// On a themed page/table background. `.gray` is invisible on a dark surface, so which
    /// one to use is a theme decision, not a per-site one.
    static var spinnerStyle: UIActivityIndicatorView.Style { return .gray }
    /// On an accent button or dark overlay — always the light spinner.
    static var contrastSpinnerStyle: UIActivityIndicatorView.Style { return .white }

    // MARK: - Builders

    /// The app's full-width action button. Was hand-built six times with the same six lines;
    /// `.custom` rather than `.system` because iOS 6 ignores styling on system buttons.
    static func actionButton(title: String, frame: CGRect, target: Any?, action: Selector) -> UIButton {
        let button = UIButton(type: .custom)
        button.frame = frame
        button.backgroundColor = accent
        button.setTitle(title, for: .normal)
        button.setTitleColor(onAccent, for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        button.layer.cornerRadius = 8
        button.layer.masksToBounds = true
        button.addTarget(target, action: action, for: .touchUpInside)
        return button
    }

    /// The trailing progress spinner on an action button whose title switches to "Loading...".
    /// The title change alone reads as frozen on the slower requests.
    static func buttonSpinner(in button: UIButton) -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: contrastSpinnerStyle)
        spinner.center = CGPoint(x: button.bounds.width - 28, y: button.bounds.height / 2)
        spinner.hidesWhenStopped = true
        button.addSubview(spinner)
        return spinner
    }

    static func apply(to tableView: UITableView) {
        tableView.backgroundColor = tableBackground
        tableView.separatorColor = separator
    }

    static func apply(to navigationBar: UINavigationBar) {
        // iOS 6's UINavigationBar has no barTintColor (iOS 7+ only, crashes at runtime) —
        // the legacy .tintColor colours the whole bar.
        navigationBar.tintColor = accent
        navigationBar.titleTextAttributes = [NSAttributedString.Key.foregroundColor: onAccent]
    }
}

struct HTMLUtil {
    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&apos;": "'", "&nbsp;": " "
    ]

    /// Flattens markup to a single run of text, discarding block structure. For anywhere a body
    /// is shown as a one-or-two-line summary (a subreddit description in a search result), where
    /// embedded newlines would just break the row layout. Use `blockText` for anything the user
    /// actually reads.
    static func stripTags(_ html: String) -> String {
        var result = ""
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { result.append(ch) }
        }
        let decoded = decodeEntities(result)
        return asciiFold(decoded).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same as `stripTags`, but turns block-level markup into real line breaks.
    ///
    /// Reddit's Atom `<content>` carries the markdown-rendered HTML with **no newlines in it at
    /// all** — verified against a live feed, block boundaries arrive as a single space
    /// (`</h1> <p>`, `</p> <p>`). So dropping the tags outright, as `stripTags` does, runs the
    /// heading, every paragraph and every list item together into one wall of text. This markup
    /// is the only place that structure still exists, so the breaks have to be recovered here
    /// rather than from the whitespace.
    ///
    /// Deliberately plain `String`, not `NSAttributedString`: `UILabel.attributedText` exists on
    /// iOS 6, but the useful half of it (`NSHTMLTextDocumentType` import, paragraph-style-per-
    /// range measuring) is iOS 7+, and the app's row heights all come from
    /// `UILabel.sizeThatFits` — which handles `\n` correctly with `numberOfLines = 0`.
    static func blockText(_ html: String) -> String {
        var result = ""
        var tagName = ""
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true; tagName = ""; continue }
            if ch == ">" {
                inTag = false
                result += lineBreak(forTag: tagName)
                continue
            }
            if inTag { tagName.append(ch) } else { result.append(ch) }
        }
        return normalizeBreaks(asciiFold(decodeEntities(result)))
    }

    /// Tags that begin or end a block, i.e. that force a line break where they appear. Emitted
    /// for both the opening and closing form, so `</p> <p>` yields a blank line between
    /// paragraphs once `normalizeBreaks` has collapsed the run.
    private static let blockTags: Set<String> = [
        "p", "div", "br", "hr", "blockquote", "pre", "table", "tr", "ul", "ol",
        "h1", "h2", "h3", "h4", "h5", "h6"
    ]

    /// `tag` is the raw text between the angle brackets, so it can be `p`, `/p`, `br /`,
    /// `a href="..."` or an HTML comment's `!-- SC_OFF --`. Only the name matters.
    private static func lineBreak(forTag tag: String) -> String {
        var name = tag
        let isClosing = name.hasPrefix("/")
        if isClosing { name = String(name.dropFirst()) }
        if let end = name.firstIndex(where: { $0 == " " || $0 == "/" || $0 == "\t" || $0 == "\n" }) {
            name = String(name[..<end])
        }
        name = name.lowercased()
        // ASCII "- " rather than a bullet glyph: iOS 6's system font only has pre-2014 glyphs,
        // and a missing one draws as an empty box.
        if name == "li" { return isClosing ? "" : "\n- " }
        return blockTags.contains(name) ? "\n" : ""
    }

    /// Collapses the whitespace left behind by tag removal: runs of spaces/tabs become one
    /// space, spaces adjacent to a line break are dropped, and a run of breaks is capped at two
    /// (one blank line) so a deeply wrapped `</div></div></p>` doesn't open a hole in the text.
    /// Also trims both ends, which is why `blockText` doesn't call `trimmingCharacters`.
    private static func normalizeBreaks(_ text: String) -> String {
        var out = ""
        var pendingBreaks = 0
        var pendingSpace = false
        for ch in text {
            if ch == "\n" || ch == "\r" {
                pendingBreaks += 1
                pendingSpace = false
                continue
            }
            if ch == " " || ch == "\t" {
                if pendingBreaks == 0 { pendingSpace = true }
                continue
            }
            // Nothing is flushed until there's a real character after it — that's what drops
            // leading whitespace, and leaves trailing whitespace unflushed at the end.
            if !out.isEmpty {
                if pendingBreaks > 0 {
                    out += String(repeating: "\n", count: min(pendingBreaks, 2))
                } else if pendingSpace {
                    out += " "
                }
            }
            pendingBreaks = 0
            pendingSpace = false
            out.append(ch)
        }
        return out
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return decodeNumericEntities(result)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }

        var result = ""
        var chars = Substring(text)
        while let ampRange = chars.range(of: "&#") {
            result += chars[chars.startIndex..<ampRange.lowerBound]
            var rest = chars[ampRange.upperBound...]

            var isHex = false
            if rest.first == "x" || rest.first == "X" {
                isHex = true
                rest = rest.dropFirst()
            }

            var digits = ""
            var remainder = rest
            while let c = remainder.first, (isHex ? c.isHexDigit : c.isNumber) {
                digits.append(c)
                remainder = remainder.dropFirst()
            }

            if !digits.isEmpty, remainder.first == ";",
               let value = UInt32(digits, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
                chars = remainder.dropFirst()
            } else {
                result += "&#"
                chars = chars[ampRange.upperBound...]
            }
        }
        result += chars
        return result
    }

    private static func asciiFold(_ text: String) -> String {
        var result = text
        let map: [String: String] = [
            "\u{2018}": "'", "\u{2019}": "'",
            "\u{201C}": "\"", "\u{201D}": "\"",
            "\u{2013}": "-", "\u{2014}": "--",
            "\u{2026}": "..."
        ]
        for (from, to) in map {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }
}
