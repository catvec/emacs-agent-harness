// What a person can do with a task, and where.  The board is a list to choose
// from: a tap on a task, in any column, opens the conversation of its session,
// and the task is handled there, by the bar above the message box: what it
// offers where the task stands, the menu behind its "...", what is asked
// before a task is stopped or deleted, a task paused and resumed, a task in
// review sent back with the feedback typed in the box, and archived.  The
// controls of the queue of a project and of every project stay on the board.
// It drives the same E2E web build as run_flows.mjs, against the preview
// harness (see tool/mock_harness_server.dart, which has the tasks of
// test/support/fake_harness.dart, each with its conversation), and writes a
// screenshot of each to ../screenshots/ (OUT overrides).
//
//   WEB_URL=http://127.0.0.1:8899 ACP_URL=ws://127.0.0.1:4277/acp \
//   node run_task_actions.mjs
import { chromium, devices } from 'playwright';
import fs from 'node:fs';

const WEB = process.env.WEB_URL ?? 'http://127.0.0.1:8899';
const ACP = process.env.ACP_URL ?? 'ws://127.0.0.1:4277/acp';
const OUT = process.env.OUT
  ? new URL(`file://${process.env.OUT.replace(/\/?$/, '/')}`)
  : new URL('../screenshots/', import.meta.url);
fs.mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();

async function pageFor(kind) {
  const ios = kind === 'ios';
  const context = await browser.newContext({
    viewport: ios ? { width: 390, height: 844 } : { width: 412, height: 915 },
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
  await page.screenshot({ path: new URL(`${name}.png`, OUT).pathname });
  console.log(`shot ${name}`);
}

async function boot(page, { style = 'android' } = {}) {
  const platform = style === 'ios' ? '&platform=cupertino' : '';
  await page.goto(`${WEB}/?v=${Date.now()}${platform}`, {
    waitUntil: 'networkidle',
    timeout: 60000,
  });
  await page.waitForTimeout(2200);
}

async function connect(page, address) {
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
    .filter({ hasText: 'Design the merge queue' })
    .first()
    .waitFor({ timeout: 20000 });
  await page.waitForTimeout(600);
}

async function nav(page, label) {
  const tab = page.getByRole('tab', { name: new RegExp(label) });
  if (await tab.count()) {
    await tab.last().click();
  } else {
    await page.getByRole('button', { name: new RegExp(label) }).last().click();
  }
  await page.waitForTimeout(1000);
}

/** Choose a column of the board by its tab. */
async function column(page, label) {
  await page.getByRole('button', { name: new RegExp(`^${label}`) }).first().click();
  await page.waitForTimeout(700);
}

async function click(page, name, { exact = true } = {}) {
  await page.getByRole('button', { name, exact }).first().click();
  await page.waitForTimeout(700);
}

/** A tap on a task: its conversation opens, with the bar of the task in it. */
async function openTask(page, title) {
  await page
    .getByRole('button', { name: new RegExp(`Task ${title}`) })
    .first()
    .click();
  await page.getByRole('button', { name: 'Task actions', exact: true }).first().waitFor({ timeout: 10000 });
  await page.waitForTimeout(900);
}

/** The "..." menu of the bar: what the bar has no room for. */
async function taskMenu(page) {
  await page.getByRole('button', { name: 'Task actions', exact: true }).first().click();
  await page.waitForTimeout(800);
}

/** Back to the board from a conversation. */
async function back(page) {
  const labelled = page.locator('flt-semantics[aria-label="Back"]');
  if (await labelled.count()) {
    await labelled.first().click();
  } else {
    // The navigation bar's back chevron, by position, for platforms whose
    // icon has no semantics label of its own.
    await page.mouse.click(24, 28);
  }
  await page.waitForTimeout(900);
}

/** The text field that is open: the last one there is (a dialog's, or the message box). */
async function type(page, text) {
  const field = page
    .locator('textarea[data-semantics-role="text-field"]:not([disabled]), input[data-semantics-role="text-field"]:not([disabled])')
    .last();
  await field.click();
  await page.waitForTimeout(350);
  await page.keyboard.insertText(text);
  await page.waitForTimeout(400);
}

/** Send what is typed in the message box of the conversation. */
async function sendMessage(page) {
  await page.getByRole('button', { name: /Send message/ }).first().click();
  await page.waitForTimeout(1200);
}

async function run(style, prefix) {
  const { page, context } = await pageFor(style);
  await boot(page, { style });
  await connect(page, ACP);
  await nav(page, 'Tasks');

  // A task at work: its conversation, and in it the bar, which says where the
  // task stands and offers what applies to it.
  await column(page, 'Active');
  await openTask(page, 'Build the Flutter ACP client');
  await shot(page, `${prefix}-task-bar-active`);

  // The rest of what applies is behind its menu: what stops or drops the task
  // is last.
  await taskMenu(page);
  await shot(page, `${prefix}-task-bar-menu`);

  // The priority, set where the task is.
  await click(page, 'Priority', { exact: false });
  await shot(page, `${prefix}-task-priority-asks`);
  await click(page, 'Low priority');
  await shot(page, `${prefix}-task-priority-low`);
  await taskMenu(page);
  await click(page, 'Priority', { exact: false });
  await click(page, 'High priority');

  // Stopping, and deleting, ask first.
  await taskMenu(page);
  await click(page, 'Stop');
  await shot(page, `${prefix}-task-stop-asks`);
  await click(page, 'Keep going');
  await taskMenu(page);
  await click(page, 'Delete task', { exact: false });
  await shot(page, `${prefix}-task-delete-asks`);
  await click(page, 'Cancel');

  // Pausing puts it back in the queue, held, where it is resumed.
  await click(page, 'Pause');
  await shot(page, `${prefix}-task-paused`);
  await click(page, 'Resume');
  await shot(page, `${prefix}-task-resumed`);
  await back(page);
  await column(page, 'Pending');

  // A task in review: verified, or sent back with the feedback typed in the box.
  await column(page, 'Review');
  await openTask(page, 'Review the emulator screenshots');
  await shot(page, `${prefix}-task-bar-review`);
  await click(page, 'Send back');
  await type(page, 'Use the large radius on the sheet, and check the dark palette.');
  await shot(page, `${prefix}-task-send-back`);
  await sendMessage(page);
  await shot(page, `${prefix}-task-sent-back`);
  await back(page);

  // A task that is done is archived, and brought back from the archive.
  await column(page, 'Done');
  await openTask(page, 'Ship the session list');
  await click(page, 'Archive');
  await shot(page, `${prefix}-task-archived-bar`);
  await back(page);
  await click(page, 'Show archived tasks');
  await column(page, 'Done');
  await shot(page, `${prefix}-task-archived`);

  // The queue of a project, which stays on the board: paused, and its tasks
  // with it.
  await click(page, 'All projects', { exact: false });
  await page.getByText('emacs-agent-harness', { exact: true }).last().click();
  await page.waitForTimeout(1200);
  await page.getByRole('button', { name: /working/ }).first().click();
  await page.waitForTimeout(800);
  await shot(page, `${prefix}-task-queue-sheet`);
  await page.getByRole('switch').first().click();
  await page.waitForTimeout(900);
  await click(page, 'Pause all');
  await shot(page, `${prefix}-task-queue-paused`);
  await page.keyboard.press('Escape');
  await context.close();
}

await run('android', 'android');
await run('ios', 'ios');
await browser.close();
