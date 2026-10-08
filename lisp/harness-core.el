;;; harness-core.el --- Module bus for the Emacs agent harness  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The core of the harness does exactly two things: it loads modules,
;; and it lets modules talk to each other without knowing about each
;; other.  Nothing here shows a UI or calls a model.
;;
;; Three primitives make up the bus:
;;
;; - Methods.  A module registers a named entry point with
;;   `harness-register-method' and anybody calls it with `harness-call'.
;;   A method may return a value directly or a `harness-promise' when
;;   the work is asynchronous.  `harness-call-async' hides the difference.
;;
;; - Events.  A module announces that something happened with
;;   `harness-emit'; interested parties subscribe with `harness-on'.
;;   Subscribers never see each other's errors.
;;
;; - Filters.  A named chain of functions that each get to transform a
;;   value (`harness-run-filter'), or asynchronously decide something
;;   (`harness-run-filter-async').  Permission hooks are built on this.
;;
;; Modules describe themselves with `harness-define-module'.  The core
;; initialises them in dependency order and isolates failures so a
;; broken module never bricks the rest.
;;
;; Everything registered on the bus is introspectable with
;; `harness-methods', `harness-events' and `harness-filters'; the ACP
;; layer exposes that as the protocol surface.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup harness nil
  "Emacs native agent harness."
  :group 'tools
  :prefix "harness-")

(define-error 'harness-error "Harness error")
(define-error 'harness-no-such-method "No such harness method" 'harness-error)
(define-error 'harness-module-error "Harness module error" 'harness-error)

;;;; Logging

(defcustom harness-log-level 'info
  "Minimum level of messages kept in the harness log buffer.
At `debug' an error caught in a promise callback is logged with a
backtrace too."
  :type '(choice (const debug) (const info) (const warn) (const error))
  :group 'harness)

(defconst harness-log-buffer-name "*harness-log*")
(defconst harness--log-levels '((debug . 0) (info . 1) (warn . 2) (error . 3)))
(defconst harness--log-max-lines 5000
  "Maximum number of lines kept in the log buffer.")

(defvar harness-log-hook nil
  "Functions called with (LEVEL MESSAGE) for every log entry.")

(defun harness-log (level fmt &rest args)
  "Log FMT formatted with ARGS at LEVEL (debug, info, warn or error)."
  (when (>= (or (alist-get level harness--log-levels) 1)
            (or (alist-get harness-log-level harness--log-levels) 1))
    (let ((msg (apply #'format-message fmt args)))
      (with-current-buffer (get-buffer-create harness-log-buffer-name)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format-time-string "%H:%M:%S.%3N ")
                  (format "%-5s " (upcase (symbol-name level)))
                  msg "\n")
          (when (> (count-lines (point-min) (point-max)) harness--log-max-lines)
            (goto-char (point-min))
            (forward-line (/ harness--log-max-lines 4))
            (delete-region (point-min) (point)))))
      (run-hook-with-args 'harness-log-hook level msg)
      msg)))

;;;; Corporate mode

(defvar harness-corporate-mode-change-hook nil
  "Hook run after `harness-corporate-mode' changes through `setopt' or Customize.
The option already holds its new value.  The UI restarts the harness
process from here, so the change reaches it, and the remote access
module stops serving other devices.")

(defun harness--set-corporate-mode (symbol value)
  "Set SYMBOL, `harness-corporate-mode', to VALUE; run the change hook if it flips."
  (let ((before (and (default-boundp symbol) (default-value symbol))))
    (set-default-toplevel-value symbol value)
    (unless (eq (not before) (not value))
      (condition-case err
          (run-hooks 'harness-corporate-mode-change-hook)
        (error (harness-log 'error "corporate mode: a change hook failed: %S" err))))))

(defcustom harness-corporate-mode nil
  "Non-nil turns off harness features that could carry data off this machine.
It is meant for work machines whose policy allows code and data to go
to the model provider in use, and search queries to a search engine,
and nowhere else.  With it on:

- The harness serves ACP on this machine only: `harness-acp-allow-remote'
  is ignored, the listener for phones and other devices, with its
  pairing QR codes (`harness-acp-remote'), is refused, and so is any
  client on another device.
- This Emacs's UI connects to its own harness only, never to a harness
  elsewhere (`harness-connect-remote').
- Network tools other than web search (web_fetch, which reaches any
  URL), and ssh, which runs commands on other machines, are not offered
  to sessions, and calls to them are denied.

Web search stays on: web_search sends its queries to the search
provider (`harness-websearch-provider'), and model providers that
search the web themselves run their searches on their side (see
`harness-websearch-builtin').  Either way the search is a call of
web_search, which the permission rules decide as usual; a standing
rule that denies web_search (`harness-perms-rules') refuses it.

Model providers still receive what sessions send them, and shell
commands stay governed by the permission mode and the sandbox
\(`harness-sandbox-policy').

Set it in your init file, before `harness-start'.  The settings page
does not offer it and no ACP client can change it.  Changed later with
`setopt' or Customize, it restarts the harness process so the change
reaches it."
  :type 'boolean :group 'harness
  :set #'harness--set-corporate-mode
  :initialize #'custom-initialize-default)

(defun harness-corporate-p ()
  "Non-nil when `harness-corporate-mode' is on."
  (and harness-corporate-mode t))

;;;; Promises

(cl-defstruct (harness-promise (:constructor harness-promise--make)
                               (:copier nil))
  (state 'pending)        ; pending, resolved, rejected
  value
  callbacks)              ; list of (on-ok . on-err)

(defun harness-make-promise ()
  "Return a new pending promise."
  (harness-promise--make))

(defun harness-promise-settled-p (promise)
  "Non-nil when PROMISE is resolved or rejected."
  (not (eq (harness-promise-state promise) 'pending)))

(defvar harness--dispatch-depth 0
  "How many promise callbacks are currently nested on the stack.")

(defconst harness--dispatch-max-depth 20
  "Nesting beyond which callbacks are deferred to the command loop.")

(defun harness--promise-enqueue (promise cb)
  "Run CB for settled PROMISE now, or from the command loop when deeply nested.
Shallow chains keep their synchronous feel; a chain of a thousand
promises resolving one another never grows the stack past the limit,
and a callback that waits synchronously cannot deadlock the rest."
  (if (>= harness--dispatch-depth harness--dispatch-max-depth)
      (harness-run-soon #'harness--promise-dispatch promise cb)
    (let ((harness--dispatch-depth (1+ harness--dispatch-depth)))
      (harness--promise-dispatch promise cb))))

(defun harness--promise-settle (promise state value)
  (when (eq (harness-promise-state promise) 'pending)
    (setf (harness-promise-state promise) state
          (harness-promise-value promise) value)
    (let ((callbacks (nreverse (harness-promise-callbacks promise))))
      (setf (harness-promise-callbacks promise) nil)
      (dolist (cb callbacks)
        (harness--promise-enqueue promise cb))))
  promise)

(defun harness--promise-dispatch (promise cb)
  (let ((fn (if (eq (harness-promise-state promise) 'resolved) (car cb) (cdr cb))))
    (when fn
      (condition-case err
          (if (and (harness--debug-p) (fboundp 'handler-bind))
              (handler-bind ((error #'harness--capture-backtrace))
                (funcall fn (harness-promise-value promise)))
            (funcall fn (harness-promise-value promise)))
        (error
         (harness-log 'error "promise callback failed: %S%s" err
                      (if (and (harness--debug-p) harness--last-backtrace)
                          (format "\n  frames: %s" (string-join (seq-take (cdr harness--last-backtrace) 40) " < "))
                        "")))))))

(defun harness-resolve (promise value)
  "Resolve PROMISE with VALUE.  If VALUE is itself a promise, adopt it."
  (if (harness-promise-p value)
      (progn (harness-then value
                           (lambda (v) (harness-resolve promise v) nil)
                           (lambda (e) (harness-reject promise e) nil))
             promise)
    (harness--promise-settle promise 'resolved value)))

(defun harness-reject (promise error)
  "Reject PROMISE with ERROR (any object, usually an error data list)."
  (harness--promise-settle promise 'rejected error))

(defvar harness--last-backtrace nil)

(defun harness--debug-p ()
  "Non-nil when `harness-log-level' asks for debugging detail."
  (eq harness-log-level 'debug))

(defun harness--capture-backtrace (err)
  "Remember a compact backtrace for ERR before the stack unwinds."
  (let ((max-lisp-eval-depth (+ max-lisp-eval-depth 2000)))
    (setq harness--last-backtrace
          (condition-case nil
              (let ((i 0) f (names nil))
                (while (and (setq f (backtrace-frame i)) (< i 2000))
                  (when (symbolp (cadr f)) (push (symbol-name (cadr f)) names))
                  (setq i (1+ i)))
                (cons err (nreverse names)))
            (error (list err "backtrace unavailable"))))))

(defun harness--call-handler (fn value)
  "Call promise handler FN with VALUE.
When `harness-log-level' is `debug', capture a backtrace on error."
  (if (and (harness--debug-p) (fboundp 'handler-bind))
      (handler-bind ((error #'harness--capture-backtrace))
        (funcall fn value))
    (funcall fn value)))

(defun harness--note-handler-error (err fn)
  "Log ERR signalled inside promise handler FN.
A handler that signals is almost always a bug, and the rejection it
produces may never be observed, so it is logged here."
  (harness-log 'error "promise handler %s signalled: %S%s"
               (let ((print-length 12) (print-level 3))
                 (truncate-string-to-width (prin1-to-string fn) 400 nil nil "…"))
               err
               (if (and (harness--debug-p) harness--last-backtrace)
                   (format "\n  frames: %s" (string-join (seq-take (cdr harness--last-backtrace) 40) " < "))
                 "")))

(defun harness-then (promise on-ok &optional on-err)
  "Call ON-OK with the value of PROMISE, or ON-ERR with its error.
Return a new promise resolved with the handler's return value.  A
handler may itself return a promise, which is adopted."
  (let ((next (harness-make-promise)))
    (let ((cb (cons (lambda (v)
                      (condition-case err
                          (harness-resolve next (if on-ok (harness--call-handler on-ok v) v))
                        (error (harness--note-handler-error err on-ok)
                               (harness-reject next err))))
                    (lambda (e)
                      (if on-err
                          (condition-case err
                              (harness-resolve next (harness--call-handler on-err e))
                            (error (harness--note-handler-error err on-err)
                                   (harness-reject next err)))
                        (harness-reject next e))))))
      (if (harness-promise-settled-p promise)
          (harness--promise-enqueue promise cb)
        (push cb (harness-promise-callbacks promise))))
    next))

(defun harness-catch (promise on-err)
  "Attach ON-ERR to PROMISE, returning a new promise."
  (harness-then promise nil on-err))

(defun harness-finally (promise fn)
  "Call FN with no arguments once PROMISE settles either way."
  (harness-then promise
                (lambda (v) (funcall fn) v)
                (lambda (e) (funcall fn) (signal 'harness-error (list e)))))

(defun harness-resolved (value)
  "Return a promise already resolved with VALUE."
  (harness-resolve (harness-make-promise) value))

(defun harness-rejected (error)
  "Return a promise already rejected with ERROR."
  (harness-reject (harness-make-promise) error))

(defun harness-all (promises)
  "Return a promise resolved with the list of values of PROMISES, in order."
  (let* ((result (harness-make-promise))
         (n (length promises))
         (values (make-vector (max n 1) nil))
         (remaining n))
    (if (zerop n)
        (harness-resolve result nil)
      (cl-loop for p in promises for i from 0 do
               (let ((i i))
                 (harness-then (if (harness-promise-p p) p (harness-resolved p))
                               (lambda (v)
                                 (aset values i v)
                                 (when (zerop (cl-decf remaining))
                                   (harness-resolve result (append values nil)))
                                 nil)
                               (lambda (e) (harness-reject result e) nil)))))
    result))

(defmacro harness-with-promise (bindings &rest body)
  "Run BODY with (RESOLVE REJECT) from BINDINGS bound to settle a new promise.
An error signalled by BODY rejects the promise.  Return the promise."
  (declare (indent 1))
  (let ((p (make-symbol "promise")))
    `(let ((,p (harness-make-promise)))
       (let ((,(car bindings) (lambda (v) (harness-resolve ,p v) nil))
             (,(cadr bindings) (lambda (e) (harness-reject ,p e) nil)))
         (ignore ,(car bindings) ,(cadr bindings))
         (condition-case err
             (progn ,@body)
           (error (harness-reject ,p err))))
       ,p)))

(defun harness-await (promise &optional timeout)
  "Block until PROMISE settles, return its value or signal its error.
Waits at most TIMEOUT seconds (default 30).  This spins the event loop
and is meant for tests and batch use, never for interactive code paths."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (not (harness-promise-settled-p promise))
                (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (unless (harness-promise-settled-p promise)
        (sit-for 0.01)))
    (pcase (harness-promise-state promise)
      ('resolved (harness-promise-value promise))
      ('rejected (let ((e (harness-promise-value promise)))
                   (if (and (consp e) (symbolp (car e)) (get (car e) 'error-conditions))
                       (signal (car e) (cdr e))
                     (signal 'harness-error (list e)))))
      (_ (signal 'harness-error (list "timed out waiting for promise"))))))

(defun harness-as-promise (value)
  "Return VALUE if it is a promise, else a promise resolved with it."
  (if (harness-promise-p value) value (harness-resolved value)))

;;;; Scheduling helpers

(defun harness-run-soon (fn &rest args)
  "Call FN with ARGS from the command loop as soon as possible.
Use this to escape the dynamic extent of a process filter or a
subscriber, or to keep an emitter non-reentrant."
  (apply #'run-at-time 0 nil fn args))

(defvar harness--debounce-timers (make-hash-table :test 'equal))

(defun harness-debounce (key delay fn &rest args)
  "Call FN with ARGS after DELAY seconds of no further calls with KEY."
  (let ((timer (gethash key harness--debounce-timers)))
    (when timer (cancel-timer timer))
    (puthash key
             (apply #'run-at-time delay nil
                    (lambda (&rest a)
                      (remhash key harness--debounce-timers)
                      (apply fn a))
                    args)
             harness--debounce-timers)))

;;;; Methods

(cl-defstruct (harness-method (:copier nil))
  name fn doc module params)

(defvar harness--methods (make-hash-table :test 'eq)
  "Registered methods, keyed by symbol.")

(cl-defun harness-register-method (name fn &key doc module params)
  "Register FN as the implementation of method NAME.
DOC describes it, MODULE names the owning module, PARAMS documents the
argument plist keys.  Registering again replaces the previous
implementation (this is what makes hot reloading safe)."
  (unless (symbolp name) (error "Method name must be a symbol: %S" name))
  (puthash name (make-harness-method :name name :fn fn :doc doc
                                     :module module :params params)
           harness--methods)
  name)

(defun harness-unregister-method (name)
  "Forget method NAME."
  (remhash name harness--methods))

(defun harness-method-exists-p (name)
  "Non-nil when a method NAME is registered."
  (and (gethash name harness--methods) t))

(defun harness-call (name &rest args)
  "Call method NAME with ARGS and return its result.
Signals `harness-no-such-method' when nothing implements NAME."
  (let ((m (gethash name harness--methods)))
    (unless m (signal 'harness-no-such-method (list name)))
    (apply (harness-method-fn m) args)))

(defun harness-call-async (name &rest args)
  "Call method NAME with ARGS and always return a promise.
Synchronous results and signalled errors are wrapped."
  (condition-case err
      (harness-as-promise (apply #'harness-call name args))
    (error (harness-rejected err))))

(defun harness-methods ()
  "Return a list of registered methods as plists, sorted by name."
  (let (out)
    (maphash (lambda (k m)
               (push (list :name k :doc (harness-method-doc m)
                           :module (harness-method-module m)
                           :params (harness-method-params m))
                     out))
             harness--methods)
    (sort out (lambda (a b) (string< (symbol-name (plist-get a :name))
                                     (symbol-name (plist-get b :name)))))))

(defmacro harness-defmethod (name arglist docstring &rest body)
  "Define a bus method NAME implemented by a function with ARGLIST and BODY.
Also defines the function `harness-method/NAME' so it can be called and
debugged like any other function.  DOCSTRING is the method's
documentation."
  (declare (indent defun) (doc-string 3))
  (let ((fname (intern (format "harness-method/%s" name)))
        (module (and (boundp 'harness--defining-module) harness--defining-module)))
    (ignore module)
    `(progn
       (defun ,fname ,arglist ,docstring ,@body)
       (harness-register-method ',name #',fname :doc ,docstring
                                :module (and (boundp 'harness--defining-module)
                                             harness--defining-module)))))

;;;; Events

(defvar harness--subscribers (make-hash-table :test 'eq)
  "Event symbol -> list of (PRIORITY . FN), sorted by priority.")

(defvar harness--known-events (make-hash-table :test 'eq)
  "Event symbol -> doc string, for introspection.")

(defun harness-declare-event (event doc)
  "Document EVENT with DOC so it shows up in `harness-events'."
  (puthash event doc harness--known-events))

(defun harness-on (event fn &optional priority)
  "Call FN whenever EVENT is emitted.  Return a handle for `harness-off'.
Lower PRIORITY runs first (default 50).  Subscribing the same FN to
the same EVENT twice is a no-op, so modules can subscribe with named
functions at load time and be reloaded safely.  Subscribe to `*' to
receive every event as (EVENT . ARGS)."
  (let* ((priority (or priority 50))
         (subs (gethash event harness--subscribers)))
    (unless (cl-find fn subs :key #'cdr :test #'equal)
      (puthash event
               (sort (cons (cons priority fn) subs) (lambda (a b) (< (car a) (car b))))
               harness--subscribers))
    (cons event fn)))

(defun harness-off (handle)
  "Cancel the subscription HANDLE returned by `harness-on'."
  (let ((event (car handle)) (fn (cdr handle)))
    (puthash event (cl-remove fn (gethash event harness--subscribers) :key #'cdr :test #'equal)
             harness--subscribers)))

(defun harness-emit (event &rest args)
  "Emit EVENT with ARGS to every subscriber.
Errors in subscribers are logged and do not propagate.  Return the
number of subscribers notified."
  (let ((n 0))
    (dolist (sub (gethash event harness--subscribers))
      (cl-incf n)
      (condition-case err
          (apply (cdr sub) args)
        (error (harness-log 'error "subscriber %S for %s failed: %S" (cdr sub) event err))))
    (dolist (sub (gethash '* harness--subscribers))
      (condition-case err
          (funcall (cdr sub) event args)
        (error (harness-log 'error "wildcard subscriber %S failed: %S" (cdr sub) err))))
    n))

(defun harness-emit-later (event &rest args)
  "Like `harness-emit' but from the command loop, after the caller returns."
  (apply #'harness-run-soon #'harness-emit event args))

(defun harness-events ()
  "Return the list of declared events as (EVENT . DOC)."
  (let (out)
    (maphash (lambda (k v) (push (cons k v) out)) harness--known-events)
    (sort out (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b)))))))

;;;; Filters

(defvar harness--filters (make-hash-table :test 'eq)
  "Filter name -> list of (PRIORITY . FN), sorted by priority.")

(defun harness-add-filter (name fn &optional priority)
  "Add FN to the filter chain NAME at PRIORITY (default 50, lower runs first).
Adding the same FN twice is a no-op."
  (let ((chain (gethash name harness--filters)))
    (unless (cl-find fn chain :key #'cdr :test #'equal)
      (puthash name (sort (cons (cons (or priority 50) fn) chain)
                          (lambda (a b) (< (car a) (car b))))
               harness--filters))
    (cons name fn)))

(defun harness-remove-filter (name fn)
  "Remove FN from the filter chain NAME."
  (puthash name (cl-remove fn (gethash name harness--filters) :key #'cdr :test #'equal)
           harness--filters))

(defun harness-run-filter (name value &rest args)
  "Pass VALUE through every function in filter chain NAME.
Each function is called as (FN VALUE . ARGS) and its return value
becomes the next VALUE.  A function that signals is skipped."
  (dolist (f (gethash name harness--filters) value)
    (condition-case err
        (setq value (apply (cdr f) value args))
      (error (harness-log 'error "filter %S in %s failed: %S" (cdr f) name err)))))

(defun harness-run-filter-async (name value &rest args)
  "Run the asynchronous filter chain NAME starting from VALUE.
Each function is called as (FN VALUE NEXT . ARGS) and must eventually
call NEXT with the new value (or return a promise of it, in which case
NEXT is called for it).  A function may stop the chain by calling NEXT
with a value whose `:final' property is non-nil.  Return a promise of
the final value."
  (let ((chain (gethash name harness--filters))
        (promise (harness-make-promise)))
    (cl-labels ((step (value rest)
                  (if (or (null rest)
                          (and (listp value) (plist-get value :final)))
                      (harness-resolve promise value)
                    (let* ((fn (cdar rest))
                           (called nil)
                           (next (lambda (v)
                                   (unless called
                                     (setq called t)
                                     (step v (cdr rest))))))
                      (condition-case err
                          (let ((ret (apply fn value next args)))
                            (when (and (harness-promise-p ret) (not called))
                              (harness-then ret next
                                            (lambda (e)
                                              (harness-log 'error "async filter %S rejected: %S" fn e)
                                              (funcall next value)))))
                        (error
                         (harness-log 'error "async filter %S in %s failed: %S" fn name err)
                         (funcall next value)))))))
      (step value chain))
    promise))

(defun harness-filters ()
  "Return the names of all filter chains that have handlers."
  (let (out) (maphash (lambda (k _) (push k out)) harness--filters) out))

;;;; Modules

(cl-defstruct (harness-module (:copier nil))
  name doc requires init-fn shutdown-fn file feature
  (state 'registered)   ; registered, ready, failed, disabled
  error)

(defvar harness--modules (make-hash-table :test 'eq)
  "Module name -> `harness-module'.")

(defvar harness--defining-module nil
  "Bound to the module name while its file is loading.")

(defvar harness--defining-file nil
  "Bound to the source file of the module loading, or nil.
The loader loads a compiled copy kept elsewhere (`load-file-name'), so
it names the source that the module `harness--defining-module' records
as its file.")

(defvar harness-module-init-hook nil
  "Hook run with the module name after each module initialises.")

(cl-defun harness-define-module (name &key doc requires init shutdown)
  "Register module NAME.
DOC describes it.  REQUIRES lists module names that must be ready
first.  INIT is called once when the harness starts (or when the module
is enabled later); SHUTDOWN when it stops.  Re-evaluating a definition
while the module is ready keeps it ready and just refreshes the
metadata, which is what a hot reload needs."
  (let ((existing (gethash name harness--modules))
        ;; Not a module another file defines as this one requires it.
        (file (if (and harness--defining-file (eq name harness--defining-module))
                  harness--defining-file
                load-file-name)))
    (if existing
        (setf (harness-module-doc existing) doc
              (harness-module-requires existing) requires
              (harness-module-init-fn existing) init
              (harness-module-shutdown-fn existing) shutdown
              (harness-module-file existing) (or file (harness-module-file existing)))
      (puthash name (make-harness-module :name name :doc doc :requires requires
                                         :init-fn init :shutdown-fn shutdown
                                         :file file
                                         :feature (intern (format "harness-%s" name)))
               harness--modules)))
  name)

(defun harness-module-get (name)
  "Return the module struct for NAME, or nil."
  (gethash name harness--modules))

(defun harness-module-ready-p (name)
  "Non-nil when module NAME is initialised."
  (let ((m (gethash name harness--modules)))
    (and m (eq (harness-module-state m) 'ready))))

(defun harness-modules ()
  "Return all registered modules, sorted by name."
  (let (out)
    (maphash (lambda (_ m) (push m out)) harness--modules)
    (sort out (lambda (a b) (string< (harness-module-name a) (harness-module-name b))))))

(defun harness--module-order (names)
  "Return NAMES topologically sorted by their requirements."
  (let (order visiting)
    (cl-labels ((visit (n)
                  (cond ((memq n order))
                        ((memq n visiting)
                         (harness-log 'warn "module dependency cycle at %s" n))
                        ((not (gethash n harness--modules))
                         (harness-log 'warn "module %s requires unknown module" n))
                        (t (push n visiting)
                           (dolist (r (harness-module-requires (gethash n harness--modules)))
                             (visit r))
                           (setq visiting (delq n visiting))
                           (push n order)))))
      (mapc #'visit names))
    (nreverse order)))

(defun harness-module-start (name)
  "Initialise module NAME if it is registered and not yet ready.
Return non-nil on success.  Failures are recorded on the module."
  (let ((m (gethash name harness--modules)))
    (cond ((null m) nil)
          ((eq (harness-module-state m) 'ready) t)
          ((cl-notevery #'harness-module-ready-p (harness-module-requires m))
           (setf (harness-module-state m) 'failed
                 (harness-module-error m)
                 (format "requirements not ready: %s"
                         (cl-remove-if #'harness-module-ready-p (harness-module-requires m))))
           (harness-log 'warn "module %s: %s" name (harness-module-error m))
           nil)
          (t (condition-case err
                 (progn
                   (when (harness-module-init-fn m) (funcall (harness-module-init-fn m)))
                   (setf (harness-module-state m) 'ready (harness-module-error m) nil)
                   (harness-log 'debug "module %s ready" name)
                   (run-hook-with-args 'harness-module-init-hook name)
                   t)
               (error
                (setf (harness-module-state m) 'failed (harness-module-error m) err)
                (harness-log 'error "module %s failed to initialise: %S" name err)
                nil))))))

(defun harness-modules-init (&optional names)
  "Initialise NAMES (default: every registered module) in dependency order.
Return the list of module names that are ready."
  (let ((names (or names (mapcar #'harness-module-name (harness-modules)))))
    (dolist (n (harness--module-order names))
      (harness-module-start n))
    (cl-remove-if-not #'harness-module-ready-p names)))

(defun harness-modules-shutdown ()
  "Shut down every ready module, dependents first."
  (dolist (n (reverse (harness--module-order (mapcar #'harness-module-name (harness-modules)))))
    (let ((m (gethash n harness--modules)))
      (when (eq (harness-module-state m) 'ready)
        (condition-case err
            (when (harness-module-shutdown-fn m) (funcall (harness-module-shutdown-fn m)))
          (error (harness-log 'error "module %s failed to shut down: %S" n err)))
        (setf (harness-module-state m) 'registered)))))

(defun harness-module-disable (name)
  "Mark module NAME disabled and shut it down if it was running."
  (let ((m (gethash name harness--modules)))
    (when m
      (when (and (eq (harness-module-state m) 'ready) (harness-module-shutdown-fn m))
        (ignore-errors (funcall (harness-module-shutdown-fn m))))
      (setf (harness-module-state m) 'disabled))))

(defun harness-module-descriptions ()
  "Describe every registered module, sorted by name.
Each description is (:name NAME :state STATE :doc DOC :file FILE
:error ERROR): FILE is the source the module was loaded from, or nil,
and ERROR says what failed it, or is nil."
  (mapcar (lambda (m)
            (let ((err (harness-module-error m)))
              (list :name (harness-module-name m)
                    :state (harness-module-state m)
                    :doc (harness-module-doc m)
                    :file (harness-module-file m)
                    :error (cond ((null err) nil)
                                 ((stringp err) err)
                                 (t (error-message-string err))))))
          (harness-modules)))

(defvar harness-describe-modules-functions nil
  "Functions adding the modules of another Emacs to `harness-describe-modules'.
Each is called with no argument and returns nil, or (TITLE . PROMISE):
PROMISE resolves to the modules to list under TITLE, described as
`harness-module-descriptions' describes them.  The UI adds the modules
of the harness it is connected to this way, when that harness runs in
another process.")

(defconst harness--modules-buffer-name "*harness-modules*"
  "Name of the buffer of `harness-describe-modules'.")

(defvar harness-directory)
(declare-function harness-error-message "harness-util" (err))

(defun harness--insert-modules (modules)
  "Insert a line for each of MODULES.
They are described as `harness-module-descriptions' describes them.  A
module from outside the harness's tree, such as one of
`harness-extra-module-directories', names its file on a line of its
own, and a failed one what failed it."
  (if (null modules)
      (insert "  none\n")
    (dolist (m modules)
      (let ((file (plist-get m :file))
            (err (plist-get m :error)))
        (insert (format "  %-22s %-10s %s\n" (plist-get m :name) (plist-get m :state)
                        (or (plist-get m :doc) "")))
        (when (and (stringp file)
                   (not (and (bound-and-true-p harness-directory)
                             (string-prefix-p (file-name-as-directory harness-directory) file))))
          (insert (format "  %-22s %-10s %s\n" "" "" (abbreviate-file-name file))))
        (when (and err (not (equal err "")))
          (insert (format "  %-22s %-10s error: %s\n" "" "" err)))))))

(defun harness--fill-modules (marker insert)
  "Call INSERT in place of the placeholder line at MARKER, if its buffer lives."
  (when (buffer-live-p (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char marker)
          (delete-region (point) (line-beginning-position 2))
          (funcall insert))))))

(defun harness-describe-modules ()
  "Describe every module and its state in a help buffer.
The modules of this Emacs come first.  When the harness runs in
another Emacs, its own process say, its modules follow as they arrive
\(see `harness-describe-modules-functions').  A module from outside the
harness's tree names the file it was loaded from."
  (interactive)
  (let ((others (delq nil (mapcar #'funcall harness-describe-modules-functions)))
        (slots nil))
    (with-help-window harness--modules-buffer-name
      (with-current-buffer standard-output
        (insert "Modules of this Emacs\n\n")
        (harness--insert-modules (harness-module-descriptions))
        (dolist (other others)
          (insert "\n" (car other) "\n\n")
          (push (cons (cdr other) (copy-marker (point))) slots)
          (insert "  …\n"))))
    (dolist (slot (nreverse slots))
      (let ((marker (cdr slot)))
        (harness-then (car slot)
                      (lambda (modules)
                        (harness--fill-modules marker (lambda () (harness--insert-modules modules)))
                        nil)
                      (lambda (err)
                        (harness--fill-modules
                         marker (lambda ()
                                  (insert (format "  They could not be listed: %s\n"
                                                  (harness-error-message err)))))
                        nil))))))

;;;; Introspection

(defun harness-describe-api ()
  "Return a plist describing the whole bus: methods, events and filters.
And modules, as `harness-module-descriptions' describes them."
  (list :methods (harness-methods)
        :events (mapcar (lambda (e) (list :name (car e) :doc (cdr e))) (harness-events))
        :filters (harness-filters)
        :modules (harness-module-descriptions)))

(provide 'harness-core)
;;; harness-core.el ends here
