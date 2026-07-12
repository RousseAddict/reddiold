import Foundation

/// Manual parser for Reddit's Atom `<updated>` timestamps, e.g. "2026-07-09T13:11:32+00:00".
/// Avoids DateFormatter's 'X' offset pattern symbol (uncertain ICU support on iOS 6).
/// Assumes UTC — matches all observed Reddit data.
struct AtomDate {
    static func parse(_ string: String) -> Date? {
        let parts = string.split(separator: "T")
        guard parts.count == 2 else { return nil }

        let dateParts = parts[0].split(separator: "-")
        guard dateParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2])
        else { return nil }

        let timeString = String(parts[1].prefix(8)) // "HH:MM:SS", ignore offset
        let timeParts = timeString.split(separator: ":")
        guard timeParts.count == 3,
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        return calendar.date(from: components)
    }
}

/// Raw entry parsed out of a Reddit Atom (.rss) feed, before being converted
/// into a Post or Comment. Namespace processing is OFF by default on XMLParser,
/// so qualified elements like <media:thumbnail> arrive as literal element names.
struct AtomEntry {
    var id: String = ""
    var title: String = ""
    var authorName: String = ""
    var subreddit: String = ""
    var link: String = ""
    var thumbnailURL: String?
    var contentHTML: String = ""
    var updated: String = ""
}

/// Parses Reddit's Atom feed XML (old.reddit.com/*.rss) into AtomEntry structs.
final class AtomFeedParser: NSObject, XMLParserDelegate {

    private var entries: [AtomEntry] = []
    private var current: AtomEntry?
    private var buffer: String = ""
    private var inAuthor = false

    static func parseEntries(data: Data) -> [AtomEntry] {
        let parser = AtomFeedParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        buffer = ""

        switch elementName {
        case "entry":
            current = AtomEntry()
        case "author":
            inAuthor = true
        case "category":
            if let term = attributeDict["term"] {
                current?.subreddit = term
            }
        case "link":
            if let href = attributeDict["href"] {
                current?.link = href
            }
        case "media:thumbnail":
            if let url = attributeDict["url"] {
                current?.thumbnailURL = url
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "id":
            current?.id = trimmed
        case "title":
            current?.title = trimmed
        case "name":
            if inAuthor {
                current?.authorName = trimmed
            }
        case "author":
            inAuthor = false
        case "content":
            current?.contentHTML = trimmed
        case "updated":
            current?.updated = trimmed
        case "entry":
            if let entry = current {
                entries.append(entry)
            }
            current = nil
        default:
            break
        }

        buffer = ""
    }
}
