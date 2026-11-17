;;; bench-workspace-seed.el --- Write bench workspaces through the harness  -*- lexical-binding: t; -*-

;; Seed a running harness with BENCH_WORKSPACES workspaces of BENCH_THREADS
;; threads, over ACP, so the records are the harness's own and not fixtures
;; of a shape this bench guessed.  Run it through
;; `scripts/analysis/bench-workspace-phases.sh'; it needs BENCH_ADDRESS and
;; BENCH_TOKEN, and prints the counts it wrote.
;;
;; `workspace/create' takes a name and a root; the threads are added with
;; `workspace/update', which is what the workspace page does when it adds
;; one.  Aggregate counts only: the names are the bench's own.

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

(defun bench--env (name default)
  (let ((v (getenv name)))
    (if (and v (not (string-empty-p v))) (string-to-number v) default)))

(defconst bench-workspaces (bench--env "BENCH_WORKSPACES" 3))
(defconst bench-threads (bench--env "BENCH_THREADS" 8))

(defun bench--run ()
  (unless (and bench-address (not (string-empty-p bench-address)))
    (error "BENCH_ADDRESS is not set"))
  (let ((harness-acp-token bench-token)
        (conn (harness-acp-connect bench-address)))
    (unwind-protect
        (progn
          (when bench-token (harness-await (harness-acp-authenticate conn bench-token) 120))
          (harness-await (harness-acp-initialize conn nil) 120)
          (dotimes (w bench-workspaces)
            (let* ((name (format "Bench %d" w))
                   (created (harness-await
                             (harness-acp-request conn "_harness/workspace/create"
                                                  (list :name name
                                                        :root (format "/tmp/bench-%d/" w)))
                             120))
                   (id (plist-get created :id)))
              (dotimes (n bench-threads)
                (harness-await
                 (harness-acp-request conn "_harness/workspace/thread/create"
                                      (list :id id
                                            :title (format "Bench thread %d" n)))
                 120))))
          (let ((listed (harness-await
                         (harness-acp-request conn "_harness/workspace/list" nil) 120)))
            (princ (format "seeded workspaces %d\n" (length listed)))
            (princ (format "seeded threads    %d\n"
                           (cl-loop for w in listed
                                    sum (length (plist-get w :threads)))))))
      (harness-acp-close conn "bench"))))

(bench--run)
