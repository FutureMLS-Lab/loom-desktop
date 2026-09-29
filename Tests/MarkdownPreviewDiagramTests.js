// The body of an async function, run after the synchronous suite: diagrams
// are drawn once the page has fetched the renderer, so these have to wait.
const results = [];
const assert = (condition, description) => {
  if (!condition) throw new Error(description);
  results.push(description);
};
const settled = async (predicate, ms = 20000) => {
  const start = performance.now();
  while (!predicate()) {
    if (performance.now() - start > ms) return false;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  return true;
};
const drawable = '```mermaid\nflowchart LR\n  A["Plan<br/><b>S1</b> bold"] --> B[Run]\n```';
const broken = '```mermaid\nflowchart LR\n  A[never closed\n```';
const doc = `# Diagrams\n\n${drawable}\n\n<details>\n<summary>More</summary>\n\n${broken}\n\n</details>\n`;
window.__loomRender(doc, true, 'test/diagrams', []);
assert(document.querySelectorAll('#content .loom-diagram').length === 2 && !document.querySelector('#content code.language-mermaid'), 'Mermaid blocks wait as diagrams, not as code');
assert(await settled(() => document.querySelector('#content .loom-diagram svg') && document.querySelector('#content .diagram-error')), 'A diagram is drawn, and a broken one settles too');
const svg = document.querySelector('#content .loom-diagram svg');
assert(!/%/.test(svg.getAttribute('width') || '%'), 'Drawn at its own size, not squeezed to the column');
assert(/S1/.test(svg.textContent) && /bold/.test(svg.textContent) && !/<b>|<br/.test(svg.textContent), 'Label markup is applied, not printed');
assert(document.querySelector('#content details pre > code.language-mermaid') && /Diagram not drawn/.test(document.querySelector('#content .diagram-error').textContent), 'A diagram that will not parse shows its source and says why');
window.__loomRender(doc + '\nMore text.', false, 'test/diagrams', []);
const first = document.querySelector('#content .loom-diagram');
assert(first.querySelector('svg') && !first.classList.contains('drawing'), 'An unchanged diagram is back at once after a re-render');
window.__loomFindQuery('Plan');
assert(!document.querySelector('#content .loom-diagram mark'), 'Find leaves drawings alone');
window.__loomFindHide();
return { passed: results.length, results };
