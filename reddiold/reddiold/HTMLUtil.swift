import Foundation

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
