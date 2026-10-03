;;; harness-tools-emacs.el --- Tools that look inside the running Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Read-only windows into the user's Emacs session so a model can help
;; drive it: the buffer list, a buffer's text, documentation and values
;; of symbols, and the tail of *Messages*.  Changing Emacs goes through
;; the elisp tool (tools-shell), which is an exec-class tool and so
;; asks for permission separately.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'help-fns)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-client-tools)

(harness-define-tool "emacs_buffers"
  :label "List buffers"
  :description "List the live buffers in the user's Emacs: name, major mode, modified flag (M), size and visited file."
  :schema '(:type "object"
            :properties (:filter (:type "string" :description "Only buffers whose name or file matches this regexp")
                         :all (:type "boolean" :description "Include hidden buffers (names starting with a space). Default false")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (when-let* ((filter (plist-get input :filter))) (format "/%s/" filter)))
  :handler (harness-tools-in-client "emacs_buffers"))

(harness-define-tool "emacs_buffer"
  :label "Read buffer"
  :description "Read the text of a live buffer with line numbers, optionally a range (offset is the 1-based first line, limit the number of lines)."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "Buffer name, exactly as emacs_buffers lists it")
                         :offset (:type "integer" :description "First line to return (1-based). Default 1")
                         :limit (:type "integer" :description "Maximum number of lines. Default: all"))
            :required ("name"))
  :kind 'read
  :coalescable t
  :subject (lambda (input)
             (when-let* ((name (plist-get input :name)))
               (let ((o (plist-get input :offset)) (l (plist-get input :limit)))
                 (format "%s%s" name
                         (cond ((and o l) (format ":%s-%s" o (+ o l -1))) (o (format ":%s-" o)) (t ""))))))
  :handler (harness-tools-in-client "emacs_buffer"))

(harness-define-tool "emacs_describe"
  :label "Describe symbol"
  :description "Describe an Emacs symbol: function signature and docstring, variable docstring and current value (truncated)."
  :schema '(:type "object"
            :properties (:symbol (:type "string" :description "The symbol name, e.g. find-file or fill-column"))
            :required ("symbol"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :symbol))
  :handler (harness-tools-in-client "emacs_describe"))

(harness-define-tool "emacs_messages"
  :label "Emacs messages"
  :description "Return the last lines of the *Messages* buffer (errors, warnings and messages Emacs showed the user)."
  :schema '(:type "object"
            :properties (:count (:type "integer" :description "Number of lines. Default 50")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (format "last %s lines" (or (plist-get input :count) harness-client-tools--messages-default)))
  :handler (harness-tools-in-client "emacs_messages"))

(harness-define-module 'tools-emacs
  :doc "List buffers, Read buffer, Describe symbol and Emacs messages: read-only tools into the running Emacs."
  :requires '(tools))

(provide 'harness-tools-emacs)
;;; harness-tools-emacs.el ends here
