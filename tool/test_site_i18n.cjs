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

function loadHelper(language) {
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
