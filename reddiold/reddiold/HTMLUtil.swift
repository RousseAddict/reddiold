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
