;;; bench-workspace-phases.el --- Where a client's workspace list waits  -*- lexical-binding: t; -*-

;; Time each phase of a client that connects to a running harness and asks
;; for its workspaces, the way the UI's `harness-workspace' does.  Run it
;; through `scripts/analysis/bench-workspace-phases.sh', which starts the
;; throwaway harness, so the numbers are of one run and not of a machine
;; that already has work in it.
;;
;; What each line measures, and what it does not:
;;
;;   connect      from before `harness-acp-connect' to the connection
;;                object it returns.  A TCP connection is opened in the
;;                background, so this is the cost of making the object,
;;                not of the socket being up; the first request's own
;;                line includes whatever it waited for the socket.
;;   authenticate `harness-acp-connect' authenticates by itself when it
;;                has a token, and this then authenticates a second time
;;                on purpose: the line is that second round trip, and the
;;                first one is inside `connect'.
;;   initialize   the ACP handshake, answered.
;;   sessions     `session/list' (lean), answered.
;;   workspace    `workspace/list', answered: the request the selector
;;                makes.
;;   total        every phase above, summed from before `connect'.
;;
;; Each phase starts its clock after the request object is built, and
;; waits with `harness-await', which spins the event loop.  The times are
;; therefore round-trip and queue time, not the cost of building a
;; request; the per-phase lines do not add up to `total' for that reason.
;;
;; Aggregate seconds and counts only: no workspace name, thread or
;; transcript.
;;
;;   BENCH_ROOT=<checkout> BENCH_ADDRESS=HOST:PORT BENCH_TOKEN=... \
;;     emacs -Q --batch -l scripts/analysis/bench-workspace-phases.el

(defconst bench-root (file-name-as-directory (or (getenv "BENCH_ROOT") default-directory)))
(dolist (dir '("lisp" "lisp/modules" "lisp/ui" "lisp/vendor/worktree-assume"
               "lisp/vendor/change-review" "lisp/vendor/compose-quote"))
  (add-to-list 'load-path (expand-file-name dir bench-root)))
(add-to-list 'load-path bench-root)

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-acp)

(defconst bench-address (getenv "BENCH_ADDRESS"))
(defconst bench-token (getenv "BENCH_TOKEN"))

(defun bench--say (label seconds)
  (princ (format "%-14s %8.3fs\n" label seconds)))

(defun bench--settle (promise)
  "Wait for PROMISE, returning (VALUE . SECONDS)."
  (let ((t0 (float-time)))
    (cons (harness-await promise 120) (- (float-time) t0))))

(defun bench--run ()
  (unless (and bench-address (not (string-empty-p bench-address)))
    (error "BENCH_ADDRESS is not set"))
  (let* ((t0 (float-time))
         (harness-acp-token bench-token)
         (conn (harness-acp-connect bench-address))
         (connected (- (float-time) t0)))
    (bench--say "connect" connected)
    (when bench-token
      (let ((r (bench--settle (harness-acp-authenticate conn bench-token))))
        (bench--say "authenticate" (cdr r))))
    (let ((r (bench--settle (harness-acp-initialize conn nil))))
      (bench--say "initialize" (cdr r)))
    (let ((r (bench--settle (harness-acp-request conn "_harness/session/list"
                                                 (list :filter (list :lean t))))))
      (bench--say "sessions" (cdr r))
      (princ (format "%-14s %d\n" "session count" (length (car r)))))
    (let ((r (bench--settle (harness-acp-request conn "_harness/workspace/list" nil))))
      (bench--say "workspace" (cdr r))
      (princ (format "%-14s %d\n" "workspace count" (length (car r)))))
    (bench--say "total" (- (float-time) t0))
    (harness-acp-close conn "bench")))

(bench--run)
