// The body of an async function, run after the diagram suite: formulas are
// typeset once the page has fetched KaTeX, so these have to wait.
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
const doc = [
  String.raw`# Decay by $\alpha$`,
  '',
  String.raw`A state $S \in \mathbb{R}^{K \times V}$ ($K = V = 128$) is updated by $\left(I - k_t k_t^\top\right)_{ij}$ and $(v_t)_{j}$, and \(x_i * y_j\) too.`,
  '',
  'It costs $5 and $10, `echo $HOME/$USER$` is code, an escaped \\$ stays a dollar sign, and \\[1\\] a citation.',
  '',
  String.raw`$$S_t = \left(I - \beta_t k_t k_t^\top\right) S_{t-1}, \qquad \alpha_{t,i} = \exp\!\left(-5\,\sigma(x)\right)$$`,
  '',
  String.raw`\[`,
  String.raw`\mathrm{SR}(x) = \begin{cases} \lceil x \rceil & p, \\ \lfloor x \rfloor & 1 - p \end{cases}`,
  String.raw`\]`,
  '',
  '```sh',
  'echo "$$"',
  '```',
  '',
  String.raw`Broken: $\frac{1}{$ is shown, not thrown.`,
  '',
  '$$',
  'a',
  '',
  'b $$',
].join('\n');
const content = document.getElementById('content');
const boxes = selector => content.querySelectorAll('.loom-math' + (selector || ''));
window.__loomRender(doc, true, 'test/math', []);
const foldKey = sections[0].dataset.foldKey;
assert(boxes().length === 9 && boxes('.display').length === 2, 'Formulas are lifted out of the text, in a line and set apart');
assert(!content.querySelector('em, strong'), 'An underscore after a bracket in a formula does not open italics');
assert(/It costs \$5 and \$10/.test(content.textContent) && content.querySelector('p code').textContent === 'echo $HOME/$USER$'
  && /escaped \$ stays/.test(content.textContent) && /\[1\] a citation/.test(content.textContent), 'Prices, code, an escaped $ and a citation stay text');
assert(/b \$\$/.test(content.textContent), 'A $$ does not reach past a blank line');
assert(boxes('.waiting').length === 9 && boxes()[0].textContent === String.raw`\alpha`, 'Until KaTeX arrives a formula shows its TeX');
assert(await settled(() => boxes('.typeset').length === 9), 'Every formula is typeset once KaTeX arrives');
assert(content.querySelectorAll('.katex').length === 8 && content.querySelectorAll('.loom-math .katex-error').length === 1, 'A formula KaTeX cannot read shows its source, and the rest still typeset');
const glued = boxes()[2];
assert(glued.firstChild.nodeValue === '(' && glued.lastChild.nodeValue === ')' && boxes()[4].lastChild.nodeValue === ','
  && getComputedStyle(glued).display === 'inline-block' && !boxes()[1].classList.contains('glued'), 'A formula keeps the punctuation touching it, so a line cannot break between them');
const cases = boxes('.display')[1];
assert(cases.querySelector('.katex-display .mtable') && !cases.querySelector('.katex-error'), 'A \\\\ inside an environment reaches KaTeX intact');
assert(await settled(() => Array.from(document.fonts).some(font => /KaTeX_Main/.test(font.family) && font.status === 'loaded')), "KaTeX's fonts arrive through the asset scheme");
window.__loomRender(doc + '\n\nMore.', false, 'test/math', []);
assert(boxes('.typeset').length === 9 && !boxes('.waiting').length, 'Once KaTeX is here, a re-render typesets at once');
assert(sections[0].dataset.foldKey === foldKey, "A heading's fold key does not change when its formula is typeset");
window.__loomFindQuery('alpha');
assert(!content.querySelector('.loom-math mark'), 'Find leaves formulas alone');
window.__loomFindQuery('Decay');
assert(findHits.length === 1, 'Text around a formula is still found');
window.__loomFindHide();
const paragraph = content.querySelector('p');
const range = document.createRange();
range.selectNodeContents(paragraph);
getSelection().removeAllRanges();
getSelection().addRange(range);
const clipboard = new DataTransfer();
paragraph.dispatchEvent(new ClipboardEvent('copy', { clipboardData: clipboard, bubbles: true, cancelable: true }));
getSelection().removeAllRanges();
const copied = clipboard.getData('text/plain');
assert(copied.includes(String.raw`$S \in \mathbb{R}^{K \times V}$ ($K = V = 128$) is`), 'Copying text with a formula copies its TeX');
window.__loomRender(String.raw`$\href{javascript:alert(1)}{x}$ and $<img src=x onerror=alert(2)>$ and <span class="loom-math">\url{javascript:alert(3)}</span>`, true, 'test/math-safety', []);
assert(boxes('.typeset').length === 3 && !content.querySelector('a, img'), 'A formula cannot make a link or an image, whatever it asks for');
return { passed: results.length, results };
