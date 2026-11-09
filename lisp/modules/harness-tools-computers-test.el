;;; harness-tools-computers-test.el --- Tests for the computer tools  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; The computer tools (harness-tools-computers.el) with the computers
;; module, but no MCP transport: a computer's answer is a result the
;; test gives, so what each tool sends and what it says of the answer is
;; what is tried.  The permission chain is not in these calls; the gate
;; has its own suite (harness-computers-test.el).

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-acp--server-enabled nil)
(defvar harness-computers--computers)
(defvar harness-computers--client-info)
(defvar harness-computers--client-binding)
(defvar harness-computers--loaded)
(defvar harness-tools)
(declare-function harness-computers--load "harness-computers" ())
(declare-function harness-computers--local-record "harness-computers" ())
(declare-function harness-computers-get "harness-computers" (id-or-name))
(declare-function harness-computers-access "harness-computers" (session-id))
(declare-function harness-tools-computers--system-prompt "harness-tools-computers" (prompt session))
(declare-function harness-tool-get "harness-tools" (name))
(declare-function harness-tool-handler "harness-tools" (tool))
(declare-function harness-computer-endpoint--base64 "harness-computer-endpoint" (bytes))

(defconst harness-tools-computers-test-modules
  '(store project config provider provider-demo tools session agent tools-agent perms readonly mcp acp
    computers tools-computers)
  "The modules every test loads.")

(defconst harness-tools-computers-test-png
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  "One 1x1 PNG, base64, as a computer sends a capture.")

(defun harness-tools-computers-test--reset ()
  "Forget every computer an earlier test made, and load the store."
  (clrhash harness-computers--computers)
  (clrhash harness-computers--client-info)
  (clrhash harness-computers--client-binding)
  (setq harness-computers--loaded nil)
  (harness-computers--load))

(defmacro harness-tools-computers-test-with (&rest body)
  "Load the modules and a fresh registry, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (setq harness-acp--server-enabled nil)
     (when (boundp 'harness-tools) (clrhash harness-tools))
     (dolist (m harness-tools-computers-test-modules)
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (harness-tools-computers-test--reset)
     (let ((default-directory (harness-test-temp-dir)))
       ,@body)))

(defun harness-tools-computers-test-session (&rest plist)
  "Create a demo session with PLIST and return its id."
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                    :model "demo:scripted" :permission-mode 'yolo plist)
             :id))

(defun harness-tools-computers-test-record (id &rest props)
  "Put a connected computer ID with PROPS into the registry."
  (let ((record (append (list :id id :name id :kind 'client :state 'connected
                              :capabilities '("view" "windows" "pointer" "keyboard"
                                               "clipboard" "audio" "camera" "files" "exec")
                              :servers (list (list :name "computer" :title "Computer")))
                        props)))
    (puthash id record harness-computers--computers)
    record))

(defun harness-tools-computers-test-call (name input &optional ctx)
  "Call the tool NAME with INPUT in CTX and return its result, awaited."
  (let ((result (funcall (harness-tool-handler (harness-tool-get name)) input
                         (or ctx (list :session-id (harness-tools-computers-test-session))))))
    (if (harness-promise-p result) (harness-test-await result) result)))

(defun harness-tools-computers-test-check (computer &optional capability window input)
  "Return a passing check for a call on COMPUTER.
CAPABILITY, WINDOW and INPUT are what the tool needs."
  (list :ok t :id computer :computer (list :id computer :name computer)
        :capability capability :window window :input input))

(defmacro harness-tools-computers-test-stub (check result &rest body)
  "Run BODY with the check and the computer's answer stubbed.
CHECK is what `--check' returns; RESULT is the MCP result of the call."
  `(cl-letf (((symbol-function 'harness-tools-computers--check)
              (lambda (_ctx _input capability &optional window input-p)
                (ignore input-p)
                (append ,check (list :capability capability :window window))))
             ((symbol-function 'harness-computers-call)
              (lambda (_computer _tool _input &optional _server _ctx)
                (harness-resolved ,result))))
     ,@body))

;;;; computer_list

(ert-deftest harness-tools-computers-list-says-what-the-session-may-use ()
  "The list names each computer, its state, its capabilities and the
session's standing, and the projects across computers."
  (harness-tools-computers-test-with
    (harness-tools-computers-test-record
     "box" :resources (list (list :kind "git-repo" :name "app" :path "/srv/app" :branch "main")))
    (let* ((sid (harness-tools-computers-test-session :kind 'workspace))
           (result (harness-tools-computers-test-call "computer_list" nil (list :session-id sid)))
           (text (plist-get result :content)))
      (should-not (plist-get result :is-error))
      (should (string-match-p "Computers: 1" text))
      (should (string-match-p "box" text))
      (should (string-match-p "connected" text))
      (should (string-match-p "this session may use it (every computer)" text))
      (should (string-match-p
               "view, windows, pointer, keyboard, clipboard, audio, camera, files" text))
      (should (string-match-p "Projects:" text))
      (should (string-match-p "app · box · /srv/app" text))
      ;; A session that may not use it is told, with the way to ask.
      (let ((text (plist-get (harness-tools-computers-test-call
                              "computer_list" nil
                              (list :session-id (harness-tools-computers-test-session)))
                             :content)))
        (should (string-match-p "this session may not use it" text))
        (should (string-match-p "request_escalation" text))))))

(ert-deftest harness-tools-computers-list-works-with-no-computer ()
  "With no registered computer, the list says so and how one joins."
  (harness-tools-computers-test-with
    (let* ((sid (harness-tools-computers-test-session))
           (text (plist-get (harness-tools-computers-test-call
                             "computer_list" nil (list :session-id sid))
                            :content)))
      (should (string-match-p "Computers: 0" text))
      (should (string-match-p "No computer registered" text)))))

;;;; computer_view

(ert-deftest harness-tools-computers-view-writes-the-picture-and-shows-it ()
  "A capture is saved in the session's temporary directory, as an
attachment the chat shows and an image the provider reads."
  (harness-tools-computers-test-with
    (let* ((sid (harness-tools-computers-test-session))
           (ctx (list :session-id sid :call-id "call-1")))
      (harness-tools-computers-test-stub
          (harness-tools-computers-test-check "local" "view")
          (list :is-error nil :content ""
                :structured (list :data harness-tools-computers-test-png
                                  :mime "image/png" :width 1 :height 1
                                  :note "the window named"))
        (let ((result (harness-tools-computers-test-call
                       "computer_view" '(:window "win-1") ctx)))
          (should-not (plist-get result :is-error))
          (should (string-match-p "Screen of local" (plist-get result :content)))
          (should (string-match-p "the window named" (plist-get result :content)))
          (let* ((attachment (car (plist-get result :attachments)))
                 (path (plist-get attachment :path)))
            (should (file-exists-p path))
            (should (equal "image/png" (plist-get attachment :mime)))
            (should (equal (list (list :path path :mime "image/png"))
                           (plist-get result :images)))
            (should (equal "png" (file-name-extension path)))
            (should (equal path (plist-get (car (plist-get result :images)) :path)))))))))

(ert-deftest harness-tools-computers-view-refuses-a-capture-without-data ()
  "An empty answer is a tool error, not a broken attachment."
  (harness-tools-computers-test-with
    (harness-tools-computers-test-stub
        (harness-tools-computers-test-check "local" "view")
        (list :is-error nil :content "" :structured (list :mime "image/png"))
      (let ((result (harness-tools-computers-test-call "computer_view" nil)))
        (should (plist-get result :is-error))
        (should (string-match-p "no picture" (plist-get result :content)))))))

;;;; computer_camera

(ert-deftest harness-tools-computers-camera-writes-the-picture-and-shows-it ()
  "A camera picture is saved as an attachment, like a screen capture."
  (harness-tools-computers-test-with
    (let* ((sid (harness-tools-computers-test-session))
           (ctx (list :session-id sid :call-id "call-camera")))
      (harness-tools-computers-test-stub
          (harness-tools-computers-test-check "phone" "camera")
          (list :is-error nil :content ""
                :structured (list :data harness-tools-computers-test-png
                                  :mime "image/png" :width 1 :height 1))
        (let ((result (harness-tools-computers-test-call "computer_camera" nil ctx)))
          (should-not (plist-get result :is-error))
          (should (string-match-p "Camera of phone" (plist-get result :content)))
          (let* ((attachment (car (plist-get result :attachments)))
                 (path (plist-get attachment :path)))
            (should (file-exists-p path))
            (should (equal "image/png" (plist-get attachment :mime)))
            (should (equal (list (list :path path :mime "image/png"))
                           (plist-get result :images)))))))))

(ert-deftest harness-tools-computers-camera-refuses-a-picture-without-data ()
  "An empty camera answer is a tool error, not a broken attachment."
  (harness-tools-computers-test-with
    (harness-tools-computers-test-stub
        (harness-tools-computers-test-check "phone" "camera")
        (list :is-error nil :content "" :structured (list :mime "image/png"))
      (let ((result (harness-tools-computers-test-call "computer_camera" nil)))
        (should (plist-get result :is-error))
        (should (string-match-p "no picture" (plist-get result :content)))))))

;;;; computer_windows

(ert-deftest harness-tools-computers-windows-lists-what-the-computer-sees ()
  "The windows come back as lines naming each id, application, title,
rectangle and focus."
  (harness-tools-computers-test-with
    (harness-tools-computers-test-stub
        (harness-tools-computers-test-check "local" "windows")
        (list :is-error nil :content ""
              :structured (list :windows (list (list :id "w1" :app "Firefox" :name "Docs"
                                                      :rect '(10 20 800 600) :focused t))))
      (let ((text (plist-get (harness-tools-computers-test-call "computer_windows" nil) :content)))
        (should (string-match-p "Windows of local" text))
        (should (string-match-p "- w1 · Firefox · Docs · 800x600\\+10\\+20 · focused" text))))))

;;;; pointer, keyboard and clipboard

(ert-deftest harness-tools-computers-pointer-sends-the-action-and-says-what-it-did ()
  "The pointer call carries its action and coordinates, and the answer's done line."
  (harness-tools-computers-test-with
    (let ((sent nil))
      (harness-tools-computers-test-stub
          (harness-tools-computers-test-check "local" "pointer" "w1" t)
          (list :is-error nil :content "" :structured (list :done "moved the pointer to 10,20"))
        (let ((result (harness-tools-computers-test-call
                       "computer_pointer" '(:action "move" :x 10 :y 20 :window "w1"))))
          (should (equal "moved the pointer to 10,20 on local"
                         (plist-get result :content))))))))

(ert-deftest harness-tools-computers-keyboard-sends-text-and-keys ()
  "Typing and pressing a key both go through, and each says what it did."
  (harness-tools-computers-test-with
    (harness-tools-computers-test-stub
        (harness-tools-computers-test-check "local" "keyboard")
        (list :is-error nil :content "" :structured (list :done "typed 5 characters"))
      (should (equal "typed 5 characters on local"
                     (plist-get (harness-tools-computers-test-call
                                 "computer_keyboard" '(:action "type" :text "hello"))
                                :content))))
    (harness-tools-computers-test-stub
        (harness-tools-computers-test-check "local" "keyboard")
        (list :is-error nil :content "" :structured (list :done "pressed Return"))
      (should (equal "pressed Return on local"
                     (plist-get (harness-tools-computers-test-call
                                 "computer_keyboard" '(:action "key" :key "Return"))
                                :content))))))

(ert-deftest harness-tools-computers-clipboard-reads-and-writes ()
  "A get returns the clipboard's text; a set says what it put there."
  (harness-tools-computers-test-with
    (harness-tools-computers-test-stub
        (harness-tools-computers-test-check "local" "clipboard")
        (list :is-error nil :content "" :structured (list :text "from the desktop"))
      (should (equal "Clipboard of local:\nfrom the desktop"
                     (plist-get (harness-tools-computers-test-call
                                 "computer_clipboard" '(:action "get"))
                                :content))))
    (harness-tools-computers-test-stub
        (harness-tools-computers-test-check "local" "clipboard")
        (list :is-error nil :content "" :structured (list :done "put 3 characters on the clipboard"))
      (should (equal "put 3 characters on the clipboard on local"
                     (plist-get (harness-tools-computers-test-call
                                 "computer_clipboard" '(:action "set" :text "abc"))
                                :content))))))

(ert-deftest harness-tools-computers-a-computer-refusal-keeps-its-words ()
  "A tool error of the computer comes back as the tool's error, not as a success."
  (harness-tools-computers-test-with
    (harness-tools-computers-test-stub
        (harness-tools-computers-test-check "local" "pointer" nil t)
        (list :is-error t :content "The computer answers no such window")
      (let ((result (harness-tools-computers-test-call
                     "computer_pointer" '(:action "click"))))
        (should (plist-get result :is-error))
        (should (equal "The computer answers no such window" (plist-get result :content)))))))

;;;; computer_tools, computer_call and computer_use

(ert-deftest harness-tools-computers-tools-lists-the-extra-ones ()
  "The extra tools of a computer are listed with their descriptions."
  (harness-tools-computers-test-with
    (cl-letf (((symbol-function 'harness-tools-computers--check)
               (lambda (_ctx _input _capability &optional _window _input-p)
                 (harness-tools-computers-test-check "local")))
              ((symbol-function 'harness-computers-tools)
               (lambda (_computer &optional _server)
                 (harness-resolved (list :tools (list (list :name "screenshot-annotated"
                                                            :description "Capture with notes")))))))
      (let ((text (plist-get (harness-tools-computers-test-call "computer_tools" nil) :content)))
        (should (string-match-p "Tools of local" text))
        (should (string-match-p "screenshot-annotated · Capture with notes" text))))))

(ert-deftest harness-tools-computers-call-needs-a-tool ()
  "computer_call without a tool is refused before it touches the computer."
  (harness-tools-computers-test-with
    (let ((err (should-error (harness-tools-computers-test-call "computer_call" '(:arguments (:x 1)))
                             :type 'harness-error)))
      (should (string-match-p "needs tool" (harness-error-message err))))))

(ert-deftest harness-tools-computers-call-names-its-capability ()
  "computer_call checks the capability its input names, exec by default."
  (harness-tools-computers-test-with
    (let (seen)
      (cl-letf (((symbol-function 'harness-tools-computers--check)
                 (lambda (_ctx _input capability &optional _window _input-p)
                   (setq seen capability)
                   (harness-tools-computers-test-check
                    "phone" capability nil _input-p)))
                ((symbol-function 'harness-computers-call)
                 (lambda (_computer _tool _input &optional _server _ctx)
                   (harness-resolved (harness-tool-ok "done")))))
        (harness-tools-computers-test-call
         "computer_call"
         '(:tool "list_dir" :capability "files" :server "files")
         (list :session-id (harness-tools-computers-test-session)))
        (should (equal "files" seen))
        (harness-tools-computers-test-call
         "computer_call" '(:tool "run")
         (list :session-id (harness-tools-computers-test-session)))
        (should (equal "exec" seen))))))

(ert-deftest harness-tools-computers-use-sets-the-preference ()
  "computer_use makes a computer the session's default, and clearing it
leaves no preferred computer."
  (harness-tools-computers-test-with
    (harness-tools-computers-test-record "box")
    (let* ((sid (harness-tools-computers-test-session))
           (ctx (list :session-id sid)))
      (harness-computers-grant sid "box" nil nil 'user)
      (let ((result (harness-tools-computers-test-call "computer_use" '(:computer "box") ctx)))
        (should (string-match-p "This session uses" (plist-get result :content)))
        (should (equal "box" (plist-get (harness-computers-access sid) :preferred))))
      (let ((result (harness-tools-computers-test-call "computer_use" nil ctx)))
        (should (string-match-p "no preferred computer" (plist-get result :content)))
        (should-not (plist-get (harness-computers-access sid) :preferred))))))

(ert-deftest harness-tools-computers-use-refuses-a-computer-it-may-not-use ()
  "A computer the session may not use is not made its default."
  (harness-tools-computers-test-with
    (harness-tools-computers-test-record "box")
    (let ((err (should-error (harness-tools-computers-test-call
                              "computer_use" '(:computer "box")
                              (list :session-id (harness-tools-computers-test-session)))
                             :type 'harness-error)))
      (should (string-match-p "may not use the computer box" (harness-error-message err))))))

;;;; The specs and the system prompt

(ert-deftest harness-tools-computers-the-specs-say-what-runs-on-a-computer ()
  "Every fixed computer tool but computer_list and computer_use needs a
computer and names its capability; the pair that does not is meta."
  (harness-tools-computers-test-with
    (let ((specs (harness-call 'tools/list)))
      (dolist (name '("computer_view" "computer_camera" "computer_windows"
                      "computer_pointer" "computer_keyboard" "computer_clipboard"
                      "computer_tools" "computer_call"))
        (let ((spec (cl-find name specs :key (lambda (s) (plist-get s :name)) :test #'equal)))
          (should spec)
          (should (plist-get spec :requires-computer))
          (should (member (plist-get spec :capability)
                          '(nil "view" "windows" "pointer" "keyboard" "clipboard"
                                "camera" "exec")))))
      (dolist (name '("computer_list" "computer_use"))
        (let ((spec (cl-find name specs :key (lambda (s) (plist-get s :name)) :test #'equal)))
          (should spec)
          (should-not (plist-get spec :requires-computer)))))))

(ert-deftest harness-tools-computers-the-system-prompt-says-it-once ()
  "The computers line is added to a prompt twice only once."
  (harness-tools-computers-test-with
    (let* ((once (harness-tools-computers--system-prompt "Prompt." nil))
           (twice (harness-tools-computers--system-prompt once nil)))
      (should (string-match-p "\\`Prompt\\.\n- Computers:" once))
      (should (equal once twice))
      (should (= 1 (cl-count-if (lambda (line) (string-prefix-p "- Computers:" line))
                                (split-string twice "\n")))))))

(provide 'harness-tools-computers-test)
;;; harness-tools-computers-test.el ends here
