// What a person can do with a task on the board: the menu of a card, the sheet
// of a task with its actions and its priority, what is asked before a task is
// stopped or deleted, a task paused and resumed, and the controls of the queue
// of a project and of every project.  It drives the same E2E web build as
// run_flows.mjs, against the preview harness (see tool/mock_harness_server.dart,
// which has the tasks of test/support/fake_harness.dart), and writes a
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

/** The "..." menu of the first card of the column. */
async function cardMenu(page, title) {
  await page.getByRole('button', { name: `Task ${title}` }).first().waitFor({ timeout: 8000 });
  await page.getByRole('button', { name: 'Task actions', exact: true }).first().click();
  await page.waitForTimeout(800);
}

async function openTask(page, title) {
  await page
    .getByRole('button', { name: new RegExp(`Task ${title}`) })
    .first()
    .click();
  await page.waitForTimeout(1000);
}

async function scrollSheet(page, by = 900) {
  await page.mouse.move(200, 600);
  for (let step = 0; step < 6; step += 1) {
    await page.mouse.wheel(0, by / 6);
    await page.waitForTimeout(120);
  }
  await page.waitForTimeout(400);
}

/** A field of the dialog or sheet that is open: the last text field there is. */
async function type(page, text) {
  const field = page
    .locator('textarea[data-semantics-role="text-field"]:not([disabled]), input[data-semantics-role="text-field"]:not([disabled])')
    .last();
  await field.click();
  await page.waitForTimeout(350);
  await page.keyboard.insertText(text);
  await page.waitForTimeout(400);
}

async function run(style, prefix) {
  const { page, context } = await pageFor(style);
  await boot(page, { style });
  await connect(page, ACP);
  await nav(page, 'Tasks');

  // A task at work: its menu holds everything that applies to it.
  await column(page, 'Active');
  await cardMenu(page, 'Build the Flutter ACP client');
  await shot(page, `${prefix}-task-card-menu`);
  await page.keyboard.press('Escape');
  await page.mouse.click(206, 90); // the scrim closes the menu
  await page.waitForTimeout(600);

  // Its sheet: what can be done, the priority, and what stops it or deletes it.
  await openTask(page, 'Build the Flutter ACP client');
  await scrollSheet(page);
  await shot(page, `${prefix}-task-sheet-actions`);

  // A message to its session.
  await click(page, 'Message');
  await type(page, 'Use the endpoint that lists every project');
  await shot(page, `${prefix}-task-message-asks`);
  await click(page, 'Cancel');

  // The priority, set where the task is.
  await click(page, 'Low');
  await shot(page, `${prefix}-task-priority-low`);
  await click(page, 'High');

  // Stopping, and deleting, ask first.
  await click(page, 'Stop', { exact: false });
  await shot(page, `${prefix}-task-stop-asks`);
  await click(page, 'Keep going');
  await click(page, 'Delete task');
  await shot(page, `${prefix}-task-delete-asks`);
  await click(page, 'Cancel');

  // Pausing puts it back in the queue, held, where it is resumed.
  await click(page, 'Pause');
  await click(page, 'Close');
  await column(page, 'Pending');
  await shot(page, `${prefix}-task-paused`);
  await click(page, 'Resume');
  await shot(page, `${prefix}-task-resumed`);

  // A task in review: verified, or sent back with feedback.
  await column(page, 'Review');
  await openTask(page, 'Review the emulator screenshots');
  await scrollSheet(page);
  await shot(page, `${prefix}-task-sheet-review`);
  await click(page, 'Send back');
  await page.waitForTimeout(500);
  await shot(page, `${prefix}-task-send-back-asks`);
  await click(page, 'Cancel');
  await click(page, 'Close');

  // A task that is done is archived, and brought back from the archive.
  await column(page, 'Done');
  await openTask(page, 'Ship the session list');
  await scrollSheet(page);
  await click(page, 'Archive');
  await shot(page, `${prefix}-task-archived-sheet`);
  await click(page, 'Close');
  await click(page, 'Show archived tasks');
  await column(page, 'Done');
  await shot(page, `${prefix}-task-archived`);

  // The queue of a project: paused, and its tasks with it.
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
