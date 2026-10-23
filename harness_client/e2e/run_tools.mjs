// How a tool call reads in the transcript: the calls of the tools on the
// harness's allow list folded into runs under one summary line (as its Emacs
// chat folds them) and a run opened to its calls; a call opened to its input
// and its output, a long result cut to a screenful and then shown whole, a call
// that failed and one the permission system refused, the report a hand-in call
// handed in, and the page that shows a call whole.  It drives the same E2E web
// build as run_flows.mjs, against a preview harness started with `--tools` (a
// task's session with the calls of every kind; see
// test/support/tool_showcase.dart), and writes a screenshot of each to
// ../screenshots/ (OUT overrides).
//
//   WEB_URL=http://127.0.0.1:8899 TOOLS_ACP_URL=ws://127.0.0.1:4280/acp \
//   ACP_URL=ws://127.0.0.1:4277/acp node run_tools.mjs
//
// THEME=dark draws it in the dark theme, and writes `NAME-dark.png`.
import { chromium, devices } from 'playwright';
import fs from 'node:fs';

const WEB = process.env.WEB_URL ?? 'http://127.0.0.1:8899';
const ACP = process.env.ACP_URL ?? 'ws://127.0.0.1:4277/acp';
const TOOLS = process.env.TOOLS_ACP_URL ?? 'ws://127.0.0.1:4280/acp';
const THEME = process.env.THEME ?? '';
const OUT = process.env.OUT
  ? new URL(`file://${process.env.OUT.replace(/\/?$/, '/')}`)
  : new URL('../screenshots/', import.meta.url);
fs.mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();

async function pageFor(kind, height) {
  const ios = kind === 'ios';
  const context = await browser.newContext({
    viewport: ios
      ? { width: 390, height: height ?? 844 }
      : { width: 412, height: height ?? 915 },
    deviceScaleFactor: ios ? 3 : 2.625,
    isMobile: true,
    hasTouch: true,
    userAgent: devices[ios ? 'iPhone 13' : 'Pixel 7'].userAgent,
    serviceWorkers: 'block',
  });
  const page = await context.newPage();
  page.on('pageerror', (error) => console.log(`[pageerror] ${error.message}`));
  page.on('console', (message) => {
    if (message.type() === 'error' && !message.text().includes('favicon')) {
      console.log(`[console] ${message.text()}`);
    }
  });
  return { page, context };
}

async function shot(page, name) {
  await page.mouse.move(2, 2);
  await page.waitForTimeout(400);
  const file = THEME ? `${name}-${THEME}` : name;
  await page.screenshot({ path: new URL(`${file}.png`, OUT).pathname });
  console.log(`shot ${file}`);
}

async function boot(page, { style = 'android' } = {}) {
  const platform = style === 'ios' ? '&platform=cupertino' : '';
  const theme = THEME ? `&theme=${THEME}` : '';
  await page.goto(`${WEB}/?v=${Date.now()}${platform}${theme}`, {
    waitUntil: 'networkidle',
    timeout: 60000,
  });
  await page.waitForTimeout(2200);
}

async function connect(page, address, session) {
  const field = page
    .locator('input[data-semantics-role="text-field"]:not([disabled])')
    .nth(0);
  await field.click();
  await page.waitForTimeout(350);
  await page.keyboard.insertText(address);
  await page.waitForTimeout(450);
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  await page
    .locator('flt-semantics[role=button]')
    .filter({ hasText: session })
    .first()
    .waitFor({ timeout: 20000 });
  await page.waitForTimeout(600);
}

async function openSession(page, title) {
  await page
    .locator('flt-semantics[role=button]')
    .filter({ hasText: title })
    .first()
    .click();
  await page.waitForTimeout(2000);
}

/**
 * The list builds only what is near the screen: wheel until [text] is.  Of
 * several, the first; the last when [last] is set, which is the card of a call
 * in an open run and not the summary line above it that names it too.
 */
async function find(page, text, { role = 'button', last = false } = {}) {
  const matches = page
    .locator(`flt-semantics[role=${role}]`)
    .filter({ hasText: text });
  const locator = last ? matches.last() : matches.first();
  for (const direction of [1, -1]) {
    for (let step = 0; step < 30 && (await locator.count()) === 0; step += 1) {
      await page.mouse.move(206, 450);
      await page.mouse.wheel(0, 350 * direction);
      await page.waitForTimeout(100);
    }
    if ((await locator.count()) > 0) break;
  }
  return locator;
}

async function toBottom(page) {
  await page.mouse.move(206, 450);
  for (let step = 0; step < 14; step += 1) {
    await page.mouse.wheel(0, 900);
    await page.waitForTimeout(100);
  }
  await page.waitForTimeout(500);
}

async function tap(page, text, options = {}) {
  const locator = await find(page, text, options);
  await locator.click();
  await page.waitForTimeout(900);
}

async function goBack(page) {
  const labelled = page.locator('flt-semantics[aria-label="Back"]');
  if (await labelled.count()) {
    await labelled.first().click();
  } else {
    await page.mouse.click(24, 28);
  }
  await page.waitForTimeout(900);
}

async function run() {
  // --- An Apple phone: a command the person allowed, and what it said.
  {
    const { page, context } = await pageFor('ios');
    await boot(page, { style: 'ios' });
    await connect(page, ACP, 'Design the merge queue');
    await openSession(page, 'Design the merge queue');
    const field = page
      .locator(
        'textarea[data-semantics-role="text-field"]:not([disabled]), input[data-semantics-role="text-field"]:not([disabled])',
      )
      .last();
    await field.click();
    await page.waitForTimeout(350);
    await page.keyboard.insertText('Run the tests with permission');
    await page.waitForTimeout(400);
    await page.getByRole('button', { name: /Send message/ }).click();
    await page.getByText('PERMISSION', { exact: true }).waitFor({ timeout: 15000 });
    await page.getByRole('button', { name: 'Allow', exact: true }).first().click();
    await page.waitForTimeout(1400);
    // The call that ran is a run of one, a line in the transcript; open the
    // line, and then the call.
    await tap(page, 'Run the full test suite');
    await tap(page, 'Run the full test suite', { last: true });
    await shot(page, 'ios-tool-result');
    await context.close();
  }

  // --- An Android phone, in a task's session: the calls, one by one.
  {
    const { page, context } = await pageFor('android');
    await boot(page);
    await connect(page, TOOLS, 'Tidy the tool cards');
    await openSession(page, 'Tidy the tool cards');
    await toBottom(page);
    // The reads and the commands are the calls on the harness's allow list:
    // each stretch is one line.  The edit and the refused write are not, and
    // stand as cards between them.
    await shot(page, 'android-tool-calls');

    // Runs opened: their calls, each as closed as any call is, and the
    // thought the model had between its two reads, folded in with them.
    await tap(page, 'Bash ×2');
    await tap(page, 'Read file, Search files · thinking');
    await shot(page, 'android-tool-run');

    // A command: what it was, then what it said, cut to a screenful.
    await tap(page, 'flutter test --reporter expanded');
    await shot(page, 'android-tool-call');
    await tap(page, 'Show all 35 lines');
    await shot(page, 'android-tool-call-all');
    // The call on a page of its own, to read and copy all of it.
    await tap(page, 'Open full view');
    await shot(page, 'android-tool-output');
    await goBack(page);

    // A call that failed says why under its title; opened, it says it all.
    await tap(page, 'Bash: flutter analyze');
    await shot(page, 'android-tool-failed');

    // One the permission system refused is not a failure: it never ran.
    await tap(page, 'Write file: /etc/hosts');
    await shot(page, 'android-tool-denied');

    // An edit: the text it took out and the text it put in.
    await tap(page, 'Edit file: lib/src/ui/widgets/tool_card.dart');
    await shot(page, 'android-tool-edit');
    await context.close();
  }

  // --- The same session on a tall screen: the hand-in call, the last one.
  {
    const { page, context } = await pageFor('android', 1500);
    await boot(page);
    await connect(page, TOOLS, 'Tidy the tool cards');
    await openSession(page, 'Tidy the tool cards');
    await toBottom(page);
    await shot(page, 'android-hand-in-closed');
    await tap(page, 'Hand in the finished work');
    await shot(page, 'android-hand-in');
    await context.close();
  }

  // --- The hand-in call on a phone: opening the last call shows it.
  {
    const { page, context } = await pageFor('android');
    await boot(page);
    await connect(page, TOOLS, 'Tidy the tool cards');
    await openSession(page, 'Tidy the tool cards');
    await toBottom(page);
    await tap(page, 'Hand in the finished work');
    await shot(page, 'android-hand-in-phone');
    await page.mouse.move(206, 450);
    await page.mouse.wheel(0, 700);
    await page.waitForTimeout(700);
    await shot(page, 'android-hand-in-evidence');
    await context.close();
  }

  // --- An Apple phone: the same calls in the platform's own style.
  {
    const { page, context } = await pageFor('ios');
    await boot(page, { style: 'ios' });
    await connect(page, TOOLS, 'Tidy the tool cards');
    await openSession(page, 'Tidy the tool cards');
    await toBottom(page);
    await shot(page, 'ios-tool-calls');
    await tap(page, 'Bash ×2');
    await tap(page, 'Bash: flutter analyze');
    await shot(page, 'ios-tool-failed');
    await context.close();
  }
}

try {
  await run();
  console.log('all flows completed');
} catch (error) {
  const pages = browser.contexts().flatMap((context) => context.pages());
  if (pages.length > 0) {
    await pages[0].screenshot({ path: new URL('failure.png', OUT).pathname }).catch(() => {});
  }
  throw error;
} finally {
  await browser.close();
}
