import XCTest
@testable import BeautifulMermaid

final class CssVariableResolutionTests: XCTestCase {
    func testDefinedVariableIgnoresNestedColorMixFallback() {
        let svg = """
        <svg style="--bg:#1A1B26;--fg:#A9B1D6;--line:#3D59A1"><style>
          svg { --_line: var(--line, color-mix(in srgb, var(--fg) 50%, var(--bg))); }
        </style><polyline stroke="var(--_line)" /></svg>
        """
        let out = _resolveSvgCssVariables(svg)
        XCTAssertTrue(out.contains("stroke=\"#3D59A1\""), out)
        XCTAssertFalse(out.contains("%, #"), out)
    }

    func testUndefinedVariableUsesWholeNestedFallback() {
        let svg = """
        <svg style="--bg:#1A1B26;--fg:#A9B1D6"><style>
          svg { --_line: var(--line, color-mix(in srgb, var(--fg) 50%, var(--bg))); }
        </style><polyline stroke="var(--_line)" /></svg>
        """
        let out = _resolveSvgCssVariables(svg)
        XCTAssertFalse(out.contains("%, #"), out)
        XCTAssertFalse(out.contains("var("), out)
    }

    func testRenderedFlowchartHasNoTruncatedColors() throws {
        let svg = try MermaidRenderer.renderSVG(source: "graph LR\n  A --> B", theme: .tokyoNight)
        XCTAssertNil(svg.range(of: #"%, #[0-9A-Fa-f]{6}\)"#, options: .regularExpression), svg)
    }
}
