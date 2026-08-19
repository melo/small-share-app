// The chat room, in a real browser.
//
// Same rule as share.spec.js: if an assertion could be made with curl it belongs
// in app/t/chat.t instead. What is left is the part that needs a real engine:
//
//   * a message posted by another session ARRIVING in an open page, which is a
//     long poll, a postMessage across a sandbox boundary and an append
//   * the room rendering as three bands — facts, conversation, composer — with
//     the conversation scrolling under a header that stays put
//   * markdown rendered inside the sandboxed frame, with a <script> in a
//     message inert and unable to reach the page holding the identity cookie
//   * posting without a navigation, and the box clearing
//   * searching the room, and coming back to the live conversation
//   * the roster picking up an agent that joined while the page was open
//
// It runs against a throwaway instance (see run.sh) — never production.

const { test, expect } = require('/usr/local/lib/node_modules/playwright/test');

// Rooms this run opened, with the password each was handed once, so the
// teardown removes exactly those and never sweeps.
const opened = [];

// A room, and an agent already in it saying something — the state a person
// arrives into when somebody pastes them a URL.
async function roomWithAnAgent(request, topic) {
  const made = await (await request.post('/api/v1/chatrooms', {
    data: { topic, purpose: 'two agents and a person' },
  })).json();
  opened.push(made);

  const id = made.room.id;
  await request.post(`/api/v1/chatrooms/${id}/members`, {
    data: { session_id: 'agent-1', name: 'planner', about: 'holding the release checklist' },
  });
  return { id, made };
}

async function say(request, id, body, session = 'agent-1') {
  await request.post(`/api/v1/chatrooms/${id}/messages`, { data: { session_id: session, body } });
}

// Join as a person: the room asks who you are before it shows anything.
async function joinAs(page, id, name, about) {
  await page.goto(`/c/${id}`);
  await expect(page.locator('.join-form')).toBeVisible();
  await page.fill('#join-name', name);
  if (about) await page.fill('#join-about', about);
  await page.click('.join-form button[type=submit]');
  await expect(page.locator('iframe.transcript')).toBeVisible();
}

test.afterAll(async ({ request }) => {
  for (const made of opened) {
    if (!made.room || !made.delete_password) continue;
    await request
      .delete(`/api/v1/chatrooms/${made.room.id}`,
        { headers: { 'X-Delete-Password': made.delete_password } })
      .catch(() => {});
  }
});

test('the room asks who you are, then hands you the conversation', async ({ page, request }) => {
  const { id } = await roomWithAnAgent(request, 'the door');

  await page.goto(`/c/${id}`);

  // The roster is on the door: who is already in there is exactly what somebody
  // deciding whether to walk in wants to know. What was SAID is not.
  await expect(page.locator('.roster')).toContainText('planner');
  await expect(page.locator('.roster')).toContainText('holding the release checklist');
  await expect(page.locator('iframe.transcript')).toHaveCount(0);

  await joinAs(page, id, 'Pedro', 'deciding on the tag');

  await expect(page.locator('.composer-me')).toContainText('Pedro');
  // A session id for a person too, because every message carries one.
  await expect(page.locator('.composer-me code')).toContainText('human-');

  // …and the arrival is in the room, with what they said they are doing.
  const frame = page.frameLocator('iframe.transcript');
  await expect(frame.locator('li.msg', { hasText: 'deciding on the tag' })).toBeVisible();
});

test('typing /c into a browser lands you in a new room', async ({ page }) => {
  await page.goto('/c?topic=opened+from+the+address+bar');

  await expect(page).toHaveURL(/\/c\/[A-Za-z0-9]{32}$/);
  await expect(page.locator('h1')).toHaveText('opened from the address bar');

  // The delete password is disclosed exactly once, on the door, because a
  // browser never sees the response that created the room.
  await expect(page.locator('.opened')).toContainText('You opened this room');
  const secret = await page.locator('.opened-secret code').innerText();
  expect(secret.length).toBeGreaterThan(8);

  await page.reload();
  await expect(page.locator('.opened')).toHaveCount(0);

  // And it is an ordinary room: join it and it behaves like any other.
  await page.fill('#join-name', 'Pedro');
  await page.click('.join-form button[type=submit]');
  await expect(page.locator('iframe.transcript')).toBeVisible();

  const id = page.url().split('/').pop();
  opened.push({ room: { id }, delete_password: secret });
});

test('three bands: the conversation scrolls, the header does not', async ({ page, request }) => {
  const { id } = await roomWithAnAgent(request, 'the layout');
  for (let n = 1; n <= 30; n++) await say(request, id, `message number ${n}`);
  await joinAs(page, id, 'Pedro');

  const head = await page.locator('.roomhead').boundingBox();
  const frame = await page.locator('iframe.transcript').boundingBox();
  const composer = await page.locator('.composer').boundingBox();

  expect(head.y).toBeLessThan(frame.y);
  expect(frame.y + frame.height).toBeLessThanOrEqual(composer.y + 1);
  // The conversation gets the room that is left, not a fixed slice of it.
  expect(frame.height).toBeGreaterThan(head.height);

  // A room opens at the newest message, which is where a conversation is read
  // from — the frame scrolls itself to the bottom on load.
  const scrolled = await page.frameLocator('iframe.transcript').locator('body')
    .evaluate(() => window.scrollY);
  expect(scrolled).toBeGreaterThan(0);

  // The page around it does not scroll at all; the header stays where it is.
  const before = await page.locator('.roomhead').boundingBox();
  await page.mouse.wheel(0, 400);
  const after = await page.locator('.roomhead').boundingBox();
  expect(after.y).toBe(before.y);
});

test('what another session says arrives without a reload', async ({ page, request }) => {
  const { id } = await roomWithAnAgent(request, 'live');
  await joinAs(page, id, 'Pedro');

  const frame = page.frameLocator('iframe.transcript');
  const before = page.url();

  await say(request, id, 'staging is **green**');
  await expect(frame.locator('li.msg', { hasText: 'staging is green' })).toBeVisible();
  expect(page.url()).toBe(before);

  // And an agent that arrives while the page is open shows up in the roster,
  // paragraph and all.
  await request.post(`/api/v1/chatrooms/${id}/members`, {
    data: { session_id: 'agent-2', name: 'builder', about: 'building the images' },
  });
  await expect(page.locator('.roster')).toContainText('builder');
  await expect(page.locator('.roster')).toContainText('building the images');
});

test('posting from the box does not reload the page, and the box clears',
  async ({ page, request }) => {
    const { id } = await roomWithAnAgent(request, 'posting');
    await joinAs(page, id, 'Pedro');

    let navigated = false;
    page.on('framenavigated', (f) => { if (f === page.mainFrame()) navigated = true; });

    await page.fill('.composer textarea', 'tagging **1.4.0** now');
    await page.click('.composer button[type=submit]');

    const frame = page.frameLocator('iframe.transcript');
    await expect(frame.locator('li.msg', { hasText: 'tagging 1.4.0 now' })).toBeVisible();
    expect(navigated).toBe(false);
    await expect(page.locator('.composer textarea')).toHaveValue('');

    // Your own messages are marked as yours — by the frame, once it knows who is
    // reading, because the markup is handed to everyone in the room unchanged.
    await expect(frame.locator('li.msg.is-me', { hasText: 'tagging' })).toBeVisible();

    // Ctrl-Enter posts too. Enter does not: these are markdown messages and a
    // list needs newlines more than it needs a shortcut.
    await page.fill('.composer textarea', 'one\ntwo');
    await page.locator('.composer textarea').press('Enter');
    await expect(page.locator('.composer textarea')).not.toHaveValue('');
    await page.locator('.composer textarea').press('Control+Enter');
    await expect(frame.locator('li.msg', { hasText: 'two' })).toBeVisible();
  });

test('a message is markdown, and it cannot get out of its frame',
  async ({ page, request }) => {
    const { id } = await roomWithAnAgent(request, 'hostile');
    await say(request, id, [
      '# A heading',
      '',
      '- one',
      '- two',
      '',
      '`code`, and a [link](https://example.com)',
      '',
      '<script>window.top.__pwned = true; document.body.dataset.ran = "yes";</script>',
      '<img src=x onerror="window.top.__pwned = true">',
    ].join('\n'));
    await joinAs(page, id, 'Pedro');

    const frame = page.frameLocator('iframe.transcript');
    await expect(frame.locator('.msg-body h1')).toHaveText('A heading');
    await expect(frame.locator('.msg-body li')).toHaveCount(2);
    await expect(frame.locator('.msg-body code').first()).toHaveText('code');
    await expect(frame.locator('.msg-body a')).toHaveAttribute('href', 'https://example.com');

    // Nothing in the message ran, in either document. The script survives as
    // TEXT — the sanitiser removes the element and the words it contained are
    // escaped, which is inert and is what an uploaded file does too — so the
    // assertion is that there is no element to run, not that the words are gone.
    expect(await page.evaluate(() => window.__pwned)).toBeUndefined();
    expect(await frame.locator('body').evaluate((b) => b.dataset.ran)).toBeUndefined();
    await expect(frame.locator('.msg-body script')).toHaveCount(0);
    await expect(frame.locator('.msg-body img[onerror]')).toHaveCount(0);

    // The frame is sandboxed without allow-same-origin, so it is in an opaque
    // origin: no cookies, and no reading of the page that holds the identity
    // one. Checked rather than assumed, because it is the whole reason the
    // transcript is a separate document.
    await expect(page.locator('iframe.transcript')).toHaveAttribute('sandbox', 'allow-scripts');
    const reach = await frame.locator('body').evaluate(() => {
      const out = { cookie: null, parent: null };
      try { out.cookie = document.cookie; } catch (e) { out.cookie = 'blocked'; }
      try { out.parent = window.parent.document.title; } catch (e) { out.parent = 'blocked'; }
      return out;
    });
    // An opaque origin has no cookie jar at all: reading document.cookie there
    // throws rather than returning an empty string, which is a stronger answer
    // than the one this test originally expected.
    expect(reach.cookie).toBe('blocked');
    expect(reach.parent).toBe('blocked');
  });

test('searching the room, and coming back to the conversation', async ({ page, request }) => {
  const { id } = await roomWithAnAgent(request, 'searching');
  await say(request, id, 'the migration is written');
  await say(request, id, 'lunch');
  await say(request, id, 'the migration is green on staging');
  await joinAs(page, id, 'Pedro');

  const frame = page.frameLocator('iframe.transcript');
  await expect(frame.locator('li.msg')).toHaveCount(5);    // two arrivals, three messages

  // A GET aimed at the frame: this works with scripting off too.
  await page.fill('.roomsearch input[name=q]', 'migration');
  await page.click('.roomsearch button[type=submit]');
  await expect(frame.locator('.searching')).toBeVisible();
  await expect(frame.locator('li.msg')).toHaveCount(2);

  // While a search is on screen, a message arriving must NOT be appended to it —
  // it is not a search result.
  await say(request, id, 'unrelated chatter');
  await expect(frame.locator('li.msg')).toHaveCount(2);

  await page.click('.roomsearch-live');
  await expect(frame.locator('li.msg', { hasText: 'unrelated chatter' })).toBeVisible();
  await expect(frame.locator('.searching')).toHaveCount(0);

  // …and the room is live again, with nothing shown twice.
  await say(request, id, 'and we are back');
  await expect(frame.locator('li.msg', { hasText: 'and we are back' })).toHaveCount(1);
});

test('with JavaScript off the room still works', async ({ browser, request }) => {
  const { id } = await roomWithAnAgent(request, 'no javascript');
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();

  await page.goto(`/c/${id}`);
  await page.fill('#join-name', 'Pedro');
  await page.click('.join-form button[type=submit]');
  await expect(page.locator('iframe.transcript')).toBeVisible();

  // The composer is a plain form: it posts and lands back on the room.
  await page.fill('.composer textarea', 'posted with no script at all');
  await page.click('.composer button[type=submit]');
  await expect(page).toHaveURL(new RegExp(`/c/${id}$`));

  const frame = page.frameLocator('iframe.transcript');
  await expect(frame.locator('li.msg', { hasText: 'posted with no script at all' }))
    .toBeVisible();

  // No dead controls: the keyboard hint and the Live button describe things that
  // only exist when the script is running.
  await expect(page.locator('.composer-hint')).toBeHidden();
  await expect(page.locator('.roomsearch-live')).toHaveCount(0);

  await context.close();
});
