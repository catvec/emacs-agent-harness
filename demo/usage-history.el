;;; usage-history.el --- Synthetic historical usage walkthrough -*- lexical-binding: t; -*-

;;; Commentary:
;; Loaded in a dedicated scripts/dev.sh harness, never the user's state.
;; Entry point: scripts/usage-history-demo.sh.  No model requests or real logs.

;;; Code:

(require 'harness-ui-usage-history)
(defvar harness-dev-frame)

(defun harness-usage-history-demo (&optional root)
  "Seed synthetic history in the development harness and show the view.
ROOT is the demo repository with a linked worktree, made by the script."
  (interactive)
  (let* ((root (file-name-as-directory (or root (expand-file-name "scripts/.dev/history-demo/project"))))
         (workspace (expand-file-name "../workspace/" root))
         (rates '(:input 2.0 :output 10.0 :cache-read 0.2 :cache-write 2.5))
         (now (float-time))
         (rows (cl-loop
                for id from 1
                for item in (list
                             (list root "openai:example" "inclusive" "not-reported"
                                   '(:input 1000000 :cache-read 950000 :output 20000) "api" "observed" 0.48)
                             (list workspace "claude:example" "exclusive" "reported"
                                   '(:input 20000 :cache-read 600000 :cache-write 70000 :output 10000) "extra-usage" "observed" 0.435)
                             (list root "openai:example" "inclusive" "not-reported"
                                   '(:input 900000 :cache-read 890000 :output 25000) "api" "observed" 0.448)
                             (list workspace "claude:example" "exclusive" "reported"
                                   '(:input 12000 :cache-read 800000 :cache-write 20000 :output 12000) "subscription" "subscription" nil)
                             (list root "openai:example" "unknown" "not-reported"
                                   '(:input 300000 :output 18000) "api" "unknown" nil))
                collect (let* ((ts (- now (* (- 6 id) 86400)))
                               (usage (nth 4 item)))
                          (append (list :session (format "history-demo-%d" id) :project (nth 0 item)
                                        :model (nth 1 item) :ts ts :billing (nth 5 item) :cost (or (nth 7 item) 0.0)
                                        :details (list :version 1 :usage usage :input-semantics (nth 2 item)
                                                       :cache-write-status (nth 3 item) :cost-source (nth 6 item)
                                                       :observed-cost (nth 7 item) :pricing rates :priced-at ts :currency "USD"))
                                  usage)))))
    (harness-ui-call
     "_harness/usage/totals" '(:session "history-demo-1")
     (lambda (totals)
       (harness-then
        (if (> (or (plist-get totals :calls) 0) 0) (harness-resolved nil)
          (harness-all (mapcar (lambda (row) (harness-ui-request "_harness/usage/record" (list :row row))) rows)))
        (lambda (_)
          (with-selected-frame (if (and (boundp 'harness-dev-frame) (frame-live-p harness-dev-frame))
                                   harness-dev-frame (selected-frame))
            ;; One display operation: opening in the default side position
            ;; before moving to full would leave two windows of the view.
            (let ((buffer (get-buffer-create harness-ui-usage-history--buffer)))
              (with-current-buffer buffer
                (unless (derived-mode-p 'harness-ui-usage-history-mode)
                  (harness-ui-usage-history-mode))
                (setq harness-ui-usage-history--group 'overall
                      harness-ui-usage-history--selected nil)
                (harness-ui-usage-history-set-period 'all))
              (harness-ui-display-view buffer 'full))
            (when (and (boundp 'harness-dev-frame) (frame-live-p harness-dev-frame))
              (set-frame-size harness-dev-frame 144 56)))))))))

(provide 'usage-history-demo)
;;; usage-history.el ends here
