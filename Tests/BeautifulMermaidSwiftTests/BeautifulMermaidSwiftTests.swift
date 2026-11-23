import XCTest
@testable import BeautifulMermaid

final class BeautifulMermaidSwiftTests: XCTestCase {
    func testVersionIsNonEmpty() {
        XCTAssertFalse(MermaidRenderer.version.isEmpty)
    }

    func testFlowSvgContainsNodes() throws {
        let svg = try renderMermaidSVG(
            """
            graph TD
              A[Start] --> B[End]
            """,
            RenderOptions()
        )
        XCTAssertTrue(svg.contains("class=\"node\""), "Expected flow SVG to include rendered nodes")
    }

    func testRenderImageForSimpleFlowIsNonNil() throws {
        let image = try MermaidRenderer.renderImage(
            source: """
            graph TD
              A[Start] --> B[End]
            """
        )
        XCTAssertNotNil(image, "Expected MermaidRenderer.renderImage to return a rasterizable image")
    }

    /// Reproduces crash in flow-15 (subgraph with direction override).
    func testFlow15SubgraphDirectionCrash() throws {
        let source = """
        graph TD
          subgraph pipeline [Processing Pipeline]
            direction LR
            A[Input] --> B[Parse] --> C[Transform] --> D[Output]
          end
          E[Source] --> A
          D --> F[Sink]
        """
        let svg = try renderMermaidSVG(source, RenderOptions())
        XCTAssertFalse(svg.isEmpty)
    }

    /// Reproduces LongEdgeJoiner crash on state-2-composite.
    func testState2CompositeCrash() throws {
        let source = """
        stateDiagram-v2
          [*] --> Idle
          Idle --> Processing : submit
          state Processing {
            parse --> validate
            validate --> execute
          }
          Processing --> Complete : done
          Processing --> Error : fail
          Error --> Idle : retry
          Complete --> [*]
        """
        let svg = try renderMermaidSVG(source, RenderOptions())
        XCTAssertFalse(svg.isEmpty)
    }

    func testFlow6EdgeStyles() throws {
        let source = "graph TD\n  A[Source] -->|solid| B[Target 1]\n  A -.->|dotted| C[Target 2]\n  A ==>|thick| D[Target 3]"
        let svg = try renderMermaidSVG(source, RenderOptions())
        XCTAssertFalse(svg.isEmpty)
    }

    func testFlow8BidirectionalEdgeLabels() throws {
        let source = "graph LR\n  A[Client] <-->|sync| B[Server]\n  B <-.->|heartbeat| C[Monitor]\n  C <==>|data| D[Storage]"
        let svg = try renderMermaidSVG(source, RenderOptions())
        XCTAssertFalse(svg.isEmpty)
    }

    func testUnspacedArrowsPreserveNodeIDsAndEdges() throws {
        let graph = try MermaidRenderer.layout("graph TD; Sidebar-->Panel; Panel-->Surface;")
        XCTAssertEqual(Set(graph.flowchartNodes!.map(\.id)), Set(["Sidebar", "Panel", "Surface"]))
        XCTAssertEqual(graph.flowchartEdges!.map { "\($0.source)->\($0.target)" }, ["Sidebar->Panel", "Panel->Surface"])
    }

    func testUnspacedFlowchartEdgesAgainstMermaidFixtures() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/compact-flowchart-edges.json")
        let fixtures = try JSONDecoder().decode([FlowchartFixture].self, from: Data(contentsOf: fixtureURL))
        for fixture in fixtures {
            if fixture.rejected == true {
                XCTAssertThrowsError(try MermaidRenderer.parse(fixture.source), fixture.name)
                continue
            }
            let graph = try MermaidRenderer.parse(fixture.source)
            guard case .flowchart(let flowchart) = graph.typedPayload else {
                XCTFail("Expected a flowchart for \(fixture.name)")
                continue
            }
            let nodes = flowchart.nodesInOrder.map { entry in
                FlowchartFixture.Node(id: entry.id, label: entry.node.label, shape: entry.node.shape.rawValue)
            }
            let edges = flowchart.edges.map { edge in
                FlowchartFixture.Edge(
                    source: edge.source,
                    target: edge.target,
                    label: edge.label ?? "",
                    style: edge.style.rawValue,
                    arrowStart: edge.hasArrowStart,
                    arrowEnd: edge.hasArrowEnd,
                    minimumRankSpan: edge.minimumRankSpan
                )
            }
            XCTAssertEqual(nodes, try XCTUnwrap(fixture.nodes), fixture.name)
            XCTAssertEqual(edges, try XCTUnwrap(fixture.edges), fixture.name)
        }
    }

    func testUnspacedFlowchartEdgesRejectUnsupportedMarkers() {
        XCTAssertThrowsError(try MermaidRenderer.parse("graph LR; A---oB;"))
        XCTAssertThrowsError(try MermaidRenderer.parse("graph LR; A---xB;"))
        XCTAssertThrowsError(try MermaidRenderer.parse("graph LR; A~~~B;"))
    }

    func testLongLinkConstrainsLayoutAndPreservesVisibleEdge() throws {
        let (source, graph) = try measuredLongLayout("shortcut")
        let nodes = try XCTUnwrap(graph.flowchartNodes)
        let edges = try XCTUnwrap(graph.flowchartEdges)
        let a = try XCTUnwrap(nodes.first { $0.id == "A" })
        let c = try XCTUnwrap(nodes.first { $0.id == "C" })
        XCTAssertEqual(Set(nodes.map(\.id)), ["A", "B", "C", "D"])
        XCTAssertEqual(edges.count, 4)
        XCTAssertGreaterThan(c.x - a.x - a.width, 3 * 32)

        let shortcut = try XCTUnwrap(edges.first { $0.source == "A" && $0.target == "C" })
        XCTAssertEqual(shortcut.label, "shortcut")
        XCTAssertTrue(shortcut.hasArrowStart)
        XCTAssertTrue(shortcut.hasArrowEnd)
        XCTAssertNotNil(shortcut.labelPosition)
        XCTAssertEqual(try XCTUnwrap(shortcut.points.first).x, a.x + a.width, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(shortcut.points.last).x, c.x, accuracy: 1)

        let svg = try MermaidRenderer.renderSVG(source: source)
        XCTAssertTrue(svg.contains("data-from=\"A\" data-to=\"C\""))
        XCTAssertTrue(svg.contains("data-label=\"shortcut\""))
        XCTAssertTrue(svg.contains("marker-start=\"url(#arrowhead-start)\""))
        XCTAssertFalse(svg.contains("_mermaid_rank_"))
    }

    func testLongLinkInCycleKeepsFeedbackRoute() throws {
        let (_, graph) = try measuredLongLayout("cycle")
        let nodes = try XCTUnwrap(graph.flowchartNodes)
        let edges = try XCTUnwrap(graph.flowchartEdges)
        let a = try XCTUnwrap(nodes.first { $0.id == "A" })
        let b = try XCTUnwrap(nodes.first { $0.id == "B" })
        let c = try XCTUnwrap(nodes.first { $0.id == "C" })
        XCTAssertEqual(edges.count, 3)
        XCTAssertGreaterThan(b.y - a.y - a.height, 3 * 32)
        let feedback = try XCTUnwrap(edges.first { $0.source == "C" && $0.target == "A" })
        XCTAssertEqual(feedback.label, "feedback")
        XCTAssertTrue(feedback.hasArrowEnd)
        let start = try XCTUnwrap(feedback.points.first)
        let end = try XCTUnwrap(feedback.points.last)
        XCTAssertGreaterThanOrEqual(start.y, c.y - 1)
        XCTAssertLessThanOrEqual(end.y, a.y + a.height + 1)
    }

    func testLongLinkInsideSubgraphHonorsLocalDirection() throws {
        let (_, graph) = try measuredLongLayout("localDirection")
        let nodes = try XCTUnwrap(graph.flowchartNodes)
        let edges = try XCTUnwrap(graph.flowchartEdges)
        let groups = try XCTUnwrap(graph.flowchartGroups)
        let a = try XCTUnwrap(nodes.first { $0.id == "A" })
        let b = try XCTUnwrap(nodes.first { $0.id == "B" })
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(groups.map(\.id), ["Local"])
        XCTAssertGreaterThan(b.x - a.x - a.width, 3 * 32)
        XCTAssertEqual(edges.first?.style, "dotted")
    }

    func testLongLinkAcrossSubgraphsKeepsBoundaryRoutes() throws {
        for override in ["", "direction LR\n"] {
            let source = """
            graph TD
            subgraph One
              \(override)A
            end
            subgraph Two
              \(override)B
            end
            A---->|cross|B
            """
            let graph = try MermaidRenderer.layout(source)
            let groups = try XCTUnwrap(graph.flowchartGroups)
            let nodes = try XCTUnwrap(graph.flowchartNodes)
            let edges = try XCTUnwrap(graph.flowchartEdges)
            XCTAssertEqual(Set(groups.map(\.id)), ["One", "Two"])
            XCTAssertEqual(Set(nodes.map(\.id)), ["A", "B"])
            XCTAssertEqual(edges.count, 1)
            let a = try XCTUnwrap(nodes.first { $0.id == "A" })
            let b = try XCTUnwrap(nodes.first { $0.id == "B" })
            XCTAssertGreaterThan(b.y - a.y - a.height, 3 * 32)
            let edge = try XCTUnwrap(edges.first)
            XCTAssertEqual(edge.label, "cross")
            XCTAssertNotNil(edge.labelPosition)
            XCTAssertGreaterThan(edge.points.count, 2)
            for (point, node) in [(try XCTUnwrap(edge.points.first), a), (try XCTUnwrap(edge.points.last), b)] {
                XCTAssertGreaterThanOrEqual(point.x, node.x - 1)
                XCTAssertLessThanOrEqual(point.x, node.x + node.width + 1)
                XCTAssertGreaterThanOrEqual(point.y, node.y - 1)
                XCTAssertLessThanOrEqual(point.y, node.y + node.height + 1)
            }
        }
    }

    private struct LongLayoutFixture: Decodable {
        let standard: String
        let extended: String
        let source: String
        let target: String
        let axis: String
        let edgeCount: Int
    }

    private func measuredLongLayout(_ name: String) throws -> (String, PositionedGraph) {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/long-flowchart-layouts.json")
        let fixtures = try JSONDecoder().decode([String: LongLayoutFixture].self, from: Data(contentsOf: file))
        let fixture = try XCTUnwrap(fixtures[name])
        let standard = try MermaidRenderer.layout(fixture.standard)
        let extended = try MermaidRenderer.layout(fixture.extended)

        func measure(_ layout: PositionedGraph) throws -> Double {
            let nodes = try XCTUnwrap(layout.flowchartNodes)
            let source = try XCTUnwrap(nodes.first { $0.id == fixture.source })
            let target = try XCTUnwrap(nodes.first { $0.id == fixture.target })
            XCTAssertEqual(layout.flowchartEdges?.count, fixture.edgeCount, name)
            return fixture.axis == "x" ? target.x - source.x : target.y - source.y
        }

        let baseline = try measure(standard)
        let separation = try measure(extended)
        XCTAssertGreaterThan(baseline, 0, name)
        XCTAssertGreaterThan(separation, baseline, name)
        return (fixture.extended, extended)
    }

    private struct FlowchartFixture: Decodable {
        struct Node: Decodable, Equatable {
            let id: String
            let label: String
            let shape: String
        }

        struct Edge: Decodable, Equatable {
            let source: String
            let target: String
            let label: String
            let style: String
            let arrowStart: Bool
            let arrowEnd: Bool
            let minimumRankSpan: Int
        }

        let name: String
        let source: String
        let nodes: [Node]?
        let edges: [Edge]?
        let rejected: Bool?
    }

    func testSimpleTDNodeOrder() throws {
        let source = "graph TD\n  A[Start] --> B[End]"
        let pos = try MermaidRenderer.layout(source)
        let nodes = pos.flowchartNodes!
        let nodeA = nodes.first { $0.id == "A" }!
        let nodeB = nodes.first { $0.id == "B" }!
        XCTAssertLessThan(nodeA.y, nodeB.y, "In graph TD, source A should be above target B (lower y)")
    }

    func testSimpleBTNodeOrder() throws {
        let source = "graph BT\n  A[Foundation] --> B[Layer 2] --> C[Top]"
        let pos = try MermaidRenderer.layout(source)
        let nodes = pos.flowchartNodes!
        let nodeA = nodes.first { $0.id == "A" }!
        let nodeC = nodes.first { $0.id == "C" }!
        XCTAssertGreaterThan(nodeA.y, nodeC.y, "In graph BT, source A should be below target C (higher y)")
    }

    func testFlow14NestedSubgraphDebug() throws {
        let source = """
        graph TD
          subgraph Cloud
            subgraph us-east [US East Region]
              A[Web Server] --> B[App Server]
            end
            subgraph us-west [US West Region]
              C[Web Server] --> D[App Server]
            end
          end
          E[Load Balancer] --> A
          E --> C
        """
        let pos = try MermaidRenderer.layout(source)
        let nodes = pos.flowchartNodes!
        let edges = pos.flowchartEdges!
        let groups = pos.flowchartGroups!
        print("=== FLOW-14 DEBUG ===")
        print("  graphSize: \(pos.width) x \(pos.height)")
        for n in nodes { print("  Node \(n.id)(\(n.label)): x=\(n.x) y=\(n.y) w=\(n.width) h=\(n.height)") }
        for e in edges { print("  Edge \(e.source)->\(e.target) pts=\(e.points.map { "(\(Int($0.x)),\(Int($0.y)))" })") }
        func printGroups(_ gs: [_PositionedGroupPayload], indent: String = "  ") {
            for g in gs {
                print("\(indent)Group \(g.id)(\(g.label)): x=\(g.x) y=\(g.y) w=\(g.width) h=\(g.height)")
                printGroups(g.children, indent: indent + "  ")
            }
        }
        printGroups(groups)
    }

    func testFlow6PortOrderDebug() throws {
        // Test as graph TD (has GraphTransformer rotation)
        let sourceTD = "graph TD\n  A[Source] -->|solid| B[Target 1]\n  A -.->|dotted| C[Target 2]\n  A ==>|thick| D[Target 3]"
        let posTD = try MermaidRenderer.layout(sourceTD)
        let nodesTD = posTD.flowchartNodes!
        let edgesTD = posTD.flowchartEdges!
        print("=== FLOW-6 TD ===")
        for n in nodesTD { print("  Node \(n.label): x=\(n.x) y=\(n.y) w=\(n.width) h=\(n.height)") }
        for e in edgesTD {
            let lp = e.labelPosition.map { "(\($0.x),\($0.y))" } ?? "nil"
            print("  Edge \(e.source)->\(e.target) label=\(e.label ?? "nil") labelPos=\(lp) pts=\(e.points.map { "(\(Int($0.x)),\(Int($0.y)))" })")
        }

        // Test as graph LR (no rotation)
        let sourceLR = "graph LR\n  A[Source] -->|solid| B[Target 1]\n  A -.->|dotted| C[Target 2]\n  A ==>|thick| D[Target 3]"
        let posLR = try MermaidRenderer.layout(sourceLR)
        let nodesLR = posLR.flowchartNodes!
        let edgesLR = posLR.flowchartEdges!
        print("=== FLOW-6 LR ===")
        for n in nodesLR { print("  Node \(n.label): x=\(n.x) y=\(n.y)") }
        for e in edgesLR {
            let lp = e.labelPosition.map { "(\($0.x),\($0.y))" } ?? "nil"
            print("  Edge \(e.source)->\(e.target) label=\(e.label ?? "nil") labelPos=\(lp) pts=\(e.points.map { "(\(Int($0.x)),\(Int($0.y)))" })")
        }
    }
}
