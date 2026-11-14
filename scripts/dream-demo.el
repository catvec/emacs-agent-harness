;;; dream-demo.el --- Watch the Logseq dream synthesize knowledge  -*- lexical-binding: t; -*-
;;
;; A demo of automatic Logseq dreaming on a scratch graph:
;;
;;   scripts/dream-demo.sh
;;
;; It holds two threads of conversation, dreams, and prints what the pass
;; read, what it refused, what it wrote, the page it corrected, the index,
;; and what recovery the graph itself has.  The judge is stubbed with a
;; fixed answer, so the demo shows the pass itself, without a model call
;; and without touching a real graph.

(require 'cl-lib)


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


(defvar harness-workspace-knowledge-dream-report)


(defvar harness-workspace-knowledge-dream-catch-up)


(defconst dream-demo-reply
  '((:type text :delta "Noted.") (:type done :stop-reason end-turn)))


(defun dream-demo--wait-for (pred &optional timeout)
  "Wait for PRED, or give up after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.02) (sit-for 0.005))))


(defmacro dream-demo--with (&rest body)
  "Run BODY in a fresh workspace over a scratch graph."
  (declare (indent 0))
  `(harness-test-with-temp-state (harness-test-reset-bus)
				 (let
				     ((harness-provider-demo-script-override
				       (lambda (_request)
					 dream-demo-reply))
				      (harness-provider-demo--delay
				       0.002)
				      (harness-workspace-model
				       "demo:scripted")
				      (harness-workspace-permission-mode
				       'auto)
				      (harness-workspace-non-interactive
				       t)
				      (harness-naming-auto nil)
				      (harness-workspace-knowledge-dream
				       nil)
				      (harness-workspace-knowledge-dream-report
				       t)
				      (harness-workspace-knowledge-dream-catch-up
				       nil)
				      (harness-logseq-directory
				       (expand-file-name "graph/"
							 harness-state-directory))
				      (default-directory
				       harness-state-directory))
				   (setq harness-workspace--subscribed
					 nil)
				   (dolist
				       (module
					'(store project config
						provider provider-demo
						tools session agent
						acp logseq memory
						workspace-knowledge
						workspace-box
						workspace))
				     (harness-test-load-module module))
				   (clrhash harness-sessions)
				   (clrhash harness-agent--turns)
				   (clrhash harness-workspace--table)
				   (setq harness-workspace--loaded nil
					 harness-workspace-knowledge--subscribed
					 nil)
				   (clrhash
				    harness-workspace-knowledge--pages)
				   (clrhash
				    harness-workspace-knowledge--pending)
				   (clrhash
				    harness-workspace-knowledge--status-cache)
				   (clrhash
				    harness-workspace-knowledge--vectors)
				   (harness-add-filter
				    'permission/decide
				    (lambda (_details next &rest _)
				      (funcall next
					       (list :behavior 'allow)))
				    10)
				   (unwind-protect (progn ,@body)
				     (harness-call 'store/sqlite-close)))))


(defun dream-demo--say (id text)
  "Send TEXT to workspace ID and wait out the turn."
  (harness-call 'workspace/prompt id text)
  (let
      ((live
	(plist-get
	 (car (plist-get (harness-call 'workspace/get id) :threads))
	 :live)))
    (dream-demo--wait-for
     (lambda nil (not (harness-call 'agent/running live))) 30)))


(defun dream-demo--print-file (name)
  "Print page NAME of the demo graph."
  (princ
   (format "\n--- pages/%s.md ---\n%s" name
	   (or
	    (harness-read-file
	     (harness-logseq-page-file name harness-logseq-directory))
	    "(absent)\n"))))


(defun dream-demo--judge (plan)
  "Return a stub `harness-judge-ask' that answers PLAN."
  (lambda (&rest _)
    (harness-resolved (list :value plan :text "" :lookups 0))))


(defun dream-demo--kitchen nil
  "The plan's entry for the kitchen page."
  (list :page "Projects/Kitchen" :about "The kitchen renovation."
	:blocks
	(list
	 ;; The id names the block the user wrote: the statement is
	 ;; corrected in place, with its child kept.
	 (list :id "d1" :text "The grout is warm grey." :kind "fact"
	       :confidence "confirmed" :sources (list "c-1"))
	 (list :text "The tile colour is still undecided." :kind
	       "question" :confidence "unresolved" :sources
	       (list "c-2" "c-4")))))


(defun dream-demo--sister nil
  "The plan's entry for the person page."
  (list :page "People/Sister" :about "The user's sister." :blocks
	(list
	 (list :text "The sister's wedding is in June." :kind "fact"
	       :confidence "confirmed" :sources (list "c-3")))))


(defun dream-demo--refused nil
  "A page the plan names and a pass may not write: a thread's page."
  (list :page "Threads/The tile is matte." :blocks
	(list (list :text "Not knowledge." :sources (list "c-1")))))


(defun dream-demo--run nil
  "Hold a conversation, dream over it, and print what happened."
  (dream-demo--with
   (let* ((workspace (harness-call 'workspace/create
                                   :name "Studio"
                                   :root (expand-file-name "studio/" harness-state-directory)
                                   :model "demo:scripted"))
          (id (plist-get workspace :id))
          (plan (list :pages
                      (list (dream-demo--kitchen) (dream-demo--sister)
                            (dream-demo--refused)))))
     (princ "\n=== the conversation\n")
     (dolist (text '("The tile is matte." "The grout is warm grey."
                     "My sister's wedding is in June."
                     "The tile colour is still undecided."))
       (princ (format "  user: %s\n" text))
       (dream-demo--say id text))
     (princ (format "\nthreads: %S\n"
                    (mapcar (lambda (thread) (plist-get thread :title))
                            (plist-get (harness-call 'workspace/get id) :threads))))
     ;; A page the user wrote by hand, with a statement the sources
     ;; contradict: a pass corrects it in place, it does not replace it.
     (dream-demo--user-page id)
     (harness-call 'knowledge/dream-exclude id "Always ask twice.")
     (princ "\n=== what a pass would read (a dry run)\n")
     (let ((dry (harness-call 'knowledge/dream id (list :dry-run t))))
       (princ (format "  status %s, %d capture(s) waiting, %d duplicate(s)\n"
                      (plist-get dry :status) (plist-get dry :would-synthesize)
                      (plist-get dry :removed))))
     (princ "\n=== the dream\n")
     (require 'harness-judge)
     (cl-letf (((symbol-function 'harness-judge-ask) (dream-demo--judge plan)))
       (let ((report (harness-call 'knowledge/dream id)))
         (when (harness-promise-p report)
           (setq report (harness-await report 60)))
         (princ (format "  status %s, %d capture(s), %d page(s), %d refused\n"
                        (plist-get report :status) (plist-get report :sources)
                        (plist-get report :pages) (plist-get report :refused)))
         (dolist (reason (plist-get report :reasons))
           (princ (format "    refused: %s\n" reason)))))
     (dream-demo--print-file "Projects/Kitchen")
     (dream-demo--print-file "People/Sister")
     (dream-demo--print-file "Index/Studio")
     (princ "\n=== the index the brief carries\n")
     (princ (format "%s\n" (or (harness-call 'knowledge/index id) "(none)")))
     (princ "\n=== what the status says\n")
     (let ((status (harness-call 'knowledge/dream-status id)))
       (princ (format "  graph %s (%s), last %s, %d processed, %d waiting, %d out\n"
                      (plist-get status :graph-type) (plist-get status :adapter)
                      (plist-get (plist-get status :last) :status)
                      (plist-get status :processed) (plist-get status :remaining)
                      (plist-get status :rejected))))
     (princ "\n=== what recovery the graph has\n")
     (dream-demo--print-recovery (plist-get (harness-call 'knowledge/dream-status id)
                                            :recovery))
     (dream-demo--print-kept id))))

(defun dream-demo--user-page (id)
  "Write the page the user edited by hand, and print it."
  (let* ((file (harness-logseq-page-file "Projects/Kitchen" harness-logseq-directory)))
    (harness-ensure-directory (file-name-directory file))
    (harness-write-file-atomically
     file
     (concat "- The tile is matte.\n"
             "  workspace-id:: " id "\n"
             "  role:: note\n"
             "- The grout is a cold grey.\n"
             "  id:: d1\n"
             "  workspace-id:: " id "\n"
             "  role:: note\n"
             "  - Ask Stone Co about the sample.\n"
             "    id:: c1\n"))
    (princ "\n=== the page the user edited by hand\n")
    (dream-demo--print-file "Projects/Kitchen")))

(defun dream-demo--print-recovery (recovery)
  "Print what RECOVERY says a page could be brought back from."
  (princ (format "  git checkout: %s\n"
                 (or (plist-get recovery :git) "none")))
  (princ (format "  logseq/bak files: %d, newest %s\n"
                 (plist-get recovery :backups)
                 (or (plist-get recovery :backup-latest) "-")))
  (princ (format "  copies the pass kept: %s\n"
                 (if (plist-get recovery :kept) "yes" "none"))))

(defun dream-demo--print-kept (id)
  "Print that the pass kept no copy of what it changed."
  (let ((dir (expand-file-name (format "workspace-dreams/%s" id)
                               harness-state-directory)))
    (princ "\n=== what the pass kept\n")
    (princ (format "  %s\n"
                   (if (file-exists-p dir)
                       (format "%s (the run retention layer is back)" dir)
                     "nothing: the page is the record")))))

(defun dream-demo-main nil
  "Print what a dream does to a scratch graph."
  (dream-demo--run))

(provide 'dream-demo)

;;; dream-demo.el ends here
