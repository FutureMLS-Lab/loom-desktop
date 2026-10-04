(() => {
  const results = [];
  const assert = (condition, description) => {
    if (!condition) throw new Error(description);
    results.push(description);
  };
  const md = '# Plan / 项目计划\nIntro\n\n## Research\nFirst chapter\n\n### Evidence\nNeedle inside a folded child.\n\n###### Detail\nDeep detail\n\n## Delivery\nSecond chapter\n\n### Evidence\nOther evidence\n\n## Links and `code`\n[Example](https://example.com)\n\n```md\n# Not a heading\n```';
  const heading = (title) => Array.from(document.querySelectorAll('.loom-section')).find(s => s.dataset.title === title);
  const click = (title, altKey = false) => heading(title).firstElementChild.querySelector('button').dispatchEvent(new MouseEvent('click', { bubbles: true, altKey }));
  const isClosed = title => heading(title).lastElementChild.hidden;
  window.__loomRender(md, true, 'test/plan', []);
  assert(sections.length === 7, 'Six heading levels work; fenced code is not a section');
  assert(heading('Research').contains(heading('Detail')), 'Skipped heading levels retain nesting');
  assert(new Set(sections.map(s => s.dataset.foldKey)).size === 7, 'Repeated heading names have distinct paths');
  click('Evidence');
  click('Research');
  assert(isClosed('Research') && !isClosed('Delivery'), 'Folding stops at the next sibling heading');
  click('Research');
  assert(isClosed('Evidence'), 'Expanding a parent preserves its child fold');
  click('Research', true);
  assert(isClosed('Research') && isClosed('Detail'), 'Option-click includes descendant sections');
  window.__loomRender(md.replace('First chapter', 'Updated first chapter'), false, 'test/plan', []);
  assert(isClosed('Research') && isClosed('Detail'), 'Refreshing the same document retains folds');
  window.__loomFindQuery('Needle');
  assert(findHits.length === 1 && !isClosed('Research') && !isClosed('Evidence'), 'Find reveals a match inside folded ancestors');
  click('Delivery');
  window.__loomFindHide();
  assert(isClosed('Delivery') && !document.querySelector('mark.loom-hit'), 'Closing find retains manual folds and removes marks');
  assert(document.querySelector('#content a').getAttribute('href') === 'https://example.com', 'Links remain intact through folding and find');
  document.getElementById('fold-all').click();
  assert(!isClosed('Plan / 项目计划') && isClosed('Research') && isClosed('Delivery'), 'Collapse all leaves chapter headings discoverable');
  document.getElementById('unfold-all').click();
  assert(sections.every(s => !s.lastElementChild.hidden), 'Expand all restores every section');
  const saved = [heading('Delivery').dataset.foldKey];
  window.__loomRender(md, true, 'test/other', []);
  assert(!isClosed('Delivery'), 'A different document has independent fold state');
  window.__loomRender(md, true, 'test/plan', saved);
  assert(isClosed('Delivery'), 'Reopening a document restores saved fold state');
  window.__loomRender('', false, 'test/plan', []);
  assert(document.getElementById('reading-tools').hidden && findHits.length === 0, 'Empty documents clear search and section controls');
  const large = '# Long plan\n' + Array.from({ length: 160 }, (_, i) => `\n## Chapter ${i}\n${'Readable content with 中文 and a little detail. '.repeat(30)}\n### Notes ${i}\n- Item\n- Item\n`).join('');
  const start = performance.now();
  window.__loomRender(large, true, 'test/large', []);
  const renderMs = performance.now() - start;
  const foldStart = performance.now();
  document.getElementById('fold-all').click();
  const foldMs = performance.now() - foldStart;
  assert(sections.length === 321 && !sections[0].lastElementChild.hidden, 'Large plans fold without losing their outline');
  window.__loomAssetScope('p1', 'task-a', 'work/repo/docs');
  window.__loomRender('# Figures\n![a](img/a.png)\n\n![b](../b.png)\n\n![c](/abs/c.png)\n\n![d](<图 1.png>)\n\n![e](https://example.com/e.png)\n\n<img src="./f.png?raw=1">', true, 'test/figures', []);
  const figures = Array.from(document.querySelectorAll('#content img'));
  const figurePath = img => img.hasAttribute('data-loom-key') ? JSON.parse(img.getAttribute('data-loom-key'))[2] : null;
  assert(JSON.stringify(figures.map(figurePath)) === JSON.stringify(['work/repo/docs/img/a.png', 'work/repo/b.png', '/abs/c.png', 'work/repo/docs/图 1.png', null, 'work/repo/docs/f.png']), 'Figure paths resolve from the document folder, percent-decoded');
  assert(figures[4].getAttribute('src') === 'https://example.com/e.png', 'Remote images are left alone');
  const firstFetch = figures[0].getAttribute('src');
  assert(firstFetch.indexOf('loom-asset://figure?path=' + encodeURIComponent('work/repo/docs/img/a.png') + '&project=p1&task=task-a&v=') === 0, 'Figures are fetched through the asset scheme, versioned');
  window.__loomRender('# Figures\n![a](img/a.png)', false, 'test/figures', []);
  assert(document.querySelector('#content img').getAttribute('src') !== firstFetch, 'A re-render asks for a figure again instead of reusing a URL WebKit has cached');
  window.__loomRender([
    '# Untrusted',
    '<img src="x.png" onerror="window.__loomXSS = 1">',
    '<script>window.__loomXSS = 2</script>',
    '[click](javascript:window.__loomXSS=3)',
    '<img src="loom-asset://figure?path=../../secret&project=p1">',
    '<details><summary>More</summary>Kept</details>'
  ].join('\n\n'), true, 'test/untrusted', []);
  const untrusted = document.getElementById('content');
  assert(window.__loomXSS === undefined && !untrusted.querySelector('script, [onerror]'), 'HTML in a document cannot run script');
  assert(!Array.from(untrusted.querySelectorAll('a')).some(a => /^\s*javascript:/i.test(a.getAttribute('href') || '')), 'javascript: links are dropped');
  assert(!Array.from(untrusted.querySelectorAll('img')).some(img => (img.getAttribute('src') || '').indexOf('secret') !== -1), 'A document cannot aim the asset scheme at a path of its own');
  assert(untrusted.querySelector('details summary') && untrusted.textContent.indexOf('Kept') !== -1, 'Harmless HTML still renders');
  window.__loomAssetScope('', '', '');
  window.__loomRender(md, true, 'test/preview', []);
  document.getElementById('fold-all').click();
  click('Research');
  return { passed: results.length, results, largePlan: { characters: large.length, headings: 321, renderMs, foldMs } };
})();
