# Writing a module

The kernel provides modules, services, events and deferreds
([architecture.md](architecture.md)).  A module is one feature file that
declares a manifest, registers what it provides during setup, and undoes
it during teardown.

## Skeleton

```elisp
;;; harness-greeting.el --- Say hello -*- lexical-binding: t; -*-

;;; Commentary:

;; One or two sentences: what this module provides and what it needs.

;;; Code:

(require 'harness-core)

(defgroup harness-greeting nil
  "Greeting module."
  :group 'harness)

(defcustom harness-greeting-template "Hello, %s!"
  "Greeting format."
  :type 'string)

(defun harness-greeting-setup ()
  "Set up the greeting module."
  (harness-service-register
   "greeting"
   :module 'harness-greeting
   :doc "Produce greetings."
   :methods '((greet . harness-greeting-service-greet)))
  (harness-tool-register
   "greet"
   :description "Greet someone by name."
   :schema '(:type "object" :properties (:name (:type "string")) :required ["name"])
   :kind 'read
   :read-only t
   :handler #'harness-greeting-tool))

(defun harness-greeting-teardown ()
  "Tear down the greeting module."
  nil)                                  ; registrations are removed automatically

(defun harness-greeting-service-greet (&rest args)
  "Service: greet :name."
  (format harness-greeting-template (plist-get args :name)))

(defun harness-greeting-tool (arguments _context)
  "Tool: greet someone."
  (format harness-greeting-template (plist-get arguments :name)))

(harness-module-define 'harness-greeting
  :version "0.1.0"
  :description "Greetings."
  :requires '((harness-core "0.1.0"))
  :provides '(harness-greeting)
  :setup #'harness-greeting-setup
  :teardown #'harness-greeting-teardown)

(provide 'harness-greeting)
;;; harness-greeting.el ends here
```

Rules of thumb:

- One module per concern; declare every dependency in `:requires`.
- Top-level code must not depend on other modules being set up.  Do that
  work in `:setup`.
- `:teardown` must leave nothing behind.  Services, event handlers and
  tools are removed automatically, but timers, processes and buffers are
  the module's responsibility.
- Everything a module provides should either be a service (request /
  response) or an event (notification).  A module author discovers the
  rest of the system with `M-x harness-describe`.
- Cross-module calls use `harness-service-call`, which is late-bound:
  check `harness-service-available-p` when a dependency is optional.

## Async work

Any function that can take longer than an instant returns a
`harness-deferred`:

```elisp
(defun harness-greeting-fetch (&rest args)
  (let ((deferred (harness-deferred-new)))
    (run-at-time 1 nil
                 (lambda ()
                   (harness-deferred-resolve deferred "slow hello")))
    deferred))
```

Compose with `harness-deferred-then`, `-finally`, `-all`, `-cancel`.
Never loop on `accept-process-output`; use process filters, timers and
deferreds.  Long text processing should use `harness-budget-run` in
timer-scheduled chunks.

## Services

```elisp
(harness-service-call "greeting" 'greet :name "Ada")
```

Methods should return plain JSON-able data (plists, vectors, strings,
numbers, `t`/`:false`, `:null`) or a deferred of it; this is what the ACP
projection sends to remote clients.  Signal `harness-user-error` for
invalid requests (it becomes an ACP invalid-params error) and
`harness-error` for internal failures.

## Events

Declare events before emitting them, with a payload description:

```elisp
(harness-event-define 'greeting-sent
  :module 'harness-greeting
  :doc "A greeting was produced."
  :payload '((name . string) (text . string)))

(harness-emit 'greeting-sent :name name :text text)

(harness-on 'greeting-sent #'my-handler :module 'harness-greeting)
```

Handlers must be quick and must not signal.  The ACP layer subscribes to
a curated set of session events and projects them onto `session/update`
notifications; if a feature must reach a remote client, say so there.

## Tools

Handlers receive the model's arguments and a `harness-tool-context`
(`:session-id`, `:cwd`, `:abort`).  They return a result plist, a string,
or a deferred.  Context-bomb protection, error conversion and result
normalization happen in the registry, so handlers only do their job:

```elisp
(defun my-tool (arguments context)
  (let ((path (harness-tool-context-path context (plist-get arguments :path))))
    (harness-tool-result (format "Looked at %s" path))))
```

Declare `:access` when the tool touches file paths: the directory jail
uses it to decide whether to ask the user.  Declare `:range-params` when
the tool can narrow its output, so oversized results come back as an
instruction to use them instead of a truncated blob.  Tools that spawn
processes must do so through `harness-sandbox-spawn`.

## Testing

Every module gets an ERT suite in `test/`.  Load only the kernel, the
module under test, and fakes of the services it consumes:

```elisp
(require 'harness-test-helpers)

(ert-deftest harness-greeting-service ()
  (harness-module-load 'harness-greeting)
  (should (equal (harness-service-call "greeting" 'greet :name "Ada")
                 "Hello, Ada!")))
```

`scripts/test.sh test/harness-greeting-test.el` runs it in a clean Emacs.
Use `harness-test-helpers` for waiting on deferreds and the canned HTTP
server.  UI changes additionally go through `scripts/demo.sh` and its
screenshots (see [dev-loop.md](dev-loop.md)).

## Reloading

`M-x harness-module-reload` (or `harness-reload` for everything) reloads
in place: the module's sources are compiled first, unload keeps
definitions and variable values in place, and a failed load restores the
previous definitions and setup.  Modules do not need to do anything
special, but remember that variable *defaults* are not re-applied on
reload; only newly added code takes effect.  Sessions and other state
that must survive a reload goes through `harness-core-state-set` /
`harness-core-state-get`.
