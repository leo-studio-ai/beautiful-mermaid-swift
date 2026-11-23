import Foundation
import CoreGraphics
#if targetEnvironment(macCatalyst)
import UIKit
#elseif canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

func _hex(_ color: BMColor) -> String? {
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
    #elseif canImport(AppKit)
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
    #else
    return nil
    #endif

    let ri = Int(max(0, min(255, (r * 255).rounded())))
    let gi = Int(max(0, min(255, (g * 255).rounded())))
    let bi = Int(max(0, min(255, (b * 255).rounded())))
    return String(format: "#%02X%02X%02X", ri, gi, bi)
}

func _flattenKnownSvgTokens(_ svg: String, theme: DiagramTheme) -> String {
    let bg = _hex(theme.background) ?? "#FFFFFF"
    let fg = _hex(theme.foreground) ?? "#27272A"
    let line = _hex(theme.effectiveLine()) ?? fg
    let muted = _hex(theme.effectiveMuted()) ?? line
    let surface = _hex(theme.effectiveSurface()) ?? bg
    let border = _hex(theme.effectiveBorder()) ?? line

    let replacements: [(token: String, value: String)] = [
        ("_line", line),
        ("_arrow", line),
        ("_node-fill", surface),
        ("_node-stroke", border),
        ("_group-fill", surface),
        ("_group-hdr", surface),
        ("_inner-stroke", border),
        ("_text", fg),
        ("_text-sec", muted),
        ("_text-muted", muted),
        ("_state-end-outer", fg),
        ("_state-end-inner", bg),
    ]

    var out = svg
    for item in replacements {
        let pattern = #"var\(\s*--\#(item.token)\s*(?:,\s*[^)]*)?\)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(location: 0, length: (out as NSString).length)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: item.value)
        }
    }
    return out
}

func _resolveSvgCssVariables(_ svg: String) -> String {
    let ns = svg as NSString
    let pattern = "--([a-zA-Z0-9_-]+)\\s*:\\s*([^;\\\"]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return svg
    }

    let matches = regex.matches(in: svg, range: NSRange(location: 0, length: ns.length))
    if matches.isEmpty { return svg }

    var vars: [String: String] = [:]
    for m in matches where m.numberOfRanges >= 3 {
        let name = ns.substring(with: m.range(at: 1))
        let value = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        vars[name] = value
    }

    // Replaces each `var(--name[, fallback])`, matching parentheses so a fallback
    // may itself contain `color-mix(...)` or `var(...)`. A defined variable wins over
    // its fallback; one with neither is left in place for the cleanup passes below.
    func resolveVars(in input: String, depth: Int = 0) -> String {
        guard depth < 16 else { return input }
        var out = ""
        var rest = Substring(input)
        while let open = rest.range(of: "var(") {
            out += rest[..<open.lowerBound]
            var level = 1
            var comma: Substring.Index?
            var close = open.upperBound
            while close < rest.endIndex {
                let c = rest[close]
                if c == "(" {
                    level += 1
                } else if c == ")" {
                    level -= 1
                    if level == 0 { break }
                } else if c == ",", level == 1, comma == nil {
                    comma = close
                }
                close = rest.index(after: close)
            }
            guard close < rest.endIndex else {
                out += rest[open.lowerBound...]
                return out
            }
            let name = rest[open.upperBound..<(comma ?? close)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.hasPrefix("--") ? String(name.dropFirst(2)) : name
            let fallback = comma.map {
                rest[rest.index(after: $0)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value = vars[key] ?? fallback, !value.isEmpty {
                out += resolveVars(in: value, depth: depth + 1)
            } else {
                out += rest[open.lowerBound...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    // First resolve variable definitions themselves.
    for _ in 0..<8 {
        var changed = false
        for (k, v) in vars {
            let rv = resolveVars(in: v)
            if rv != v {
                vars[k] = rv
                changed = true
            }
        }
        if !changed { break }
    }

    var out = resolveVars(in: svg)

    // AppKit/UIKit SVG rasterizers do not reliably support color-mix().
    // Replace remaining dynamic CSS with deterministic solid colors.
    let mixPattern = #"color-mix\([^)]+\)"#
    if let mixRegex = try? NSRegularExpression(pattern: mixPattern) {
        let nsOut = out as NSString
        let matches = mixRegex.matches(in: out, range: NSRange(location: 0, length: nsOut.length))
        for m in matches.reversed() {
            out = (out as NSString).replacingCharacters(in: m.range, with: "#666666")
        }
    }

    let unresolvedVarPattern = #"var\([^)]+\)"#
    if let unresolvedVarRegex = try? NSRegularExpression(pattern: unresolvedVarPattern) {
        let nsOut = out as NSString
        let matches = unresolvedVarRegex.matches(in: out, range: NSRange(location: 0, length: nsOut.length))
        for m in matches.reversed() {
            out = (out as NSString).replacingCharacters(in: m.range, with: "#666666")
        }
    }

    return out
}
