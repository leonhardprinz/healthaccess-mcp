import Foundation

/// The little XML the WebDAV and S3 answers need: a list of records (one per file), each a flat set of
/// element name → text, plus the fields outside any record. Namespaces are dropped; nesting is flattened.
final class CloudXML: NSObject, XMLParserDelegate {
    struct Result {
        var records: [[String: String]] = []
        var top: [String: String] = [:]
    }

    private let recordNames: Set<String>
    private var result = Result()
    private var current: [String: String]?
    private var text = ""

    private init(recordNames: Set<String>) { self.recordNames = recordNames }

    static func parse(_ data: Data, records: Set<String>) throws -> Result {
        let delegate = CloudXML(recordNames: records)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw CloudError.unexpected("the server's answer was not readable XML") }
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if recordNames.contains(name) {
            current = ["_kind": name]
        } else if var record = current {
            // An empty element inside a record still says something: <collection/> marks a folder.
            if record[name] == nil { record[name] = "" }
            current = record
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if recordNames.contains(name) {
            if let current { result.records.append(current) }
            current = nil
        } else if current != nil {
            if !value.isEmpty { current?[name] = value }
        } else if !value.isEmpty {
            result.top[name] = value
        }
        text = ""
    }
}
