// Run with Node.js and an existing installation containing mermaid and jsdom.
// node Tests/Fixtures/check-long-flowchart-layouts.mjs /path/to/reference-install
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const install = process.argv[2];
assert(install, 'Supply a directory with mermaid and jsdom installed in node_modules');
const requireReference = createRequire(resolve(install, 'package.json'));
const { JSDOM } = requireReference('jsdom');
const dom = new JSDOM('');
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.CSSStyleSheet = dom.window.CSSStyleSheet;
globalThis.Element = dom.window.Element;
globalThis.getComputedStyle = dom.window.getComputedStyle;

// Supply deterministic text measurements in jsdom so Mermaid can lay out SVG.
dom.window.SVGElement.prototype.getBBox = function () {
  return {
    x: 0,
    y: 0,
    width: Number(this.getAttribute('width')) || this.textContent.length * 8 || 12,
    height: Number(this.getAttribute('height')) || 16,
  };
};
dom.window.SVGElement.prototype.getComputedTextLength = function () {
  return this.getBBox().width;
};

try {
  const { default: mermaid } = await import(pathToFileURL(requireReference.resolve('mermaid')));
  mermaid.initialize({ startOnLoad: false, htmlLabels: false, flowchart: { htmlLabels: false } });

  const fixtureURL = new URL('long-flowchart-layouts.json', import.meta.url);
  const fixtures = JSON.parse(await readFile(fixtureURL, 'utf8'));
  for (const [name, fixture] of Object.entries(fixtures)) {
    async function measure(variant) {
      const id = `${name}-${variant}`;
      const { svg } = await mermaid.render(id, fixture[variant]);
      const document = new dom.window.DOMParser().parseFromString(svg, 'image/svg+xml');
      const nodes = [...document.querySelectorAll('g.node')];
      function position(nodeId) {
        const node = nodes.find(({ id: nodeSvgId }) => nodeSvgId.startsWith(`${id}-flowchart-${nodeId}-`));
        assert(node, `${name} ${variant} contains ${nodeId}`);
        const [, x, y] = node.getAttribute('transform').match(/^translate\(([-\d.]+),\s*([-\d.]+)\)$/);
        return Number(fixture.axis === 'x' ? x : y);
      }
      assert.equal(document.querySelectorAll('path.flowchart-link').length, fixture.edgeCount);
      return position(fixture.target) - position(fixture.source);
    }
    const standard = await measure('standard');
    const extended = await measure('extended');
    assert(standard > 0 && extended > standard, `${name} increases endpoint separation`);
    console.log(`PASS ${name}: ${standard} → ${extended}`);
  }
} finally {
  dom.window.close();
}
