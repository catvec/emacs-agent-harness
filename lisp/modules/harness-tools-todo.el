;;; harness-tools-todo.el --- The todo_write tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; `todo_write' replaces the session's todo list, which the session
;; shows: its items pending, in progress or done.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-tools)

(defun harness-tools-todo--status (value)
  "Return VALUE as one of the symbols pending, in-progress or done."
  (let ((s (downcase (format "%s" (or value "pending")))))
    (cond ((member s '("done" "completed" "complete")) 'done)
          ((member s '("in-progress" "in_progress" "in progress" "active" "doing")) 'in-progress)
          (t 'pending))))

(defun harness-tools-todo--normalise (item index)
  "Return todo ITEM (a plist or a string) as (:id :text :status); INDEX numbers it."
  (if (stringp item)
      (list :id (format "t%d" index) :text item :status 'pending)
    (list :id (format "%s" (or (plist-get item :id) (format "t%d" index)))
          :text (or (plist-get item :text) (plist-get item :content) "")
          :status (harness-tools-todo--status (plist-get item :status)))))

(defun harness-tools-todo--render (todos)
  "Return a compact rendering of TODOS with counts."
  (let ((done 0) (active 0) (pending 0))
    (dolist (todo todos)
      (pcase (plist-get todo :status)
        ('done (cl-incf done))
        ('in-progress (cl-incf active))
        (_ (cl-incf pending))))
    (concat
     (mapconcat (lambda (todo)
                  (format "%s %s"
                          (pcase (plist-get todo :status)
                            ('done "[x]") ('in-progress "[~]") (_ "[ ]"))
                          (plist-get todo :text)))
                todos "\n")
     (if todos "\n" "")
     (format "%d todos: %d done, %d in progress, %d pending"
             (length todos) done active pending))))

(defun harness-tools-todo--write (input ctx)
  "Handler of the todo_write tool.
Replace the todos of the session in CTX with those in INPUT."
  (let* ((raw (plist-get input :todos))
         (todos (cl-loop for item in raw for i from 1
                         collect (harness-tools-todo--normalise item i))))
    (harness-call 'session/set-todos (plist-get ctx :session-id) todos)
    (harness-tool-ok (harness-tools-todo--render todos))))

(harness-define-tool "todo_write"
  :label "Todo list"
  :description "Replace the session's todo list. Each item has id, text and status (pending, in-progress or done); plain strings are accepted as pending items. Keep exactly one item in progress at a time and mark items done as soon as they are."
  :schema '(:type "object"
            :properties (:todos (:type "array"
                                 :items (:type "object"
                                         :properties (:id (:type "string")
                                                      :text (:type "string")
                                                      :status (:type "string" :enum ("pending" "in-progress" "done")))
                                         :required ("text"))))
            :required ("todos"))
  :kind 'meta
  :coalescable t
  :subject (lambda (input) (let ((n (length (plist-get input :todos))))
                             (format "%d item%s" n (if (= n 1) "" "s"))))
  :handler #'harness-tools-todo--write)

(harness-define-module 'tools-todo
  :doc "The Todo list tool (todo_write): the session's todo list."
  :requires '(tools session))

(provide 'harness-tools-todo)
;;; harness-tools-todo.el ends here
