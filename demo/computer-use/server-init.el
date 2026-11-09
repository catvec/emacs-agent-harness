;;; server-init.el --- script the computer-use demo's tool calls  -*- lexical-binding: t; -*-

;; Loaded by the harness process of the computer-use demo, after its
;; forwarded configuration (`harness-server-init-file').  The demo provider
;; runs the tools for real: the calls below go over the computer endpoint to
;; the private display, and their screenshots come back into the transcript.

(require 'cl-lib)

(declare-function harness-provider-demo--last-user-text "harness-provider-demo" (request))

(defvar computer-use-demo-marker "computer use demo"
  "The words of the prompt that start the scripted calls.")

(defvar computer-use-demo-started nil
  "Non-nil once the scripted calls were given for the demo session.")

(defconst computer-use-demo--other-prompts
  '("You write short titles" "You keep the todo list" "You are the search box"
    "You write the Insights report" "You decide how one session should start"
    "You explain one blocked tool call")
  "The openings of the harness's own prompts, which are not the demo turn.")

(defun computer-use-demo--main-request-p (request)
  "Non-nil when REQUEST is the demo session's first computer-use turn."
  (let ((model (plist-get (plist-get request :session) :model))
        (system (or (plist-get request :system) "")))
    (and (equal model "demo:scripted")
         (not computer-use-demo-started)
         (not (plist-get request :cache-refresh))
         (not (cl-some (lambda (opening) (string-prefix-p opening system))
                       computer-use-demo--other-prompts))
         (string-match-p computer-use-demo-marker
                         (harness-provider-demo--last-user-text request)))))

(defun computer-use-demo-script (request)
  "Return the events of REQUEST: the demo's calls, or the demo provider's.
Only the demo session's first computer-use turn is scripted; every other
request gets the demo provider's own answer."
  (if (computer-use-demo--main-request-p request)
      (progn
        (setq computer-use-demo-started t)
        `((:type text :delta "Using the local computer's desktop with the computer tools.\n")
          (:type tool-call :id "cu-list" :name "computer_list" :input nil)
          (:type tool-call :id "cu-view-1" :name "computer_view" :input nil)
          (:type tool-call :id "cu-windows" :name "computer_windows" :input nil)
          (:type tool-call :id "cu-move" :name "computer_pointer"
           :input (:action "move" :x 640 :y 348))
          (:type tool-call :id "cu-click" :name "computer_pointer"
           :input (:action "click" :x 640 :y 348 :button 1))
          (:type tool-call :id "cu-type" :name "computer_keyboard"
           :input (:action "type" :text "Noah"))
          (:type tool-call :id "cu-view-2" :name "computer_view" :input nil)
          (:type tool-call :id "cu-move-button" :name "computer_pointer"
           :input (:action "move" :x 332 :y 425))
          (:type tool-call :id "cu-click-button" :name "computer_pointer"
           :input (:action "click" :x 332 :y 425 :button 1))
          (:type tool-call :id "cu-view-3" :name "computer_view" :input nil)
          (:type text :delta "\nThe screen now says **Hello, Noah.**\n")
          (:type done :stop-reason end-turn)))
    `((:type text :delta "ok")
      (:type done :stop-reason end-turn))))

;; The module is loaded after this file, and its `defvar' keeps this value.
(setq harness-provider-demo-script-override #'computer-use-demo-script)

(provide 'computer-use-demo-server-init)
;;; server-init.el ends here
