;;; bench-transcript-load.el --- Measure what reading a transcript costs  -*- lexical-binding: t; -*-
;;; Commentary:
;; Synthetic sessions, no real transcript, and only aggregate timings:
;;
;;  * the full `session/list' against the lean one both clients ask for;
;;  * the standard replay's updates against the harness's nodes alone;
;;  * finding session ids in a long message by regexp (what the chat did)
;;    against the hyphen scan it does now.
;;
;; Run it with scripts/analysis/bench-transcript-load.sh, which compiles a
;; copy of the sources and loads this file in a batch Emacs.  Nothing here
;; writes to the checkout or a state directory.
;;; Code:

(require 'harness-test-helpers)

;; The modules define the session struct the accessors below expand through.
;; They are loaded first, in a state directory of their own, as a test suite
;; does; the run at the end uses the same one.
(defvar bench-transcript--state
  (file-name-as-directory (make-temp-file "harness-bench-" t)))
(setq harness-state-directory bench-transcript--state)
(harness-test-reset-bus)
(dolist (module '(store project config provider session acp ui))
  (harness-test-load-module module))

(defun bench-transcript--ms (start)
  "Milliseconds since START, a `float-time'."
  (* 1000.0 (- (float-time) start)))

(defun bench-transcript--summarize (label times &optional extra)
  "Say the median, p95 and range of TIMES (milliseconds) under LABEL.
EXTRA is appended to the line."
  (let* ((sorted (sort (copy-sequence times) #'<))
         (n (length sorted))
         (median (nth (/ n 2) sorted))
         (p95 (nth (min (1- n) (floor (* n 0.95))) sorted)))
    (message "BENCH %-48s n=%d median=%8.2f ms p95=%8.2f ms min=%7.2f max=%7.2f%s"
             label n median p95 (car sorted) (car (last sorted))
             (or extra ""))))

(defmacro bench-transcript--measure (label reps &rest body)
  "Run BODY REPS times and report its time under LABEL."
  (declare (indent 2))
  `(let (times)
     (dotimes (_ ,reps)
       (let ((start (float-time)))
         ,@body
         (push (bench-transcript--ms start) times)))
     (bench-transcript--summarize ,label times)))

(defun bench-transcript--node (i size session)
  "Return synthetic node I of SIZE bytes for SESSION."
  (let* ((kind (pcase (% i 5) (0 'user) (1 'assistant) (2 'thinking) (3 'tool-call) (_ 'tool-result)))
         (text (make-string size (aref "abcdefghijklmnopqrstuvwxyz " (% i 27))))
         (call (format "call-%05d" i))
         (node (list :id (format "n-%05d" i)
                     :session session
                     :parent (and (> i 0) (format "n-%05d" (1- i)))
                     :ts (+ 1794000000 (* i 0.5))
                     :kind kind)))
    (pcase kind
      ((or 'user 'assistant 'thinking) (plist-put node :content text))
      ('tool-call (setq node (plist-put node :call-id call)
                        node (plist-put node :tool "read_file")
                        node (plist-put node :title (format "Read file %d" i))
                        node (plist-put node :input (list :path (format "/tmp/file-%d" i)))))
      ('tool-result (setq node (plist-put node :call-id (format "call-%05d" (1- i)))
                         node (plist-put node :tool "read_file")
                         node (plist-put node :title (format "Read file %d" (1- i)))
                         node (plist-put node :output text))))
    node))

(defun bench-transcript--session (id n size &optional provider-bytes)
  "Put a synthetic session ID with N nodes of SIZE into the session table.
PROVIDER-BYTES is the size of the provider conversation the session keeps."
  (let ((session (make-harness-session))
        (province (make-string (or provider-bytes 0) ?p)))
    (setf (harness-session-id session) id
          (harness-session-name session) (format "Synthetic %s" id)
          (harness-session-kind session) 'main
          (harness-session-project session) "/tmp/bench-project/"
          (harness-session-cwd session) "/tmp/bench-project/"
          (harness-session-model session) "demo:scripted"
          (harness-session-permission-mode session) 'ask
          (harness-session-status session) 'idle
          (harness-session-created session) 1794000000
          (harness-session-updated session) 1794000000
          (harness-session-usage session) '(:input-tokens 1000 :output-tokens 2000 :cost 0.12)
          (harness-session-nodes session) (make-hash-table :test 'equal)
          (harness-session-loaded session) t
          (harness-session-ext session) (list :recaps (make-string 2000 ?r))
          (harness-session-provider-state session)
          (and (> (length province) 0) (list :conversation province)))
    (dotimes (i n)
      (let ((node (bench-transcript--node i size id)))
        (puthash (plist-get node :id) node (harness-session-nodes session))
        (setf (harness-session-head session) (plist-get node :id))))
    (puthash id session harness-sessions)
    session))

(defun bench-transcript--standard-updates (nodes)
  "Return the updates the standard replay sends for NODES."
  (let (updates)
    (dolist (node nodes)
      (setq updates (nconc (harness-acp--node-updates node nil) updates)))
    (nreverse updates)))

(defun bench-transcript--nodes-alone (nodes)
  "Return the updates a replay of NODES alone sends."
  (mapcar (lambda (node)
            (list :sessionUpdate "_harness/node" :node node))
          nodes))

(defun bench-transcript--bytes (value)
  "Return how many bytes VALUE takes on the wire."
  (length (harness-json-encode value)))

(defun bench-transcript--texts (count size id)
  "Return COUNT messages of SIZE bytes, each naming session ID."
  (let ((tail (concat " See " id " for the rest.\n"))
        (filler "a line of prose with a - dash and a -- mark, nothing else.\n"))
    (let ((body (make-string (- size (length tail)) ?x)))
      (make-list count (concat body "\n" filler tail)))))

(defun bench-transcript--regexp-ids (text)
  "Find session ids in TEXT with the regexp the chat used before the scan."
  (let ((pos 0) (found 0))
    (while (string-match harness-ui--session-id-regexp text pos)
      (setq pos (match-end 0)
            found (1+ found)))
    found))

(defun bench-transcript--hyphen-ids (text)
  "Find how many hyphens a scan of TEXT has to look at."
  (let ((pos (string-search "-" text)) (found 0))
    (while pos
      (setq found (1+ found)
            pos (string-search "-" text (1+ pos))))
    found))

(unwind-protect
    (progn
  (clrhash harness-sessions)
  (setq default-directory (harness-test-temp-dir))
  ;; A home screen of many sessions, each with a provider conversation.
  (dotimes (i 200)
    (bench-transcript--session (format "bench-%03d" i) 0 0 40000))
  (let* ((full (harness-call 'session/list))
         (lean (harness-call 'session/list (list :lean t))))
    (message "BENCH sessions=%d full=%d bytes lean=%d bytes"
             (length full) (bench-transcript--bytes full) (bench-transcript--bytes lean))
    (bench-transcript--measure "session/list full, plists" 10
      (harness-call 'session/list))
    (bench-transcript--measure "session/list lean, plists" 10
      (harness-call 'session/list (list :lean t)))
    (bench-transcript--measure "session/list full, encode" 10
      (harness-json-encode (harness-call 'session/list)))
    (bench-transcript--measure "session/list lean, encode" 10
      (harness-json-encode (harness-call 'session/list (list :lean t)))))
  ;; A long transcript, and what a replay of it puts on the wire.
  (bench-transcript--session "bench-nodes" 400 5000)
  (let* ((nodes (harness-call 'session/nodes "bench-nodes"))
         (standard (bench-transcript--standard-updates nodes))
         (alone (bench-transcript--nodes-alone nodes)))
    (message "BENCH transcript nodes=%d standard-updates=%d alone-updates=%d standard=%d bytes alone=%d bytes"
             (length nodes) (length standard) (length alone)
             (bench-transcript--bytes standard) (bench-transcript--bytes alone))
    (bench-transcript--measure "replay: standard updates" 10
      (bench-transcript--standard-updates nodes))
    (bench-transcript--measure "replay: nodes alone" 10
      (bench-transcript--nodes-alone nodes)))
  ;; Finding session ids in long messages: the old regexp scan and the
  ;; hyphen scan the chat now uses.
  (let* ((id "6f2c1a90-0001-4000-8000-000000000001")
         (texts (bench-transcript--texts 400 5000 id)))
    (puthash id (list :id id) harness-ui--sessions)
    (bench-transcript--measure "session ids: regexp scan" 3
      (dolist (text texts) (bench-transcript--regexp-ids text)))
    (bench-transcript--measure "session ids: hyphen count" 3
      (dolist (text texts) (bench-transcript--hyphen-ids text)))
    (bench-transcript--measure "session ids: linkify (current)" 3
      (dolist (text texts) (harness-ui-link-session-ids (copy-sequence text)))))
  (ignore-errors (delete-directory bench-transcript--state t))))
;;; bench-transcript-load.el ends here
