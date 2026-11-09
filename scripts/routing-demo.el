;;; routing-demo.el --- Watch workspace routing decide  -*- lexical-binding: t; -*-
;;
;; A demo of workspace topic routing, with no model to place a message:
;;
;;   scripts/routing-demo.sh
;;
;; It builds a workspace, sends one turn per message, and prints for
;; each message what the ranker scored each thread and which thread it
;; chose.  The second run stubs an embedding model, so the paraphrase
;; is placed by meaning where the words alone would split it.

(require 'cl-lib)

;; The state the test helpers keep, as the workspace suite declares it.
(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-workspace--table)
(defvar harness-workspace-model)
(defvar harness-workspace-permission-mode)
(defvar harness-workspace-non-interactive)
(defvar harness-workspace--loaded)
(defvar harness-workspace--subscribed)
(defvar harness-logseq-directory)
(defvar harness-workspace-knowledge--pages)
(defvar harness-workspace-knowledge--pending)
(defvar harness-workspace-knowledge--status-cache)
(defvar harness-workspace-knowledge--vectors)
(defvar harness-workspace-knowledge--subscribed)
(defvar harness-workspace-knowledge-dream)
(defvar harness-workspace-knowledge-embedding-model)

(defconst routing-demo-reply
  '((:type text :delta "Noted.")
    (:type done :stop-reason end-turn)))

(defun routing-demo--embed (_model texts &optional _opts)
  "A stand-in embedding model: tile words and wedding words are far apart."
  (harness-resolved
   (list :vectors
         (mapcar (lambda (text)
                   (let ((text (downcase text)))
                     (cond
                      ((string-match-p "tile\\|grout\\|shade\\|matte\\|colour\\|warm" text)
                       (list 1.0 0.0 0.0))
                      ((string-match-p "wedding\\|sister\\|june" text)
                       (list 0.0 1.0 0.0))
                      (t (list 0.0 0.0 1.0)))))
                 texts)
         :usage (list :input 1))))

(defun routing-demo--wait-for (pred &optional timeout)
  "Wait for PRED, or give up after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (sit-for 0.005))))

(defmacro routing-demo--with (model &rest body)
  "Run BODY with a fresh workspace and MODEL as its embedding model."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-provider-demo-script-override (lambda (_request) routing-demo-reply))
           (harness-provider-demo--delay 0.002)
           (harness-workspace-model "demo:scripted")
           (harness-workspace-permission-mode 'auto)
           (harness-workspace-non-interactive t)
           (harness-naming-auto nil)
           (harness-workspace-knowledge-dream nil)
           (harness-workspace-knowledge-embedding-model ,model)
           (harness-logseq-directory (expand-file-name "graph/" harness-state-directory))
           (default-directory harness-state-directory))
       (setq harness-workspace--subscribed nil)
       (dolist (module '(store project config provider provider-demo tools session agent
                               acp logseq memory workspace-knowledge workspace-box workspace))
         (harness-test-load-module module))
       (clrhash harness-sessions)
       (clrhash harness-agent--turns)
       (clrhash harness-workspace--table)
       (setq harness-workspace--loaded nil
             harness-workspace-knowledge--subscribed nil)
       (clrhash harness-workspace-knowledge--pages)
       (clrhash harness-workspace-knowledge--pending)
       (clrhash harness-workspace-knowledge--status-cache)
       (clrhash harness-workspace-knowledge--vectors)
       (harness-add-filter 'permission/decide
                           (lambda (_details next &rest _)
                             (funcall next (list :behavior 'allow)))
                           10)
       (unwind-protect (progn ,@body)
         (harness-call 'store/sqlite-close)))))

(defun routing-demo--live (id)
  "Return the live episode of the thread of ID that was last written to."
  (plist-get (car (plist-get (harness-call 'workspace/get id) :threads)) :live))

(defun routing-demo--send (id text)
  "Send TEXT to workspace ID, wait out its turn, and print the route."
  (let* ((workspace (harness-call 'workspace/get id))
         (route (harness-workspace--route workspace text nil))
         (index (harness-workspace--route-index workspace))
         (scores (harness-workspace--route-scores
                  index text (plist-get workspace :threads)))
         (ranked (or (harness-workspace--router-meaning index text scores)
                     scores)))
    (princ (format "\n%s\n" text))
    (dolist (pair ranked)
      (princ (format "    %-38s %.3f\n"
                     (plist-get (car pair) :title) (cdr pair))))
    (princ (format "  => %s  %s/%s\n"
                   (or (and (car route) (plist-get (car route) :title))
                       "(a new thread)")
                   (cadr route) (nth 2 route))))
  (harness-call 'workspace/prompt id text)
  (when-let* ((live (routing-demo--live id)))
    (routing-demo--wait-for (lambda () (not (harness-call 'agent/running live))) 30)))

(defun routing-demo--run (label model)
  "Print LABEL, then route a conversation with MODEL as the embedding stub."
  (princ (format "\n=== %s\n" label))
  (routing-demo--with model
    (let* ((workspace (harness-call 'workspace/create
                                    :name "Studio"
                                    :root (expand-file-name "studio/" harness-state-directory)
                                    :model "demo:scripted"))
           (id (plist-get workspace :id)))
      (dolist (text '("The tile is matte."
                      "And the grout is warm grey."
                      "My sister's wedding is in June."
                      "The tile colour is still undecided."
                      "What about the wedding?"))
        (routing-demo--send id text))
      (princ (format "\nthreads: %S\n"
                     (mapcar (lambda (thread) (plist-get thread :title))
                             (plist-get (harness-call 'workspace/get id) :threads)))))))

(defun routing-demo-main ()
  "Print what the ranker decides, with words alone and with meaning."
  (routing-demo--run "words alone" nil)
  (routing-demo--run "words, and a paraphrase placed by meaning" "demo:embed"))

;;; routing-demo.el ends here
