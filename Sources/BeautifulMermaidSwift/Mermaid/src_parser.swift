// Ported from original/src/parser.ts
import Foundation
import ElkSwift

private typealias ParsedDirection = original_src_types.Direction
private typealias ParsedNodeShape = original_src_types.NodeShape
private typealias ParsedEdgeStyle = original_src_types.EdgeStyle
private typealias ParsedNode = original_src_types.MermaidNode
private typealias ParsedEdge = original_src_types.MermaidEdge
private typealias ParsedSubgraph = original_src_types.MermaidSubgraph
private typealias ParsedGraph = original_src_types.MermaidGraph

private enum _ParserEntryError: LocalizedError {
    case emptyDiagram
    case invalidHeader(String)
    case invalidFlowchartLink(String)
    case unsupportedFlowchartLink(String)

    var errorDescription: String? {
        switch self {
        case .emptyDiagram:
            return "The Mermaid diagram is empty."
        case .invalidHeader(let header):
            return "Invalid Mermaid diagram header: \(header)"
        case .invalidFlowchartLink(let text):
            return "Invalid or incomplete flowchart link: \(text)"
        case .unsupportedFlowchartLink(let text):
            return "Unsupported flowchart link: \(text)"
        }
    }
}

private struct _WorkingGraph {
    var direction: ParsedDirection
    var nodesById: [String: ParsedNode] = [:]
    var nodeOrder: [String] = []
    var edges: [ParsedEdge] = []
    var subgraphs: [ParsedSubgraph] = []
    var subgraphIds: Set<String> = []
    var classDefs: [String: [String: String]] = [:]
    var classAssignments: [String: String] = [:]
    var nodeStyles: [String: [String: String]] = [:]
    /// Maps edge indices (or -1 for 'default') to inline styles from `linkStyle` directives
    var linkStyles: [Int: [String: String]] = [:]

    mutating func upsertNode(_ node: ParsedNode) {
        if nodesById[node.id] == nil {
            nodeOrder.append(node.id)
        }
        nodesById[node.id] = node
    }

    mutating func mergeNodeStyle(_ id: String, _ props: [String: String]) {
        var merged = nodeStyles[id] ?? [:]
        for (k, v) in props {
            merged[k] = v
        }
        nodeStyles[id] = merged
    }

    func toParsedGraph() -> ParsedGraph {
        let nodesInOrder: [(id: String, node: ParsedNode)] = nodeOrder.compactMap { id in
            guard let node = nodesById[id] else { return nil }
            return (id: id, node: node)
        }
        return ParsedGraph(
            direction: direction,
            nodesInOrder: nodesInOrder,
            edges: edges,
            subgraphs: subgraphs,
            classDefs: classDefs,
            classAssignments: classAssignments,
            nodeStyles: nodeStyles,
            linkStyles: linkStyles
        )
    }
}

private struct _ConsumedNode {
    var id: String
    var remaining: String
}

private struct _ConsumedNodeGroup {
    var ids: [String]
    var remaining: String
}

private func _regex(_ pattern: String) -> NSRegularExpression {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        assertionFailure("Invalid regex pattern: \(pattern)")
        return NSRegularExpression()
    }
    return regex
}

private let _solidLink = #"-{2,}[>xo-]"#
private let _thickLink = #"={2,}[>xo=]"#
private let _dottedLinkEnd = #"\.+-[>xo]?"#
private let _arrowRegex = _regex(
    #"^([<xo])?(\#(_solidLink)|\#(_thickLink)|-\#(_dottedLinkEnd))(?:\s*\|([^|]*)\|)?"#
)
private let _textEmbeddedArrowRegexes = [
    ("--", #"(?:[^"-]|-(?!-))+?"#, _solidLink),
    ("==", #"(?:[^"=]|=(?!=))+?"#, _thickLink),
    (#"-\."#, #"[^"]+?"#, #"-?\#(_dottedLinkEnd)"#),
].map { opening, label, closing in
    _regex(#"^([<xo])?\#(opening)\s*("[^"]*"|\#(label))\s*([<xo])?(\#(closing))"#)
}
private let _flowchartLinkStartRegex = _regex(#"^(?:[<xo])?(?:--|==|-\.)"#)
// A single hyphen can be part of an ID. Double hyphens and hyphen-dot begin links.
private let _bareNodeRegex = _regex(#"^((?:\w|-(?![-.]))+)"#)
private let _classShorthandRegex = _regex(#"^:::([\w][\w-]*)"#)

private let _nodePatterns: [(regex: NSRegularExpression, shape: ParsedNodeShape)] = [
    (_regex(#"^([\w-]+)\(\(\((.+?)\)\)\)"#), .doublecircle),
    (_regex(#"^([\w-]+)\(\[(.+?)\]\)"#), .stadium),
    (_regex(#"^([\w-]+)\(\((.+?)\)\)"#), .circle),
    (_regex(#"^([\w-]+)\[\[(.+?)\]\]"#), .subroutine),
    (_regex(#"^([\w-]+)\[\((.+?)\)\]"#), .cylinder),
    (_regex(#"^([\w-]+)\[\/(.+?)\\\]"#), .trapezoid),
    (_regex(#"^([\w-]+)\[\\(.+?)\/\]"#), .trapezoidAlt),
    (_regex(#"^([\w-]+)>(.+?)\]"#), .asymmetric),
    (_regex(#"^([\w-]+)\{\{(.+?)\}\}"#), .hexagon),
    (_regex(#"^([\w-]+)\[(.+?)\]"#), .rectangle),
    (_regex(#"^([\w-]+)\((.+?)\)"#), .rounded),
    (_regex(#"^([\w-]+)\{(.+?)\}"#), .diamond),
]

public func parseMermaid(_ text: String) throws -> MermaidGraph {
    try _parseMermaidEntry(text)
}

private func _parseMermaidEntry(_ text: String) throws -> MermaidGraph {
    let lines = text
        .components(separatedBy: CharacterSet(charactersIn: "\n;"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("%%") }

    guard !lines.isEmpty else {
        throw _ParserEntryError.emptyDiagram
    }

    let header = lines[0]
    let parsed: ParsedGraph
    let diagramType: DiagramType

    if _regexTest(#"^stateDiagram(-v2)?\s*$"#, header, caseInsensitive: true) {
        parsed = try _parseStateDiagram(lines)
        diagramType = .stateDiagram
    } else {
        parsed = try _parseFlowchart(lines)
        diagramType = .flowchart
    }

    return MermaidGraph(type: diagramType, payload: parsed)
}

private func _parseFlowchart(_ lines: [String]) throws -> ParsedGraph {
    guard let header = lines.first else {
        throw _ParserEntryError.invalidHeader("")
    }

    guard let match = _regexGroups(#"^(?:graph|flowchart)\s+(TD|TB|LR|BT|RL)\s*$"#, header, caseInsensitive: true),
          let dirToken = match[safe: 1],
          let direction = _parseDirection(dirToken)
    else {
        throw _ParserEntryError.invalidHeader(header)
    }

    var graph = _WorkingGraph(direction: direction)
    var subgraphStack: [ParsedSubgraph] = []

    if lines.count <= 1 {
        return graph.toParsedGraph()
    }

    // Pre-scan: collect all subgraph IDs so forward-referenced subgraphs aren't
    // mistaken for bare nodes during edge parsing.
    for line in lines.dropFirst() {
        if let subgraphMatch = _regexGroups(#"^subgraph\s+(.+)$"#, line),
           let restRaw = subgraphMatch[safe: 1]
        {
            let rest = restRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let bracketMatch = _regexGroups(#"^([\w-]+)\s*\[(.+)\]$"#, rest),
               let foundId = bracketMatch[safe: 1]
            {
                graph.subgraphIds.insert(foundId)
            } else {
                let id = rest
                    .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
                    .replacingOccurrences(of: #"[^\w]"#, with: "", options: .regularExpression)
                graph.subgraphIds.insert(id)
            }
        }
    }

    for line in lines.dropFirst() {
        if let classDefMatch = _regexGroups(#"^classDef\s+(\w+)\s+(.+)$"#, line),
           let name = classDefMatch[safe: 1],
           let propsStr = classDefMatch[safe: 2]
        {
            graph.classDefs[name] = _parseStyleProps(propsStr)
            continue
        }

        if let classAssignMatch = _regexGroups(#"^class\s+([\w,-]+)\s+(\w+)$"#, line),
           let idsRaw = classAssignMatch[safe: 1],
           let className = classAssignMatch[safe: 2]
        {
            for id in idsRaw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !id.isEmpty {
                graph.classAssignments[id] = className
            }
            continue
        }

        if let styleMatch = _regexGroups(#"^style\s+([\w,-]+)\s+(.+)$"#, line),
           let idsRaw = styleMatch[safe: 1],
           let propsRaw = styleMatch[safe: 2]
        {
            let props = _parseStyleProps(propsRaw)
            for id in idsRaw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !id.isEmpty {
                graph.mergeNodeStyle(id, props)
            }
            continue
        }

        // --- linkStyle: `linkStyle 0 stroke:#f00` or `linkStyle default stroke:#f00` ---
        if let lsMatch = _regexGroups(#"^linkStyle\s+(default|[\d,\s]+)\s+(.+)$"#, line),
           let target = lsMatch[safe: 1],
           let propsRaw = lsMatch[safe: 2]
        {
            let props = _parseStyleProps(propsRaw)
            if target.trimmingCharacters(in: .whitespacesAndNewlines) == "default" {
                var merged = graph.linkStyles[-1] ?? [:]
                for (k, v) in props { merged[k] = v }
                graph.linkStyles[-1] = merged
            } else {
                for part in target.split(separator: ",") {
                    if let idx = Int(part.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        var merged = graph.linkStyles[idx] ?? [:]
                        for (k, v) in props { merged[k] = v }
                        graph.linkStyles[idx] = merged
                    }
                }
            }
            continue
        }

        if let dirMatch = _regexGroups(#"^direction\s+(TD|TB|LR|BT|RL)\s*$"#, line, caseInsensitive: true),
           let dirToken = dirMatch[safe: 1],
           let dir = _parseDirection(dirToken),
           !subgraphStack.isEmpty
        {
            subgraphStack[subgraphStack.count - 1].direction = dir
            continue
        }

        if let subgraphMatch = _regexGroups(#"^subgraph\s+(.+)$"#, line),
           let restRaw = subgraphMatch[safe: 1]
        {
            let rest = restRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let id: String
            let label: String

            if let bracketMatch = _regexGroups(#"^([\w-]+)\s*\[(.+)\]$"#, rest),
               let foundId = bracketMatch[safe: 1],
               let foundLabel = bracketMatch[safe: 2]
            {
                id = foundId
                label = original_src_multiline_utils.normalizeBrTags(foundLabel)
            } else {
                label = original_src_multiline_utils.normalizeBrTags(rest)
                id = rest
                    .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
                    .replacingOccurrences(of: #"[^\w]"#, with: "", options: .regularExpression)
            }

            graph.subgraphIds.insert(id)
            subgraphStack.append(ParsedSubgraph(id: id, label: label, nodeIds: [], children: [], direction: nil))
            continue
        }

        if line == "end" {
            let completed = subgraphStack.popLast()
            if let completed {
                if !subgraphStack.isEmpty {
                    subgraphStack[subgraphStack.count - 1].children.append(completed)
                } else {
                    graph.subgraphs.append(completed)
                }
            }
            continue
        }

        try _parseEdgeLine(line, graph: &graph, subgraphStack: &subgraphStack)
    }

    return graph.toParsedGraph()
}

private func _parseStateDiagram(_ lines: [String]) throws -> ParsedGraph {
    var graph = _WorkingGraph(direction: .TD)

    var compositeStack: [ParsedSubgraph] = []
    var compositeStateIds = Set<String>()
    var startCount = 0
    var endCount = 0

    if lines.count <= 1 {
        return graph.toParsedGraph()
    }

    for line in lines.dropFirst() {
        if let dirMatch = _regexGroups(#"^direction\s+(TD|TB|LR|BT|RL)\s*$"#, line, caseInsensitive: true),
           let dirToken = dirMatch[safe: 1],
           let direction = _parseDirection(dirToken)
        {
            if !compositeStack.isEmpty {
                compositeStack[compositeStack.count - 1].direction = direction
            } else {
                graph.direction = direction
            }
            continue
        }

        // --- linkStyle in state diagrams ---
        if let lsMatch = _regexGroups(#"^linkStyle\s+(default|[\d,\s]+)\s+(.+)$"#, line),
           let target = lsMatch[safe: 1],
           let propsRaw = lsMatch[safe: 2]
        {
            let props = _parseStyleProps(propsRaw)
            if target.trimmingCharacters(in: .whitespacesAndNewlines) == "default" {
                var merged = graph.linkStyles[-1] ?? [:]
                for (k, v) in props { merged[k] = v }
                graph.linkStyles[-1] = merged
            } else {
                let indices = target.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                for idx in indices {
                    var merged = graph.linkStyles[idx] ?? [:]
                    for (k, v) in props { merged[k] = v }
                    graph.linkStyles[idx] = merged
                }
            }
            continue
        }

        if let compositeMatch = _regexGroups(#"^state\s+(?:\"([^\"]+)\"\s+as\s+)?([\w\p{L}]+)\s*\{$"#, line),
           let id = compositeMatch[safe: 2]
        {
            let raw1 = compositeMatch[safe: 1]
            let label = (raw1?.isEmpty == false) ? raw1! : id
            compositeStack.append(ParsedSubgraph(id: id, label: label, nodeIds: [], children: [], direction: nil))
            compositeStateIds.insert(id)
            graph.nodesById.removeValue(forKey: id)
            graph.nodeOrder.removeAll { $0 == id }
            continue
        }

        if line == "}" {
            let completed = compositeStack.popLast()
            if let completed {
                if !compositeStack.isEmpty {
                    compositeStack[compositeStack.count - 1].children.append(completed)
                } else {
                    graph.subgraphs.append(completed)
                }
            }
            continue
        }

        if let aliasMatch = _regexGroups(#"^state\s+\"([^\"]+)\"\s+as\s+([\w\p{L}]+)\s*$"#, line),
           let labelRaw = aliasMatch[safe: 1],
           let id = aliasMatch[safe: 2]
        {
            let label = original_src_multiline_utils.normalizeBrTags(labelRaw)
            _registerStateNode(&graph, &compositeStack, ParsedNode(id: id, label: label, shape: .rounded))
            continue
        }

        if let transitionMatch = _regexGroups(#"^(\[\*\]|[\w\p{L}-]+)\s*(-->)\s*(\[\*\]|[\w\p{L}-]+)(?:\s*:\s*(.+))?$"#, line),
           let sourceRaw = transitionMatch[safe: 1],
           let targetRaw = transitionMatch[safe: 3]
        {
            var sourceId = sourceRaw
            var targetId = targetRaw
            let rawLabel = transitionMatch[safe: 4]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let edgeLabel = (rawLabel?.isEmpty == false) ? original_src_multiline_utils.normalizeBrTags(rawLabel!) : nil

            if sourceId == "[*]" {
                startCount += 1
                sourceId = startCount > 1 ? "_start\(startCount)" : "_start"
                _registerStateNode(&graph, &compositeStack, ParsedNode(id: sourceId, label: "", shape: .stateStart))
            } else if !compositeStateIds.contains(sourceId) {
                _ensureStateNode(&graph, &compositeStack, sourceId)
            }

            if targetId == "[*]" {
                endCount += 1
                targetId = endCount > 1 ? "_end\(endCount)" : "_end"
                _registerStateNode(&graph, &compositeStack, ParsedNode(id: targetId, label: "", shape: .stateEnd))
            } else if !compositeStateIds.contains(targetId) {
                _ensureStateNode(&graph, &compositeStack, targetId)
            }

            graph.edges.append(
                ParsedEdge(
                    source: sourceId,
                    target: targetId,
                    label: edgeLabel,
                    style: .solid,
                    hasArrowStart: false,
                    hasArrowEnd: true
                )
            )
            continue
        }

        if let descMatch = _regexGroups(#"^([\w\p{L}-]+)\s*:\s*(.+)$"#, line),
           let id = descMatch[safe: 1],
           let labelRaw = descMatch[safe: 2]
        {
            let label = original_src_multiline_utils.normalizeBrTags(labelRaw.trimmingCharacters(in: .whitespacesAndNewlines))
            _registerStateNode(&graph, &compositeStack, ParsedNode(id: id, label: label, shape: .rounded))
            continue
        }
    }

    return graph.toParsedGraph()
}

private func _registerStateNode(_ graph: inout _WorkingGraph, _ compositeStack: inout [ParsedSubgraph], _ node: ParsedNode) {
    let isNew = graph.nodesById[node.id] == nil
    if isNew {
        graph.upsertNode(node)
    }
    if !compositeStack.isEmpty {
        let current = compositeStack[compositeStack.count - 1]
        if !current.nodeIds.contains(node.id) {
            current.nodeIds.append(node.id)
        }
    }
}

private func _ensureStateNode(_ graph: inout _WorkingGraph, _ compositeStack: inout [ParsedSubgraph], _ id: String) {
    if graph.nodesById[id] == nil {
        _registerStateNode(&graph, &compositeStack, ParsedNode(id: id, label: id, shape: .rounded))
    } else if !compositeStack.isEmpty {
        let current = compositeStack[compositeStack.count - 1]
        if !current.nodeIds.contains(id) {
            current.nodeIds.append(id)
        }
    }
}

private func _parseStyleProps(_ propsStr: String) -> [String: String] {
    // Strip trailing semicolons — Mermaid tolerates them (e.g. `stroke:#f00;`)
    let cleaned = propsStr.replacingOccurrences(of: #";[\s]*$"#, with: "", options: .regularExpression)
    var props: [String: String] = [:]
    for pair in cleaned.split(separator: ",", omittingEmptySubsequences: false) {
        let item = String(pair)
        guard let idx = item.firstIndex(of: ":") else { continue }
        let key = item[..<idx].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = item[item.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, !value.isEmpty {
            props[key] = value
        }
    }
    return props
}

private struct _FlowchartLink {
    let remaining: String
    let label: String?
    let style: ParsedEdgeStyle
    let hasArrowStart: Bool
    let hasArrowEnd: Bool
    let minimumRankSpan: Int
}

private func _consumeFlowchartLink(_ text: String) throws -> _FlowchartLink? {
    let full: String
    let openingMarker: String
    let closingMarker: String
    let op: String
    let label: String?
    if let match = _regexMatch(_arrowRegex, text) {
        full = match[0]
        openingMarker = ""
        closingMarker = match[1]
        op = match[2]
        label = match[3]
    } else if let match = _textEmbeddedArrowRegexes.lazy.compactMap({ _regexMatch($0, text) }).first {
        full = match[0]
        openingMarker = match[1]
        closingMarker = match[3]
        op = match[4]
        let embeddedLabel = match[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !embeddedLabel.isEmpty else {
            throw _ParserEntryError.invalidFlowchartLink(full)
        }
        label = embeddedLabel
    } else if text.hasPrefix("~~~") {
        throw _ParserEntryError.unsupportedFlowchartLink(text)
    } else if _regexMatch(_flowchartLinkStartRegex, text) != nil {
        throw _ParserEntryError.invalidFlowchartLink(text)
    } else {
        return nil
    }

    let hasArrowEnd = op.hasSuffix(">")
    let closingHasArrowStart = closingMarker == "<" && hasArrowEnd
    if op.hasSuffix("o") || op.hasSuffix("x") || openingMarker == "o" || openingMarker == "x" {
        throw _ParserEntryError.unsupportedFlowchartLink(full)
    }
    if openingMarker == "<" && (!hasArrowEnd || closingHasArrowStart) {
        throw _ParserEntryError.invalidFlowchartLink(full)
    }

    let style: ParsedEdgeStyle
    let minimumRankSpan: Int
    if op.contains(".") {
        style = .dotted
        minimumRankSpan = op.filter { $0 == "." }.count
    } else {
        let linePrefix = closingHasArrowStart ? "" : closingMarker
        style = (linePrefix + op).hasPrefix("=") ? .thick : .solid
        minimumRankSpan = linePrefix.count + op.count - 2
    }

    var trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let quoted = trimmedLabel, quoted.hasPrefix("\""), quoted.hasSuffix("\"") {
        trimmedLabel = String(quoted.dropFirst().dropLast())
    }
    return _FlowchartLink(
        remaining: String(text.dropFirst(full.count)).trimmingCharacters(in: .whitespacesAndNewlines),
        label: trimmedLabel.flatMap { $0.isEmpty ? nil : original_src_multiline_utils.normalizeBrTags($0) },
        style: style,
        hasArrowStart: openingMarker == "<" || closingHasArrowStart,
        hasArrowEnd: hasArrowEnd,
        // Mermaid caps the rank span at ten.
        minimumRankSpan: min(minimumRankSpan, 10)
    )
}

private func _parseEdgeLine(_ line: String, graph: inout _WorkingGraph, subgraphStack: inout [ParsedSubgraph]) throws {
    guard let firstGroup = try _consumeNodeGroup(line, graph: &graph, subgraphStack: &subgraphStack) else {
        if _regexMatch(_flowchartLinkStartRegex, line) != nil {
            throw _ParserEntryError.invalidFlowchartLink(line)
        }
        return
    }

    var remaining = firstGroup.remaining
    var prevGroupIds = firstGroup.ids

    while let link = try _consumeFlowchartLink(remaining) {
        guard let nextGroup = try _consumeNodeGroup(link.remaining, graph: &graph, subgraphStack: &subgraphStack) else {
            throw _ParserEntryError.invalidFlowchartLink(line)
        }

        for sourceId in prevGroupIds {
            for targetId in nextGroup.ids {
                graph.edges.append(
                    ParsedEdge(
                        source: sourceId,
                        target: targetId,
                        label: link.label,
                        style: link.style,
                        hasArrowStart: link.hasArrowStart,
                        hasArrowEnd: link.hasArrowEnd,
                        minimumRankSpan: link.minimumRankSpan
                    )
                )
            }
        }

        prevGroupIds = nextGroup.ids
        remaining = nextGroup.remaining
    }
}

private func _consumeNodeGroup(_ text: String, graph: inout _WorkingGraph, subgraphStack: inout [ParsedSubgraph]) throws -> _ConsumedNodeGroup? {
    guard let first = _consumeNode(text, graph: &graph, subgraphStack: &subgraphStack) else {
        return nil
    }

    var ids: [String] = [first.id]
    var remaining = first.remaining.trimmingCharacters(in: .whitespacesAndNewlines)

    while remaining.hasPrefix("&") {
        remaining = String(remaining.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let next = _consumeNode(remaining, graph: &graph, subgraphStack: &subgraphStack) else {
            throw _ParserEntryError.invalidFlowchartLink(text)
        }
        ids.append(next.id)
        remaining = next.remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return _ConsumedNodeGroup(ids: ids, remaining: remaining)
}

private func _consumeNode(_ text: String, graph: inout _WorkingGraph, subgraphStack: inout [ParsedSubgraph]) -> _ConsumedNode? {
    guard let nodeId = _regexMatch(_bareNodeRegex, text)?[safe: 1] else {
        return nil
    }
    var remaining = String(text.dropFirst(nodeId.count))
    var hasExplicitShape = false

    for pattern in _nodePatterns {
        guard let match = _regexMatch(pattern.regex, text),
              let full = match[safe: 0],
              match[safe: 1] == nodeId,
              let rawLabel = match[safe: 2]
        else {
            continue
        }

        let label = original_src_multiline_utils.normalizeBrTags(rawLabel)
        _registerNode(&graph, &subgraphStack, ParsedNode(id: nodeId, label: label, shape: pattern.shape))
        remaining = String(text.dropFirst(full.count))
        hasExplicitShape = true
        break
    }

    if !hasExplicitShape && graph.nodesById[nodeId] == nil && !graph.subgraphIds.contains(nodeId) {
        _registerNode(&graph, &subgraphStack, ParsedNode(id: nodeId, label: nodeId, shape: .rectangle))
    }

    if let classMatch = _regexMatch(_classShorthandRegex, remaining),
       let full = classMatch[safe: 0],
       let className = classMatch[safe: 1]
    {
        graph.classAssignments[nodeId] = className
        remaining = String(remaining.dropFirst(full.count))
    }

    return _ConsumedNode(id: nodeId, remaining: remaining)
}

private func _registerNode(_ graph: inout _WorkingGraph, _ subgraphStack: inout [ParsedSubgraph], _ node: ParsedNode) {
    let isNew = graph.nodesById[node.id] == nil
    if isNew {
        graph.upsertNode(node)
    }
    _trackInSubgraph(&subgraphStack, node.id)
}

private func _trackInSubgraph(_ subgraphStack: inout [ParsedSubgraph], _ nodeId: String) {
    if !subgraphStack.isEmpty {
        let current = subgraphStack[subgraphStack.count - 1]
        if !current.nodeIds.contains(nodeId) {
            current.nodeIds.append(nodeId)
        }
    }
}

private func _parseDirection(_ token: String) -> ParsedDirection? {
    ParsedDirection(rawValue: token.uppercased())
}

private func _regexTest(_ pattern: String, _ input: String, caseInsensitive: Bool = false) -> Bool {
    _regexGroups(pattern, input, caseInsensitive: caseInsensitive) != nil
}

private func _regexGroups(_ pattern: String, _ input: String, caseInsensitive: Bool = false) -> [String]? {
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
          let match = regex.firstMatch(in: input, options: [], range: NSRange(input.startIndex..., in: input))
    else {
        return nil
    }

    var groups: [String] = []
    for i in 0..<match.numberOfRanges {
        let nsRange = match.range(at: i)
        if nsRange.location == NSNotFound {
            groups.append("")
            continue
        }
        if let range = Range(nsRange, in: input) {
            groups.append(String(input[range]))
        } else {
            groups.append("")
        }
    }
    return groups
}

private func _regexMatch(_ regex: NSRegularExpression, _ input: String) -> [String]? {
    guard let match = regex.firstMatch(in: input, options: [], range: NSRange(input.startIndex..., in: input)) else {
        return nil
    }

    var groups: [String] = []
    for i in 0..<match.numberOfRanges {
        let nsRange = match.range(at: i)
        if nsRange.location == NSNotFound {
            groups.append("")
            continue
        }
        if let range = Range(nsRange, in: input) {
            groups.append(String(input[range]))
        } else {
            groups.append("")
        }
    }
    return groups
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

open class original_src_parser {
    public init() {}

    // Marker to keep transpiled outputs linked to elk-swift runtime.
    public static let __elkVersion = ElkSwift.version

    // Export inventory from TypeScript source:
    // - export function parseMermaid
    public static func parseMermaid(_ text: String) throws -> MermaidGraph {
        try _parseMermaidEntry(text)
    }
}
