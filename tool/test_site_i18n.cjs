// Run with: node --test tool/test_site_i18n.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../site/shared/idy.js'), 'utf8');
const targets = [
  { marker: 'data-i18n', property: 'textContent', authored: 'Readable English content' },
  { marker: 'data-i18n-html', property: 'innerHTML', authored: 'Flutter control.<br><a href="#architecture">Native packet path.</a>' },
  { marker: 'data-i18n-aria-label', attribute: 'aria-label', authored: 'Diagram legend' },
  { marker: 'data-i18n-title', attribute: 'title', authored: 'Architecture details' },
  { marker: 'data-i18n-alt', attribute: 'alt', authored: 'Packet flow diagram' },
];

function loadHelper(language, fetch) {
  const elements = targets.map(target => {
    const attributes = new Map([[target.marker, 'pageCopy']]);
    if (target.attribute) attributes.set(target.attribute, target.authored);
    return {
      attributes,
      dataset: { i18n: 'pageCopy', i18nHtml: 'pageCopy' },
      ...(target.property ? { [target.property]: target.authored } : {}),
      getAttribute: name => attributes.get(name) ?? null,
      setAttribute: (name, value) => attributes.set(name, String(value)),
    };
  });
  const documentListeners = new Map();
  const windowListeners = new Map();
  const document = {
    documentElement: { dataset: {}, style: {} },
    querySelector: () => null,
    querySelectorAll: selector => elements.filter(element => element.attributes.has(selector.slice(1, -1))),
    addEventListener: (name, callback) => documentListeners.set(name, callback),
    dispatchEvent: event => documentListeners.get(event.type)?.(event),
  };
  const window = {
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    addEventListener: (name, callback) => windowListeners.set(name, callback),
  };
  vm.runInNewContext(source, {
    document, window,
    navigator: { languages: [language] },
    localStorage: { getItem: () => null, setItem() {} },
    fetch, AbortController, setTimeout, clearTimeout,
    CustomEvent: class { constructor(type, options) { this.type = type; this.detail = options.detail; } },
  }, { filename: 'site/shared/idy.js' });
  return {
    site: window.IdySite,
    elements,
    ready: () => document.dispatchEvent({ type: 'DOMContentLoaded' }),
    setLanguage: value => windowListeners.get('storage')({ key: 'idy-language', newValue: value }),
    values: () => elements.map((element, index) => targets[index].property
      ? element[targets[index].property] : element.getAttribute(targets[index].attribute)),
  };
}

for (const language of ['en', 'zh']) {
  test(`${language}: absent page script preserves authored text, HTML and attributes`, () => {
    const page = loadHelper(language);
    page.ready(); // shared/idy.js runs without script.js ever registering page dictionaries.
    assert.deepEqual(page.values(), targets.map(target => target.authored));
    for (const nextLanguage of ['zh', 'en']) {
      page.setLanguage(nextLanguage);
      assert.deepEqual(page.values(), targets.map(target => target.authored));
      assert.equal(page.site.t('language'), nextLanguage === 'zh' ? '语言' : 'Language');
      assert.equal(page.site.t('pageCopy'), 'pageCopy', 't() still returns unknown keys');
    }
  });
}

for (const [name, en, zh, expected] of [
  ['localized strings', 'English', '中文', '中文'],
  ['English-only strings', 'English', undefined, 'English'],
  ['English strings with invalid localized values', 'English', 42, 'English'],
  ['localized strings with invalid English values', false, '中文', '中文'],
  ['empty localized strings', 'English', '', ''],
  ['empty English strings', '', undefined, ''],
]) {
  test(`${name} replace authored content`, () => {
    const page = loadHelper('zh');
    page.ready();
    page.site.init({ en: { pageCopy: en }, zh: { pageCopy: zh } });
    assert.deepEqual(page.values(), targets.map(() => expected));
  });
}

test('non-string dictionary entries leave authored content intact', () => {
  const page = loadHelper('zh');
  page.ready();
  page.site.init({ en: { pageCopy: 42 }, zh: { pageCopy: { text: 'not a string' } } });
  assert.deepEqual(page.values(), targets.map(target => target.authored));
  page.setLanguage('en');
  assert.deepEqual(page.values(), targets.map(target => target.authored));
});

test('missing translations do not create missing attributes', () => {
  const page = loadHelper('en');
  page.elements.forEach((element, index) => {
    if (targets[index].attribute) element.attributes.delete(targets[index].attribute);
  });
  page.ready();
  page.elements.forEach((element, index) => {
    if (targets[index].attribute) assert.equal(element.getAttribute(targets[index].attribute), null);
  });
});

test('a 404 latest release falls back to published preview releases', async () => {
  const requests = [];
  const preview = {
    tag_name: 'v0.3.0-preview', prerelease: true, draft: false, assets: [],
    published_at: '2026-01-01T00:00:00Z',
    html_url: 'https://github.com/idy/wgc-ne/releases/tag/v0.3.0-preview',
  };
  const page = loadHelper('en', async url => {
    requests.push(url);
    return url.endsWith('/latest')
      ? { status: 404, ok: false }
      : { status: 200, ok: true, json: async () => [preview] };
  });
  assert.equal((await page.site.loadRelease('idy/wgc-ne')).tag_name, preview.tag_name);
  assert.deepEqual(requests, [
    'https://api.github.com/repos/idy/wgc-ne/releases/latest',
    'https://api.github.com/repos/idy/wgc-ne/releases?per_page=100',
  ]);
});

function loadDiagram() {
  const listeners = new Map();
  const nodes = new Map();
  function element(dataset = {}) {
    const handlers = new Map();
    const attributes = new Map();
    return {
      dataset, textContent: '', hidden: true, disabled: true,
      classList: { add() {}, remove() {} },
      addEventListener(type, callback) { handlers.set(type, callback); },
      setAttribute(name, value) { attributes.set(name, String(value)); },
      getAttribute(name) { return attributes.get(name); },
      fire(type, event = {}) { return handlers.get(type)?.(event); },
    };
  }
  const stages = ['flutter', 'ne', 'singbox', 'wgc', 'transport'].map(stage => element({ stage }));
  const board = element({ transport: 'udp' });
  board.querySelectorAll = () => stages;
  nodes.set('runtime-board', board);
  const copy = element({ copy: 'transport-code' });
  const document = {
    getElementById(id) {
      if (!nodes.has(id)) nodes.set(id, element());
      return nodes.get(id);
    },
    querySelectorAll(selector) { return selector === '[data-copy]' ? [copy] : []; },
    querySelector() { return {}; },
    documentElement: { dataset: { theme: 'light' } },
    addEventListener(type, callback) { listeners.set(type, callback); },
  };
  let language = 'en';
  let dictionary;
  const site = {
    init(translations) { dictionary = translations; },
    t(key) { return dictionary[language][key] ?? dictionary.en[key] ?? key; },
    loadRelease: async () => { throw new Error('offline'); },
    asset() {},
  };
  const window = { IdySite: site, matchMedia: () => ({ matches: true }), setTimeout: () => 1, clearTimeout() {} };
  let copied;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../site/script.js'), 'utf8'), {
    document, window, IdySite: site,
    navigator: { clipboard: { writeText: async text => { copied = text; } } },
    MutationObserver: class { observe() {} },
  }, { filename: 'site/script.js' });
  return {
    board, stages, copy, nodes, get: id => document.getElementById(id), copied: () => copied,
    language(value) { language = value; listeners.get('idy:languagechange')(); },
  };
}

test('architecture stages, transport choice, translation and copy stay interactive', async () => {
  const page = loadDiagram();
  assert.ok(page.stages.every(stage => !stage.disabled));
  assert.equal(page.get('transport-choice').disabled, false);
  assert.equal(page.get('flow-next').hidden, false);
  page.get('flow-next').fire('click');
  assert.equal(page.get('flow-title').textContent, 'NetworkExtension owns the tunnel.');
  assert.equal(page.stages[1].getAttribute('aria-pressed'), 'true');
  page.get('transport-choice').fire('change', { target: { name: 'transport', value: 'custom', checked: true } });
  assert.equal(page.board.dataset.transport, 'custom');
  assert.equal(page.get('socket-config').textContent, '{"type":"your-registered-name","options":{}}');
  assert.equal(page.get('flow-title').textContent, 'Your wrapper lives in the native core.');
  page.language('zh');
  assert.equal(page.get('flow-title').textContent, '你的包装器运行在原生核心中。');
  page.get('transport-code').textContent = 'type Transport interface {}';
  await page.copy.fire('click');
  assert.equal(page.copied(), 'type Transport interface {}');
  assert.equal(page.get('copy-status').textContent, '已复制 Go 传输接口。');
  await new Promise(resolve => setImmediate(resolve));
  assert.match(page.get('release-status').textContent, /暂时无法获取版本信息/);
});

test('website architecture documentation link targets an existing document', () => {
  const html = fs.readFileSync(path.join(__dirname, '../site/index.html'), 'utf8');
  assert.match(html, /https:\/\/github\.com\/idy\/wgc-ne\/blob\/main\/docs\/architecture\.md/);
  assert.ok(fs.existsSync(path.join(__dirname, '../docs/architecture.md')));
});
