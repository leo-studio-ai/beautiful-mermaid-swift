// Run with Node.js and an existing installation containing mermaid and jsdom.
// node Tests/Fixtures/check-compact-flowchart-edges.mjs /path/to/reference-install
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

try {
  const { default: mermaid } = await import(pathToFileURL(requireReference.resolve('mermaid')));
  mermaid.initialize({ startOnLoad: false });

  const fixtureURL = new URL('compact-flowchart-edges.json', import.meta.url);
  const fixtures = JSON.parse(await readFile(fixtureURL, 'utf8'));
  const shapes = { square: 'rectangle', odd: 'asymmetric' };
  console.log(`Mermaid ${requireReference('mermaid/package.json').version}`);

  for (const fixture of fixtures) {
    if (fixture.rejected) {
      await assert.rejects(() => mermaid.mermaidAPI.getDiagramFromText(fixture.source), /Parse error|Lexical error/);
      console.log(`PASS ${fixture.name}`);
      continue;
    }
    const { db } = await mermaid.mermaidAPI.getDiagramFromText(fixture.source);
    const nodes = [...db.getVertices()].map(([id, vertex]) => ({
      id,
      label: vertex.text,
      shape: shapes[vertex.type] ?? vertex.type ?? 'rectangle',
    }));
    const edges = db.getEdges().map(edge => ({
      source: edge.start,
      target: edge.end,
      label: edge.text,
      style: edge.stroke === 'normal' ? 'solid' : edge.stroke,
      arrowStart: edge.type === 'double_arrow_point',
      arrowEnd: edge.type === 'arrow_point' || edge.type === 'double_arrow_point',
      minimumRankSpan: edge.length,
    }));
    assert.deepEqual(nodes, fixture.nodes, `${fixture.name} nodes`);
    assert.deepEqual(edges, fixture.edges, `${fixture.name} edges`);
    console.log(`PASS ${fixture.name}`);
  }
} finally {
  dom.window.close();
}
