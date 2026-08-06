// The browser end-to-end suite.
//
// Everything here is something HTTP alone cannot answer. If an assertion could
// be made with curl it belongs in app/t/share.t instead, which is faster and
// runs in the image build. What is left is the part that needs a real engine:
//
//   * mermaid actually DRAWING an SVG, inside a sandboxed iframe, under a CSP
//     that names an explicit origin
//   * the drop zone accepting files and reporting progress
//   * navigator.clipboard receiving the URL
//   * localStorage surviving a reload
//   * the viewer's header/iframe split rendering as two panes
//   * the delete password never leaving the browser that uploaded the file
//
// It runs against a throwaway instance (see run.sh) — never production.

const { test, expect } = require('/usr/local/lib/node_modules/playwright/test');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'share-e2e-'));

function fixture(name, contents) {
  const file = path.join(tmp, name);
  fs.writeFileSync(file, contents);
  return file;
}

const MARKDOWN = `# End to end

Some **bold** text, a [link](https://example.com) and a table.

| what | value |
|------|-------|
| run  | browser |

\`\`\`mermaid
graph LR
  Agent -->|share| Human
\`\`\`

<script>window.__pwned = true;</script>
`;

// 1x1 transparent PNG.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64'
);

// {url, id, delete_password} for everything this run created. Deleting now needs
// the password, which only the uploading browser ever sees — so the teardown
// scrapes it out of localStorage rather than guessing.
const uploaded = [];

// Upload through the browser and return the share URL, which is how every test
// below gets something to look at.
async function uploadViaBrowser(page, file) {
  await page.goto('/');
  await page.setInputFiles('#upload-files', file);

  const row = page.locator('.uploader .results li').last();
  await expect(row.locator('.result-url')).toBeVisible();

  const url = await row.locator('.result-url').innerText();
  await trackAll(page);
  return url;
}

test.afterAll(async ({ request }) => {
  // Delete only what this run created, by id, with the password that came back
  // with it. Never a sweep — see the memory of what a sweep cost once.
  for (const rec of uploaded) {
    if (!rec.id || !rec.delete_password) continue;
    await request
      .delete(`/api/v1/files/${rec.id}`, { headers: { 'X-Delete-Password': rec.delete_password } })
      .catch(() => {});
  }
});

// Everything the browser knows about what it has uploaded, including the delete
// passwords it was handed once each.
async function history(page) {
  return page.evaluate(() => JSON.parse(window.localStorage.getItem('share.recent') || '[]'));
}

async function trackAll(page) {
  for (const rec of await history(page)) {
    if (!uploaded.some((u) => u.id === rec.id)) uploaded.push(rec);
  }
}

test('the home page is the uploader, open and ready', async ({ page }) => {
  await page.goto('/');

  await expect(page.locator('.topbar .brand')).toHaveText('share');
  await expect(page.locator('.topbar nav a').first()).toHaveText('How to use it');
  await expect(page.locator('.topbar nav a').nth(1)).toHaveText('API');
  await expect(page.locator('.topbar nav a.gh')).toHaveAttribute(
    'href', 'https://github.com/melo/small-share-app');

  // The wordmark is a logo, not a hyperlink: it must not turn blue or sprout an
  // underline just because it happens to be clickable.
  const brandStyle = await page.locator('.topbar .brand').evaluate((el) => {
    const s = getComputedStyle(el);
    return { decoration: s.textDecorationLine, size: parseFloat(s.fontSize) };
  });
  expect(brandStyle.decoration).toBe('none');
  expect(brandStyle.size).toBeGreaterThan(18);

  // Always open: the drop zone is visible with no click, and there is no
  // disclosure control to click in the first place.
  await expect(page.locator('.uploader .dropzone')).toBeVisible();
  await expect(page.locator('.uploader summary')).toHaveCount(0);

  // The pitch panel carries the one `claude mcp add` line deliberately — most
  // people arriving have no idea this is an MCP server — but the rules and the
  // REST tutorial stay one click away.
  await expect(page.locator('.pitch')).toBeVisible();
  await expect(page.locator('.pitch')).toContainText('claude mcp add');
  await expect(page.locator('body')).not.toContainText('curl --data-binary');

  await page.click('.topbar nav a >> nth=0');
  await expect(page).toHaveURL(/\/how-to$/);
  await expect(page.locator('body')).toContainText('claude mcp add --transport http share');
});

test('the pitch is dismissed by timestamp, and stays dismissed', async ({ page }) => {
  await page.goto('/');
  await page.evaluate(() => window.localStorage.removeItem('share.pitch-dismissed'));
  await page.reload();

  const pitch = page.locator('.pitch');
  await expect(pitch).toBeVisible();

  // The button ships hidden and is woken by the script, so a scripting-off
  // visitor gets the panel but no dead control.
  const dismiss = page.locator('.pitch-dismiss');
  await expect(dismiss).toBeVisible();
  await dismiss.click();
  await expect(pitch).toBeHidden();

  // What is stored is the MOMENT OF DISMISSAL, not the first visit — which is
  // what lets it come back after a long enough gap rather than never again.
  const at = await page.evaluate(() =>
    parseInt(window.localStorage.getItem('share.pitch-dismissed'), 10));
  expect(at).toBeGreaterThan(Date.now() - 60000);
  expect(at).toBeLessThanOrEqual(Date.now());

  await page.reload();
  await expect(pitch).toBeHidden();

  // Ninety days on, it is news again rather than nagging.
  await page.evaluate(() => window.localStorage.setItem('share.pitch-dismissed',
    String(Date.now() - 91 * 24 * 60 * 60 * 1000)));
  await page.reload();
  await expect(pitch).toBeVisible();

  await page.evaluate(() => window.localStorage.setItem('share.pitch-dismissed', String(Date.now())));
});

test('the header collapses to a burger on a phone, with no JavaScript', async ({ page }) => {
  await page.setViewportSize({ width: 380, height: 800 });
  await page.goto('/how-to');    // a page that grants no script source at all

  const nav = page.locator('.topbar nav');
  const burger = page.locator('.nav-burger');
  await expect(burger).toBeVisible();
  await expect(nav).toBeHidden();

  await burger.click();
  await expect(nav).toBeVisible();
  await expect(page.locator('.topbar nav a.gh')).toBeVisible();

  await burger.click();
  await expect(nav).toBeHidden();

  // Wide again: the links are inline and the burger is gone.
  await page.setViewportSize({ width: 1100, height: 800 });
  await expect(nav).toBeVisible();
  await expect(burger).toBeHidden();
});

test('drag-and-drop uploads, shows progress, and yields a copyable URL', async ({ page }) => {
  await page.goto('/');
  await page.setInputFiles('#upload-files', fixture('report.md', MARKDOWN));

  const row = page.locator('.uploader .results li').first();
  await expect(row.locator('.result-name')).toHaveText('report.md');
  await expect(row.locator('.result-meta')).toContainText('markdown');
  await expect(row.locator('.result-meta')).toContainText('expires in');

  const url = await row.locator('.result-url').innerText();
  await trackAll(page);
  expect(url).toMatch(/\/f\/[A-Za-z0-9]{32}$/);

  // The progress bar is removed once the upload lands — otherwise a finished
  // row would sit there looking like it is still going.
  await expect(row.locator('.result-bar')).toHaveCount(0);

  // The Copy button is server-blind: it is created by upload.js, so if it is
  // visible at all, the script ran.
  const copy = row.locator('.result-copy');
  await expect(copy).toBeVisible();
  await copy.click();
  await expect(copy).toHaveText('Copied');

  const clipboard = await page.evaluate(() => navigator.clipboard.readText());
  expect(clipboard).toBe(url);
});

test('mermaid actually draws, inside the sandboxed preview', async ({ page }) => {
  const url = await uploadViaBrowser(page, fixture('diagram.md', MARKDOWN));
  await page.goto(url);

  const frame = page.frameLocator('iframe.preview');

  // The markdown rendered...
  await expect(frame.locator('.markdown-body h1')).toHaveText('End to end');
  await expect(frame.locator('.markdown-body table')).toBeVisible();

  // ...and mermaid turned the fenced block into an actual SVG. This is the one
  // assertion that cannot be made without a browser, and the reason this suite
  // exists: the CSP names an explicit origin because 'self' matches nothing in
  // the opaque origin a sandboxed iframe gets, and only a real engine proves
  // that got it right.
  // The vendored bundle is only in the runtime image, so this is the one place
  // its fingerprinted URL can be checked at all — and a stale mermaid served
  // from a CDN cache is exactly the failure fingerprinting exists to prevent.
  const src = await frame.locator('script[src*="mermaid.min"]').getAttribute('src');
  expect(src).toMatch(/^\/assets\/mermaid\.min\.[0-9a-f]{12}\.js$/);

  const diagram = frame.locator('pre.mermaid');
  await expect(diagram).toBeVisible();
  await expect(diagram.locator('svg')).toBeVisible();
  await expect(diagram.locator('svg')).toContainText('Human');
});

test('the sandbox holds: an uploaded script never runs', async ({ page }) => {
  const url = await uploadViaBrowser(page, fixture('hostile.md', MARKDOWN));
  await page.goto(url);

  const frame = page.frameLocator('iframe.preview');
  await expect(frame.locator('.markdown-body')).toBeVisible();

  // The sanitiser removed it, and even if it had not, the iframe has no
  // allow-same-origin, so it could not reach this page's window.
  expect(await page.evaluate(() => window.__pwned)).toBeUndefined();
  await expect(page.locator('iframe.preview')).toHaveAttribute('sandbox', 'allow-scripts');
});

test('the viewer is a header of facts over a scrolling frame', async ({ page }) => {
  const url = await uploadViaBrowser(page, fixture('facts.md', MARKDOWN));
  await page.goto(url);

  await expect(page.locator('.filebar h1')).toHaveText('facts.md');
  await expect(page.locator('.filebar')).toContainText('markdown');
  await expect(page.locator('.filebar .expiry')).toContainText('in 15 days');
  await expect(page.locator('.actions .btn', { hasText: 'Download' })).toBeVisible();

  // A link handed to you has to lead somewhere. The brand sits top-left, set
  // apart from the file's own metadata, and goes home.
  const brand = page.locator('.topbar .brand');
  await expect(brand).toBeVisible();
  await expect(brand).toHaveText('share');

  // The viewer carries the same header as every other page, above the file bar.
  const brandBox = await brand.boundingBox();
  const barBox = await page.locator('.filebar').boundingBox();
  expect(brandBox.y).toBeLessThan(barBox.y);

  // The header sits above the frame and the frame fills what is left. A
  // regression here reads as "the preview is 0px tall", which no HTTP test
  // would notice.
  const bar = await page.locator('.filebar').boundingBox();
  const preview = await page.locator('iframe.preview').boundingBox();
  expect(preview.y).toBeGreaterThanOrEqual(bar.y + bar.height - 1);
  expect(preview.height).toBeGreaterThan(200);

  // Last, because it navigates: everything measured above is gone afterwards.
  await brand.click();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator('.uploader .dropzone')).toBeVisible();
});

test('an image previews as an image', async ({ page }) => {
  const url = await uploadViaBrowser(page, fixture('dot.png', PNG));
  await page.goto(url);

  await expect(page.locator('.filebar')).toContainText('image');
  const img = page.frameLocator('iframe.preview').locator('img');
  await expect(img).toBeVisible();
  // naturalWidth is only non-zero if the browser actually decoded it.
  expect(await img.evaluate((el) => el.naturalWidth)).toBeGreaterThan(0);
});

test('a rejected file explains itself across the full row', async ({ page }) => {
  await page.goto('/');
  await page.setInputFiles('#upload-files', fixture('liar.png', 'this is not a png'));

  const row = page.locator('.uploader .results li.failed').first();
  await expect(row).toBeVisible();
  await expect(row.locator('.result-meta')).toContainText('claims to be .png');

  // The bug this replaced: the message was squeezed into the narrow, right
  // aligned column that normally holds a Copy button. It must now take the
  // width of the row and read left to right.
  const rowBox = await row.boundingBox();
  const metaBox = await row.locator('.result-meta').boundingBox();
  expect(metaBox.width).toBeGreaterThan(rowBox.width * 0.6);
  expect(await row.locator('.result-meta').evaluate((el) => getComputedStyle(el).textAlign))
    .toBe('left');
});

test('recent uploads are remembered, and survive a reload', async ({ page }) => {
  await page.goto('/');
  await page.evaluate(() => window.localStorage.clear());
  await page.reload();
  await expect(page.locator('.recent')).toBeHidden();

  await page.setInputFiles('#upload-files', fixture('remembered.md', '# remembered\n'));
  await expect(page.locator('.uploader .results li .result-url')).toBeVisible();
  await trackAll(page);

  await expect(page.locator('.recent')).toBeVisible();
  await expect(page.locator('.recent-list li')).toHaveCount(1);

  // The point of localStorage: it is still there on a fresh page load.
  await page.reload();
  await expect(page.locator('.recent-list li .result-name')).toHaveText('remembered.md');
  await expect(page.locator('.recent-list li .result-meta')).toContainText('expires in 14 days');

  // Newest first. Wait for the URL, not merely for the row: the row appears the
  // instant the upload is queued, so asserting on it and reloading races the
  // request — and the record is only written when the response lands.
  await page.setInputFiles('#upload-files', fixture('newer.md', '# newer\n'));
  await expect(page.locator('.uploader .results li .result-url')).toBeVisible();
  await trackAll(page);
  await page.reload();
  await expect(page.locator('.recent-list li').first().locator('.result-name'))
    .toHaveText('newer.md');

  // Forgetting is local only — the file itself is untouched.
  const stillThere = await page.locator('.recent-list li').first().locator('.result-url').innerText();
  await page.click('.recent-clear');
  await expect(page.locator('.recent')).toBeHidden();
  const res = await page.request.get(stillThere);
  expect(res.status()).toBe(200);
});

test('the share URL alone cannot delete: the confirm page demands the password', async ({ page }) => {
  const url = await uploadViaBrowser(page, fixture('doomed.md', '# doomed\n'));
  const id = url.split('/f/')[1];
  const record = (await history(page)).find((r) => r.id === id);
  expect(record.delete_password, 'the browser was handed the password once').toBeTruthy();

  // The viewer offers Download and nothing else: whoever opens a link they were
  // sent has no password, so a Delete button there would be a door they could
  // never open.
  await page.goto(url);
  await expect(page.locator('.actions .btn')).toHaveCount(1);
  await expect(page.locator('.actions .btn')).toHaveText('Download');

  // The page still works for whoever does have the password.
  await page.goto(url + '/delete');
  await expect(page.locator('h1')).toHaveText('Delete this file?');

  // Whoever was merely SENT the link does not have this, which is the point.
  await page.fill('#delete-password', 'not the password');
  await page.click('button[type=submit]');
  await expect(page.locator('.failed')).toContainText('wrong delete password');
  await page.goto(url);
  await expect(page.locator('.filebar h1')).toHaveText('doomed.md');

  await page.goto(url + '/delete');
  await page.fill('#delete-password', record.delete_password);
  await page.click('button[type=submit]');
  await expect(page.locator('h1')).toHaveText('Deleted');

  await page.goto(url);
  await expect(page.locator('h1')).toHaveText('Nothing here');
});

test('recent uploads can delete, because only this browser has the password', async ({ page }) => {
  await page.goto('/');
  await page.evaluate(() => window.localStorage.clear());
  await page.reload();

  await page.setInputFiles('#upload-files', fixture('own-it.md', '# own it\n'));
  await expect(page.locator('.uploader .results li .result-url')).toBeVisible();
  const url = await page.locator('.uploader .results li .result-url').innerText();

  await page.reload();
  const row = page.locator('.recent-list li').first();
  const del = row.locator('.result-delete');
  await expect(del).toBeVisible();

  // Two clicks, because one is far too easy to hit by accident.
  await del.click();
  await expect(del).toHaveText('Really delete?');
  await del.click();

  await expect(page.locator('.recent')).toBeHidden();
  const res = await page.request.get(url);
  expect(res.status()).toBe(404);
});
