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
