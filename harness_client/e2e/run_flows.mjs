import { chromium, devices } from 'playwright';
import fs from 'node:fs';

const WEB = process.env.WEB_URL ?? 'http://127.0.0.1:8899';
const ACP = process.env.ACP_URL ?? 'ws://127.0.0.1:4277/acp';
const STANDARD = process.env.STANDARD_ACP_URL ?? 'ws://127.0.0.1:4278/acp';
const SIGN_IN = process.env.SIGN_IN_ACP_URL ?? 'ws://127.0.0.1:4279/acp';
const OUT = new URL('../screenshots/', import.meta.url);
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
  await page.waitForTimeout(300);
  await page.screenshot({ path: new URL(`${name}.png`, OUT).pathname });
  console.log(`shot ${name}`);
}

async function boot(page, { style = 'android', query = '' } = {}) {
  const platform = style === 'ios' ? '&platform=cupertino' : '';
  await page.goto(`${WEB}/?v=${Date.now()}${platform}${query}`, {
    waitUntil: 'networkidle',
    timeout: 60000,
  });
  await page.waitForTimeout(2200);
}

async function connect(page, address) {
  const fields = page.locator('input[data-semantics-role="text-field"]:not([disabled])');
  const field = fields.nth(0);
  await field.click();
  await page.waitForTimeout(350);
  await page.keyboard.insertText(address);
  await page.waitForTimeout(450);
  const value = await field.inputValue();
  if (!value) {
    await field.fill(address);
    await page.waitForTimeout(300);
  }
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  await waitSessions(page);
}

async function waitSessions(page, timeout = 20000) {
  await page
    .locator('flt-semantics[role=button]')
    .filter({ hasText: 'Design the merge queue' })
    .waitFor({ timeout });
  await page.waitForTimeout(600);
}

async function openSession(page, title) {
  await page.locator('flt-semantics[role=button]').filter({ hasText: title }).first().click();
  await page.waitForTimeout(1600);
}

async function send(page, text) {
  const field = page
    .locator('textarea[data-semantics-role="text-field"]:not([disabled]), input[data-semantics-role="text-field"]:not([disabled])')
    .last();
  await field.click();
  await page.waitForTimeout(350);
  await page.keyboard.insertText(text);
  await page.waitForTimeout(400);
  const sendButton = page.getByRole('button', { name: /Send message/ });
  await sendButton.click();
}

async function clickButton(page, name, { exact = true } = {}) {
  await page.getByRole('button', { name, exact }).first().click();
}

async function nav(page, label) {
  const tab = page.getByRole('tab', { name: new RegExp(label) });
  if (await tab.count()) {
    await tab.last().click();
  } else {
    const button = page.getByRole('button', { name: new RegExp(label) });
    if (await button.count()) {
      await button.last().click();
    } else {
      await page.getByText(label, { exact: true }).last().click();
    }
  }
  await page.waitForTimeout(1000);
}

async function goBack(page) {
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

async function run() {
  // --- Apple phone: connection, sessions, chat, streaming, permission, question.
  {
    const { page, context } = await pageFor('ios');
    await boot(page, { style: 'ios' });
    await shot(page, 'ios-connect');
    await connect(page, ACP);
    await shot(page, 'ios-sessions');
    await openSession(page, 'Design the merge queue');
    await shot(page, 'ios-chat');

    await send(page, 'Walk me through it again, slowly');
    await page.waitForTimeout(600);
    await shot(page, 'ios-streaming');
    await page.waitForTimeout(5000);

    await send(page, 'Run the tests with permission');
    await page.getByText('PERMISSION', { exact: true }).waitFor({ timeout: 15000 });
    await shot(page, 'ios-permission');
    await clickButton(page, 'Allow');
    // What the call that ran gave back is drawn by run_tools.mjs
    // (`ios-tool-result`), which opens it.
    await page.waitForTimeout(2600);

    await send(page, 'Ask me a question about layouts');
    await page.getByText('Which layout should the tablet session view use?', { exact: true }).waitFor({ timeout: 15000 });
    await shot(page, 'ios-question');
    await page
      .locator('flt-semantics[role=button]')
      .filter({ hasText: 'Split: list and transcript' })
      .first()
      .click();
    await page.waitForTimeout(300);
    await clickButton(page, 'Send answer');
    await page.waitForTimeout(1400);
    await shot(page, 'ios-question-answered');

    await goBack(page);
    await nav(page, 'Settings');
    await shot(page, 'ios-settings');
    await context.close();
  }

  // --- Android phone: connection, sessions, tasks, usage, server, settings.
  {
    const { page, context } = await pageFor('android');
    await boot(page);
    await shot(page, 'android-connect');
    await connect(page, ACP);
    await shot(page, 'android-sessions');

    // Create a session through the sheet.
    await page.getByRole('button', { name: 'New session', exact: true }).click();
    await page.getByText('Start session', { exact: true }).waitFor({ timeout: 8000 });
    await page
      .locator('input[aria-label="What is this conversation about?"]')
      .fill('A test session from the emulator');
    await shot(page, 'android-new-session-sheet');
    await page.getByRole('button', { name: 'Start session', exact: true }).click();
    await page.waitForTimeout(1800);
    await shot(page, 'android-new-session');
    await goBack(page);

    await openSession(page, 'Design the merge queue');
    await shot(page, 'android-chat');
    // The plan that pays for the session, with its quota, says more when it
    // is touched: who pays, and a meter for each window.
    await page.getByRole('button', { name: /Plan: Max/ }).first().click();
    await page.getByText(/Current session \(5 hours\)/).first().waitFor({ timeout: 8000 });
    await page.waitForTimeout(500);
    await shot(page, 'android-plan-sheet');
    await page.mouse.click(206, 60); // the scrim above the sheet closes it
    await page.waitForTimeout(700);
    await goBack(page);

    await nav(page, 'Tasks');
    await shot(page, 'android-tasks');
    await page.getByRole('button', { name: 'New task', exact: true }).click();
    await page.getByText('Submit task', { exact: true }).waitFor({ timeout: 8000 });
    const promptField = page
      .locator('textarea[data-semantics-role="text-field"]:not([disabled]), input[data-semantics-role="text-field"]:not([disabled])')
      .last();
    await promptField.click();
    await page.waitForTimeout(300);
    await page.keyboard.insertText('Add a small native settings screenshot flow');
    await page.waitForTimeout(300);
    await page.getByRole('button', { name: 'High', exact: true }).click();
    // Attach two pictures: the photo picker is the browser's file chooser.
    const [chooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      page.getByRole('button', { name: /Attach images/ }).first().click(),
    ]);
    await chooser.setFiles([
      new URL('android-chat.png', OUT).pathname,
      new URL('android-tasks.png', OUT).pathname,
    ]);
    // The pictures are read, and shown, a moment later.
    await page.getByRole('button', { name: /Add more/ }).waitFor({ timeout: 20000 });
    await page.waitForTimeout(600);
    await shot(page, 'android-new-task-sheet');
    await page.getByRole('button', { name: 'Submit task', exact: true }).click();
    await page.waitForTimeout(1600);
    await shot(page, 'android-task-created');
    // The task names the pictures it was sent with.
    await page
      .getByRole('button', { name: /Add a small native settings screenshot flow/ })
      .first()
      .click();
    await page.getByText('ATTACHMENTS', { exact: true }).waitFor({ timeout: 8000 });
    await shot(page, 'android-task-pictures');
    await clickButton(page, 'Close');
    await page.waitForTimeout(500);
    await page
      .locator('flt-semantics[role=button]')
      .filter({ hasText: 'Review' })
      .filter({ hasNotText: 'required' })
      .first()
      .click();
    await page.waitForTimeout(500);
    await shot(page, 'android-tasks-review');
    await page
      .getByRole('button', { name: /Review the emulator screenshots/ })
      .first()
      .click();
    await page.getByText('Verify and merge', { exact: true }).waitFor({ timeout: 10000 });
    await shot(page, 'android-task-detail');
    await clickButton(page, 'Verify and merge');
    await page.waitForTimeout(1200);
    await shot(page, 'android-task-verified');
    await clickButton(page, 'Close');
    await page.waitForTimeout(500);

    await nav(page, 'Usage');
    await shot(page, 'android-usage');
    // The wheel scrolls what the pointer is over, not the corner it was left
    // in, and a page takes it in small steps: down past the plan to the models.
    await page.mouse.move(206, 500);
    for (let step = 0; step < 8; step += 1) {
      await page.mouse.wheel(0, 600);
      await page.waitForTimeout(150);
    }
    await page.waitForTimeout(700);
    await shot(page, 'android-usage-models');

    await nav(page, 'Server');
    await shot(page, 'android-server');
    await page.mouse.wheel(0, 900);
    await page.waitForTimeout(500);
    await shot(page, 'android-server-methods');

    await nav(page, 'Settings');
    await shot(page, 'android-settings');
    await context.close();
  }

  // --- Android phone, signing in from inside the app: the harness lists how
  // (ACP's authMethods), the user picks one, and the person at the harness's
  // Emacs approves.  The mock approves a few seconds after it is asked.
  {
    const { page, context } = await pageFor('android');
    await page.setViewportSize({ width: 412, height: 1250 });
    await boot(page);
    const field = page.locator('input[data-semantics-role="text-field"]:not([disabled])').nth(0);
    await field.click();
    await page.waitForTimeout(350);
    await page.keyboard.insertText(SIGN_IN);
    await page.waitForTimeout(450);
    await page.getByRole('button', { name: 'Connect', exact: true }).click();
    const approve = page.getByRole('button', { name: /Approve in Emacs/ });
    await approve.waitFor({ timeout: 20000 });
    await page.waitForTimeout(600);
    await shot(page, 'android-signin');
    await approve.click();
    await page.getByText('Waiting for approval in Emacs', { exact: true }).waitFor({ timeout: 10000 });
    await page.waitForTimeout(600);
    await shot(page, 'android-signin-waiting');
    await waitSessions(page);

    // The app is opened again (the page is loaded again).  The harness handed
    // it a session secret and it kept it, so it goes back in by itself:
    // nothing to tap and nothing to approve, though the mock would take six
    // seconds to approve.
    await page.setViewportSize({ width: 412, height: 915 });
    const reopened = Date.now();
    await page.reload({ waitUntil: 'networkidle', timeout: 60000 });
    await waitSessions(page);
    if (Date.now() - reopened > 5500) {
      throw new Error('the app took as long as an approval to go back in: it asked again');
    }
    if (await page.getByRole('button', { name: 'Connect', exact: true }).count()) {
      throw new Error('the connection form is up after the app went back in');
    }

    // Opened again while the harness cannot be reached: it says so, and keeps
    // trying by itself; when the harness is back it is in, still asking nobody.
    let away = true;
    await page.routeWebSocket(/\/acp/, (ws) => {
      if (away) ws.close({ code: 1006, reason: 'the harness is away' });
      else ws.connectToServer();
    });
    await page.reload({ waitUntil: 'networkidle', timeout: 60000 });
    // The card's text is a live region, which the page's semantics gives as a
    // label or as text; its button is the same either way.
    await page
      .getByRole('button', { name: 'Use another address' })
      .waitFor({ timeout: 20000 });
    await page.waitForTimeout(600);
    await shot(page, 'android-resuming');
    away = false;
    await waitSessions(page, 40000);
    await context.close();
  }

  // --- macOS: the wide sidebar and the list/detail split.
  {
    const context = await browser.newContext({
      viewport: { width: 1280, height: 900 },
      deviceScaleFactor: 2,
      isMobile: false,
      hasTouch: false,
      serviceWorkers: 'block',
    });
    const page = await context.newPage();
    page.on('pageerror', (error) => console.log(`[pageerror] ${error.message}`));
    await boot(page, { style: 'ios' });
    await connect(page, ACP);
    await shot(page, 'macos-sessions');
    await page
      .locator('flt-semantics[role=button]')
      .filter({ hasText: 'Design the merge queue' })
      .first()
      .click();
    await page.waitForTimeout(1800);
    await shot(page, 'macos-chat');
    await nav(page, 'Tasks');
    await shot(page, 'macos-tasks');
    await context.close();
  }

  // --- Android against a plain ACP agent: the same chat, fewer tabs.
  {
    const { page, context } = await pageFor('android');
    await boot(page);
    await connect(page, STANDARD);
    await shot(page, 'android-standard-sessions');
    await openSession(page, 'Design the merge queue');
    await send(page, 'hello from a plain ACP agent');
    await page.waitForTimeout(1600);
    await shot(page, 'android-standard-chat');
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
