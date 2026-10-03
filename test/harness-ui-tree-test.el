;;; harness-ui-tree-test.el --- Tests for the conversation tree  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-ui-default-position)

(defmacro harness-ui-tree-test-with (&rest body)
  "Load the state layer, ACP, the UI foundation and the tree, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent usage worktree acp ui ui-tree))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-ui--sessions)
     (let ((harness-provider-demo-delay 0.005)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (unwind-protect
           (progn ,@body)
         (dolist (b (harness-ui-tree--buffers)) (kill-buffer b))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-tree-test-request (method params)
  "Await METHOD with PARAMS over the UI connection."
  (harness-test-await (harness-ui-request method params)))

(defun harness-ui-tree-test-append (sid kind content)
  "Append a KIND node with CONTENT to SID; return its id."
  (plist-get (harness-ui-tree-test-request "_harness/session/append"
                                           (list :id sid :node (list :kind kind :content content)))
             :id))

(defun harness-ui-tree-test-rows ()
  "Return the node ids of the rows in the current tree buffer, top to bottom."
  (let (ids)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((n (get-text-property (point) 'harness-ui-tree-node)))
          (unless (get-text-property (point) 'harness-ui-tree-expansion)
            (push (plist-get n :id) ids)))
        (forward-line 1)))
    (nreverse ids)))

(defun harness-ui-tree-test-goto (id)
  "Move point to the row of node ID."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal id (plist-get (get-text-property (point) 'harness-ui-tree-node) :id))))
    (forward-line 1))
  (should-not (eobp)))

(ert-deftest harness-ui-tree-layout-lanes-and-joins ()
  (let* ((data (list :sessions (list (list :id "A" :name "main" :kind "main" :head "a3" :parent-id nil :fork-node nil)
                                     (list :id "B" :name "side" :kind "fork" :head "b1" :parent-id "A" :fork-node "a2"))
                     :nodes (list (list :id "a1" :session "A" :ts 1.0 :kind "user" :content "one")
                                  (list :id "a2" :session "A" :ts 2.0 :kind "assistant" :content "two")
                                  (list :id "b1" :session "B" :ts 3.0 :kind "user" :content "branch")
                                  (list :id "a3" :session "A" :ts 4.0 :kind "user" :content "three"))))
         (rows (harness-ui-tree--layout data))
         (ids (mapcar (lambda (r) (plist-get (plist-get r :node) :id)) rows))
         (row (lambda (id) (cl-find id rows :key (lambda (r) (plist-get (plist-get r :node) :id)) :test #'equal))))
    (should (equal '("a3" "b1" "a2" "a1") ids))
    (should (= 0 (plist-get (funcall row "a3") :lane)))
    (should (= 1 (plist-get (funcall row "b1") :lane)))
    (should (plist-get (funcall row "b1") :fork-start-p))
    (should (plist-get (funcall row "b1") :head-p))
    (should (plist-get (funcall row "a3") :head-p))
    (should-not (plist-get (funcall row "a2") :head-p))
    ;; B's lane joins A's at the fork node and is gone below it.
    (should (equal '((1 0)) (mapcar (lambda (j) (list (car j) (cadr j))) (plist-get (funcall row "a2") :joins))))
    (should (equal '(0) (mapcar #'car (plist-get (funcall row "a2") :after))))
    (should (= 2 (harness-ui-tree--lane-count rows)))
    ;; Text rails are drawn per lane.
    (let ((rails (harness-ui-tree--text-rails 2 (plist-get (funcall row "a2") :segments)
                                              (plist-get (funcall row "a2") :joins) 0 "#000" nil)))
      (should (string-match-p "● ╯" rails)))
    ;; A fork without nodes of its own gets a placeholder row above its fork node.
    (let* ((data2 (plist-put (copy-sequence data) :sessions
                             (append (plist-get data :sessions)
                                     (list (list :id "C" :name "empty" :kind "btw" :head "a3" :parent-id "A" :fork-node "a3")))))
           (ids2 (mapcar (lambda (r) (plist-get (plist-get r :node) :id)) (harness-ui-tree--layout data2))))
      (should (equal '("session:C" "a3" "b1" "a2" "a1") ids2)))
    ;; One started empty, like a BTW, has no fork node: its placeholder
    ;; sits where it was created, not below everything.
    (let* ((data3 (plist-put (copy-sequence data) :sessions
                             (append (plist-get data :sessions)
                                     (list (list :id "D" :name "btw" :kind "btw" :head nil :parent-id "A"
                                                 :fork-node nil :created 2.5)))))
           (rows3 (harness-ui-tree--layout data3))
           (ids3 (mapcar (lambda (r) (plist-get (plist-get r :node) :id)) rows3)))
      (should (equal '("a3" "b1" "session:D" "a2" "a1") ids3))
      (should (plist-get (cl-find "session:D" rows3 :key (lambda (r) (plist-get (plist-get r :node) :id))
                                  :test #'equal)
                         :fork-start-p)))))

(ert-deftest harness-ui-tree-buffer-rows-fork-and-checkout ()
  (harness-ui-tree-test-with
    (let* ((sid (plist-get (harness-ui-tree-test-request
                            "session/new" (list :cwd (harness-test-temp-dir) :_harness (list :model "demo:scripted" :name "Trunk")))
                           :sessionId))
           (n1 (harness-ui-tree-test-append sid "user" "first question"))
           (n2 (harness-ui-tree-test-append sid "assistant" "first answer\nwith a second line"))
           (child (harness-ui-tree-test-request "_harness/session/fork" (list :id sid :kind "fork" :name "Branch")))
           (cid (plist-get child :id))
           (b1 (harness-ui-tree-test-append cid "user" "branch question"))
           (n3 (harness-ui-tree-test-append sid "user" "trunk continues")))
      (should (equal n2 (plist-get child :fork-node)))
      ;; Full width, so the labels below are not truncated to a side window.
      (let ((harness-ui-default-position 'full))
        (harness-tree sid))
      (should (derived-mode-p 'harness-ui-tree-mode))
      (should (equal "*harness tree: Trunk*" (buffer-name)))
      (harness-test-wait (lambda () harness-ui-tree--data) 5 "tree data")
      ;; Every node has a row, newest first; both sessions are in the family.
      (should (equal (list n3 b1 n2 n1) (harness-ui-tree-test-rows)))
      (should (equal (sort (list sid cid) #'string<) (sort (copy-sequence harness-ui-tree--family) #'string<)))
      (let ((rows harness-ui-tree--rows))
        (should (= 4 (length rows)))
        (let ((branch (cl-find b1 rows :key (lambda (r) (plist-get (plist-get r :node) :id)) :test #'equal))
              (trunk (cl-find n3 rows :key (lambda (r) (plist-get (plist-get r :node) :id)) :test #'equal)))
          (should (plist-get branch :fork-start-p))
          (should (plist-get branch :head-p))
          (should (plist-get trunk :head-p))
          (should-not (= (plist-get branch :lane) (plist-get trunk :lane)))))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Branch" text))
        (should (string-match-p "first answer" text))
        (should-not (string-match-p "second line" text))
        (should (string-match-p "trunk continues" text))
        ;; Batch Emacs draws the text rails.
        (should (string-match-p "[●◉]" text)))
      ;; Node at point and expansion.
      (goto-char (point-min))
      (should (equal n3 (plist-get (harness-ui-tree-node-at-point) :id)))
      (harness-ui-tree-test-goto n2)
      (harness-ui-tree-toggle)
      (should (string-match-p "with a second line" (buffer-substring-no-properties (point-min) (point-max))))
      (harness-ui-tree-toggle)
      (should-not (string-match-p "with a second line" (buffer-substring-no-properties (point-min) (point-max))))
      ;; Lane navigation skips the other session's rows.
      (harness-ui-tree-test-goto n3)
      (harness-ui-tree-next-in-lane)
      (should (equal n2 (plist-get (harness-ui-tree-node-at-point) :id)))
      (harness-ui-tree-previous-in-lane)
      (should (equal n3 (plist-get (harness-ui-tree-node-at-point) :id)))
      ;; Checkout calls session/set-head with the node and moves the head.
      (let ((calls nil) (real (symbol-function 'harness-ui-call)))
        (harness-ui-tree-test-goto n1)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'harness-ui-call)
                   (lambda (method params cb &rest rest)
                     (if (equal method "_harness/session/set-head")
                         (progn (push (list method params) calls) (funcall cb nil))
                       (apply real method params cb rest)))))
          (harness-ui-tree-checkout))
        (should (equal (list (list "_harness/session/set-head" (list :id sid :node-id n1))) calls)))
      (harness-test-wait (lambda () (not harness-ui-tree--loading)) 5 "reloaded")
      (harness-ui-tree-test-goto n1)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (harness-ui-tree-checkout))
      (harness-test-wait (lambda () (equal n1 (plist-get (harness-call 'session/get sid) :head))) 5 "head moved")
      (harness-test-wait (lambda () (equal n1 (harness-ui-tree--head-of sid))) 5 "tree reloaded")
      ;; Live refresh: a node appended over ACP shows up without a manual reload.
      (let ((n4 (harness-ui-tree-test-append cid "assistant" "branch answer")))
        (harness-test-wait (lambda () (member n4 (harness-ui-tree-test-rows))) 5 "live row"))
      ;; Fork at a node that is not the head moves the head there, forks and restores it.
      (harness-ui-tree-test-goto n2)
      (let ((before (length (harness-call 'session/list))))
        (cl-letf (((symbol-function 'harness-ui-display-session) #'ignore))
          (harness-ui-tree-fork))
        (harness-test-wait (lambda () (> (length (harness-call 'session/list)) before)) 5 "fork created")
        (let ((fork (car (cl-remove-if-not (lambda (s) (and (equal (plist-get s :parent-id) sid)
                                                             (not (equal (plist-get s :id) cid))))
                                            (harness-call 'session/list)))))
          (should (equal n2 (plist-get fork :fork-node))))
        (harness-test-wait (lambda () (equal n1 (plist-get (harness-call 'session/get sid) :head))) 5 "head restored")))))

(ert-deftest harness-ui-tree-tells-denied-results-from-failed-ones ()
  ;; A result the permission system refused reads apart from a failure,
  ;; with the chat's icons: a yellow circle, a red triangle, and a green
  ;; circle for a call that ran.
  (harness-ui-tree-test-with
    (let ((denied '(:kind "tool-result" :output "Denied: the user said no" :is-error t :meta (:denied t)))
          (failed '(:kind "tool-result" :output "exit 1" :is-error t :meta (:denied nil)))
          (ok '(:kind "tool-result" :output "fine" :is-error :false)))
      (should (equal (concat (harness-ui-icon 'harness-icon-caution) " Denied: the user said no")
                     (harness-ui-tree--excerpt denied)))
      (should (equal (concat (harness-ui-icon 'harness-icon-failure) " exit 1") (harness-ui-tree--excerpt failed)))
      (should (equal (concat (harness-ui-icon 'harness-icon-success) " fine") (harness-ui-tree--excerpt ok)))
      (should (eq 'harness-caution-face (get-text-property 0 'face (harness-ui-tree--excerpt denied))))
      (should (eq 'harness-failure-face (get-text-property 0 'face (harness-ui-tree--excerpt failed))))
      (should (eq 'harness-success-face (get-text-property 0 'face (harness-ui-tree--excerpt ok))))
      (should (eq 'harness-caution-face (harness-ui-tree--excerpt-face denied)))
      (should (eq 'harness-failure-face (harness-ui-tree--excerpt-face failed)))
      (should (eq 'harness-dim-face (harness-ui-tree--excerpt-face ok)))
      (should (eq 'harness-tool-denied-face (get-text-property 0 'face (harness-ui-tree--expansion-text denied))))
      (should (eq 'harness-tool-error-face (get-text-property 0 'face (harness-ui-tree--expansion-text failed))))
      (should (eq 'harness-tool-face (get-text-property 0 'face (harness-ui-tree--expansion-text ok))))
      ;; Drawn in a row, the icon keeps its colour over the excerpt's face.
      (pcase-dolist (`(,result ,icon-face ,text-face) `((,denied harness-caution-face harness-caution-face)
                                                         (,failed harness-failure-face harness-failure-face)
                                                         (,ok harness-success-face harness-dim-face)))
        (let* ((data (list :sessions (list (list :id "A" :name "main" :kind "main" :head "a2"))
                           :nodes (list (list :id "a1" :session "A" :ts 1.0 :kind "tool-call"
                                              :tool "bash" :title "Bash: make")
                                        (append (list :id "a2" :session "A" :ts 2.0) result))))
               (row (car (harness-ui-tree--layout data))))
          (with-temp-buffer
            (harness-ui-tree--insert-row row 1 80)
            (goto-char (point-min))
            (should (search-forward (harness-ui-tree--excerpt result) nil t))
            (let ((start (match-beginning 0)))
              (should (eq icon-face (car (ensure-list (get-text-property start 'face)))))
              (should (eq text-face (car (ensure-list (get-text-property (+ start 2) 'face))))))))))))

(provide 'harness-ui-tree-test)
;;; harness-ui-tree-test.el ends here
