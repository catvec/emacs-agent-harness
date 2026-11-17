# Live evidence: the workspace selector in an isolated harness


Instance: `scripts/dev.sh` opened by `open_harness`, state in
`scripts/.dev/state-harness-dev-b303909eb154/`, three workspaces
(`Home`, `Study`, `Work`) created through `_harness/workspace/create`.

The echo area does not paint in that instance's lowered daemon frame --
a plain `(message "ECHO-AREA-RENDER-TEST")` also leaves
`current-message` nil and no line in the screenshot -- so the words are
read from `*Messages*`, where `message` records them, and the command's
timing from the callbacks.

## 1. Loading before the request, then the menu

Request delayed 1.0 s on purpose to make the wait visible.

    (0ms)   Workspace selector · loading
    (200ms) Workspace selector · waiting
    (1000ms) MENU Workspace:  ("Home" "Work")  ->  OPEN Home

`*Messages*`:

    Workspace selector · loading
    Workspace selector · waiting

## 2. C-g while waiting

Wait given up at 400 ms; the answer came at 1500 ms and opened nothing.

    :opened nil
    :choosing nil
    :elapsed-ms 400
    *Messages*: loading / waiting / cancelled

## 3. Two invocations, one request, one menu

Second invocation at 300 ms, while the first waited.

    :list-requests 1
    :menus 1

## 4. The real server, no stubs

Against the running harness, three real workspaces:

    (0ms) Workspace selector · loading
    (2ms) MENU ("Home" "Study" "Work")  ->  OPEN "Home"
