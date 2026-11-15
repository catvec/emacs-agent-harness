;;; demo.el --- Show why a permission prompt is put to the user  -*- lexical-binding: t; -*-

;;; Commentary:

;; Prints the reason line every permission prompt carries, drawn by the
;; panel's own code, for each `:why' code the harness sends.  Three parts:
;;
;;   1. the twelve codes: what each says on the panel, the face its label
;;      wears, and the tooltip the person reads over it;
;;   2. the one code that is a safety judgment, next to the ones that are
;;      no judgment at all, so the two are told apart by sight;
;;   3. where the reason comes from: `harness-perms--why-of' on the
;;      decisions the chain really makes -- a judge denial, a judge that
;;      gave no verdict, an ask mode -- and the prompt a request with no
;;      reason at all draws.
;;
;; Run it with demo/permission-why/demo.sh.  It sends no model request,
;; asks no provider, sets no permission rule, installs no module and runs
;; no tool: it calls the reader of a verdict, the builder of a reason and
;; the panel's own insert function, and every path it prints is a
;; placeholder.

;;; Code:

(add-to-list 'load-path (expand-file-name "../.."
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp/modules"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp/ui"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))

(require 'harness-util)
(require 'harness-perms)
(require 'harness-ui)
(require 'harness-ui-pending)

(defconst demo-reasons
  '((judge-deny "it force pushes to the shared remote")
    (judge-timeout "it took longer than 30s")
    (judge-unavailable nil)
    (judge-unreadable "its answer held no verdict")
    (judge-failed "it failed: the provider refused the key")
    (judge-empty "it gave no answer")
    (judge-stopped "it stopped: max-tokens")
    (judge-asked "not mine to call")
    (mode nil)
    (access "/srv/notes is outside the allowed directories")
    (confirm nil)
    (away "the agent asked to run without asking"))
  "Each `:why' code, and the detail a prompt of that code may carry.")

(defun demo--record (why)
  "Return the permission record a panel is drawn from, carrying WHY."
  (list :id "p1" :kind "permission" :why why))

(defun demo--draw (r)
  "Draw R's reason line as the panel does, and return what it drew.
The value is (TEXT FACE DETAIL-FACE HELP): the lines the person sees,
the face the label wears, the face the detail under it wears, and the
tooltip over the label."
  (with-temp-buffer
    (harness-ui-pending--insert-why r)
    (let ((text (buffer-string))
          (label (plist-get (plist-get r :why) :label))
          (detail (plist-get (plist-get r :why) :detail))
          face detail-face help)
      (goto-char (point-min))
      (when (and label (search-forward (format "%s" label) nil t))
        (setq face (get-text-property (1- (point)) 'face)
              help (get-text-property (1- (point)) 'help-echo)))
      (goto-char (point-min))
      (when (and (stringp detail) (search-forward detail nil t))
        (setq detail-face (get-text-property (1- (point)) 'face)))
      (list text face detail-face help))))

(defun demo--show (label why)
  "Print LABEL and WHY as the panel draws it."
  (let* ((r (demo--record why))
         (drawn (demo--draw r))
         (text (car drawn))
         (face (nth 1 drawn))
         (detail-face (nth 2 drawn))
         (help (nth 3 drawn)))
    (princ (format "\n  %s\n" label))
    (if (string-empty-p text)
        (princ "    (no reason line: the request carries no :why)\n")
      (dolist (line (split-string text "\n" t))
        (princ (format "  |%s\n" line)))
      (princ (format "    label face:   %s\n" (or face "none")))
      (princ (format "    detail face:  %s\n" (or detail-face "none")))
      (princ (format "    tooltip:      %s\n" (or help "none")))
      (princ (format "    unsafe:       %s\n"
                     (if (harness-ui-pending--why-unsafe-p r) "yes" "no"))))))

(defun demo-codes ()
  "Part 1: every code, as the panel draws it."
  (princ "1. Every reason a prompt can carry, drawn by the panel's own code\n")
  (dolist (entry demo-reasons)
    (demo--show (format "%s" (car entry))
                (harness-perms--why (car entry) (cadr entry)))))

(defun demo-unsafe ()
  "Part 2: the one safety judgment, beside reasons that are no judgment."
  (princ "\n\n2. The one safety judgment, and the reasons that are none\n")
  (demo--show "judge-deny (the judge weighed the call and would deny it)"
              (harness-perms--why 'judge-deny "it force pushes to the shared remote"))
  (demo--show "judge-timeout (no verdict: nothing weighed the call)"
              (harness-perms--why 'judge-timeout "it took longer than 30s"))
  (demo--show "mode (nothing weighed the call; the mode asks)"
              (harness-perms--why 'mode))
  (princ "\n  Only judge-deny is unsafe.  A judge that timed out, failed, could\n")
  (princ "  not be asked, or answered in no shape the reader takes made no\n")
  (princ "  judgment on the call, and its line says so.\n"))

(defun demo-sources ()
  "Part 3: where a prompt's reason comes from, for the chain's decisions."
  (princ "\n\n3. Where the reason comes from\n")
  (dolist (entry
           (list (cons (list :behavior 'ask
                             :why (harness-perms--why 'judge-deny "it force pushes to the shared remote"))
                       "an interactive judge denial")
                 (cons (list :behavior 'ask :no-verdict "it took longer than 30s"
                             :no-verdict-code 'judge-timeout
                             :no-verdict-detail "it took longer than 30s")
                       "a judge that gave no verdict")
                 (cons (list :behavior 'ask) "an ask mode: no decision of its own")
                 (cons (list :behavior 'ask :no-verdict "no auto-mode judge could decide the call"
                             :no-verdict-code 'judge-unavailable)
                       "no judge could be asked")))
    (let* ((decision (car entry))
           (label (cdr entry))
           (why (harness-perms--why-of decision 'mode)))
      (princ (format "\n  %-42s -> %s\n" label (plist-get why :code)))
      (princ (format "  %-42s    %s\n" "" (plist-get why :label)))
      (when (plist-get why :detail)
        (princ (format "  %-42s    %s\n" "" (plist-get why :detail))))))
  ;; A request with no reason at all: a harness that sent none.
  (demo--show "a request from a harness that sends no :why" nil)
  ;; The detail is masked and cut where it is made.
  (let ((why (harness-perms--why 'judge-deny (make-string 500 ?x))))
    (princ (format "\n  a long detail is cut to %d characters: %d\n"
                   harness-perms--why-detail-chars (length (plist-get why :detail))))))

(defun demo-run ()
  "Run every part of the demo."
  (demo-codes)
  (demo-unsafe)
  (demo-sources))
(provide 'demo)
;;; demo.el ends here
