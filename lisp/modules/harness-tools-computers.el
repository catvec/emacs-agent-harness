;;; harness-tools-computers.el --- Tools that use the computers the harness may reach  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A session is not on a computer: it uses the tools of the computers
;; it may reach (see harness-computers.el).  These are the tools:
;;
;;   computer_list      the computers, their state, capabilities and
;;                      resources, and what this session may use;
;;   computer_view      a screen capture of the desktop or one window;
;;   computer_windows   the windows of the desktop;
;;   computer_pointer   move, click, scroll and drag;
;;   computer_keyboard  type text and press keys;
;;   computer_clipboard read and write the clipboard;
;;   computer_tools     the extra tools this computer's implementation
;;                      offers, beyond the fixed vocabulary;
;;   computer_call      call one of those extra tools;
;;   computer_use       which computer a call names when it names none.
;;
;; The fixed vocabulary is the computer-use interface, and what a
;; computer answers is its implementation's MCP server, reached over the
;; ACP connection of the client running there.  Each tool names a
;; computer (`:computer'), or leaves it to the session's preference; each
;; says which capability it needs, and the permission chain's computer
;; gate (a stage at 7) refuses, for good, a call to a computer the
;; session may not use, one whose grant does not hold the capability, or
;; one that drives a computer a person has taken control of.  The
;; handler checks the same thing again, for a call the permission chain
;; did not see (`tools/execute-approved').
;;
;; Not every computer has every capability, and none may be registered
;; at all: a call says why and what to do about it, and the model is
;; meant to tell the user and ask for a computer with
;; `request_escalation' (attribute computer) rather than guess.  A screen
;; capture comes back as bytes over MCP and is written into the
;; session's temporary directory here, so the model sees the picture and
;; the user does wherever the session is shown.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-computers)

(defun harness-tools-computers--session-id (ctx)
  "Return the session id of CTX, or signal."
  (or (plist-get ctx :session-id)
      (signal 'harness-error (list "This tool runs in no session"))))

(defun harness-tools-computers--check (ctx input capability &optional window input-p)
  "Return the computer requirement for a call under CTX.
INPUT names a computer in `:computer'; CAPABILITY is what the call needs;
WINDOW names one window.  Signal a `harness-error' with the reason and
the guidance when the call cannot run, so the model reads what to do."
  (let* ((session-id (harness-tools-computers--session-id ctx))
         (check (apply #'harness-call
                       'computers/check session-id
                       (list :computer (plist-get input :computer)
                             :capability capability
                             :window window
                             :input input-p))))
    (unless (plist-get check :ok)
      (signal 'harness-error
              (list (format "%s. %s" (plist-get check :reason) (plist-get check :hint)))))
    check))

(defun harness-tools-computers--call (ctx check tool input &optional server)
  "Call TOOL of CHECK's computer with INPUT; return a promise of the result.
SERVER defaults to the computer's `computer' server."
  (harness-then
   (harness-computers-call (plist-get check :id) tool input (or server "computer") ctx)
   (lambda (result)
     (if (plist-get result :is-error)
         result
       (let ((structured (plist-get result :structured)))
         (if (and (listp structured) (keywordp (car structured)))
             (harness-tool-ok (or (plist-get result :content) "")
                              :structured structured)
           (harness-tool-ok (or (plist-get result :content) ""))))))))

(defun harness-tools-computers--failed (result)
  "Return RESULT, an error of a computer tool, as a tool error."
  (if (plist-get result :is-error)
      (harness-tool-error (or (plist-get result :content) "The computer could not do it"))
    result))

(defun harness-tools-computers--text (structured &rest keys)
  "Return the first non-blank string of STRUCTURED under KEYS, or nil."
  (cl-some (lambda (key)
             (let ((value (plist-get structured key)))
               (and (stringp value) (not (harness-string-blank-p value)) value)))
           keys))

(defun harness-tools-computers--computer-name (ctx input)
  "Return how a call under CTX names its computer, for a title."
  (or (harness-computers--name (plist-get input :computer))
      (and (harness-method-exists-p 'computer/access)
           (ignore-errors
             (let* ((access (harness-call 'computer/access
                                          (harness-tools-computers--session-id ctx)))
                    (id (plist-get access :preferred)))
               (and id (plist-get (harness-computers-get id) :name)))))
      "the computer"))

;;;; The pictures a computer sends

(defun harness-tools-computers--write-image (ctx data mime)
  "Write DATA, base64 bytes of type MIME, into CTX's session; return its path.
The file is in the session's own temporary directory, which every
session may write, and is what the model reads and the chat shows."
  (let* ((session-id (harness-tools-computers--session-id ctx))
         (dir (and (harness-method-exists-p 'session/tmp-dir)
                   (ignore-errors (harness-call 'session/tmp-dir session-id))))
         (ext (pcase mime ("image/jpeg" ".jpg") ("image/webp" ".webp") ("image/gif" ".gif")
                (_ ".png")))
         (path (expand-file-name
                (format "computer-%s%s" (or (plist-get ctx :call-id) (harness-short-id)) ext)
                (or dir temporary-file-directory)))
         (bytes (base64-decode-string data)))
    (harness-ensure-directory (file-name-directory path))
    (let ((coding-system-for-write 'binary))
      (with-temp-file path
        (set-buffer-multibyte nil)
        (insert bytes)))
    path))

(defun harness-tools-computers--image-result (ctx check structured &optional label)
  "Return the result of a capture, from STRUCTURED and CTX.
CHECK names the computer, and LABEL is what was captured: Screen by
default.  The model gets the picture when its provider reads images;
the user sees the attachment."
  (let ((data (plist-get structured :data))
        (mime (or (plist-get structured :mime) "image/png")))
    (if (not (and (stringp data) (not (string-empty-p data))))
        (harness-tool-error "The computer sent no picture")
      (condition-case err
          (let* ((path (harness-tools-computers--write-image ctx data mime))
                 (size (harness-file-size path))
                 (name (file-name-nondirectory path))
                 (note (harness-tools-computers--text structured :note))
                 (text (format "%s of %s%s, %s%s"
                               (or label "Screen")
                               (plist-get (plist-get check :computer) :name)
                               (if note (format " (%s)" note) "")
                               (harness-format-bytes size)
                               (if (plist-get structured :width)
                                   (format ", %sx%s px"
                                           (plist-get structured :width)
                                           (plist-get structured :height))
                                 ""))))
            (append (harness-tool-ok text)
                    (list :attachments (list (list :path path :mime mime :size size :name name))
                          :images (list (list :path path :mime mime)))))
        (error (harness-tool-error
                (format "The capture could not be saved: %s"
                        (harness-error-message err))))))))

(defun harness-tools-computers--window-line (window)
  "Return WINDOW, a plist, as one line of text."
  (let ((rect (plist-get window :rect)))
    (format "- %s · %s · %s%s%s"
            (or (plist-get window :id) "?")
            (or (plist-get window :app) "?")
            (or (plist-get window :name) "")
            (if (and (listp rect) (= (length rect) 4))
                (format " · %sx%s+%s+%s" (nth 2 rect) (nth 3 rect) (nth 0 rect) (nth 1 rect))
              "")
            (if (harness-json-true-p (plist-get window :focused)) " · focused" ""))))

;;;; computer_list

(defun harness-tools-computers--list-text (computers access projects)
  "Return the words of `computer_list' for COMPUTERS, ACCESS and PROJECTS.
COMPUTERS are the records `computer/list' answered, ACCESS the session's
`computer/access', and PROJECTS its resources of kind git-repo."
  (let ((preferred (plist-get access :preferred))
        (policy (plist-get access :policy)))
    (concat
     (format "Computers: %d\n" (length computers))
     (mapconcat
      (lambda (computer)
        (let* ((id (plist-get computer :id))
               (entry (cl-find id (plist-get access :computers)
                               :key (lambda (c) (plist-get c :id)) :test #'equal))
               (allowed (plist-get entry :allowed))
               (caps (plist-get computer :capability-names))
               (resources (plist-get computer :resources))
               (control (plist-get computer :control)))
          (format "- %s (%s) · %s · %s%s%s%s\n  capabilities: %s\n  resources: %d\n"
                  (plist-get computer :name) id
                  (or (plist-get computer :kind) "client")
                  (if (plist-get computer :connected) "connected" "not connected")
                  (if allowed
                      (format " · this session may use it (%s)" (or (plist-get entry :why) "grant"))
                    " · this session may not use it")
                  (if (equal id preferred) " · preferred" "")
                  (if control (format " · %s has control" control) "")
                  (or (string-join caps ", ") "none")
                  (length resources))))
      computers)
     (if projects
         (format "\nProjects:\n%s\n"
                 (mapconcat (lambda (project)
                              (format "- %s · %s · %s"
                                      (or (plist-get project :name) "?")
                                      (or (plist-get project :computer-name) "?")
                                      (or (plist-get project :path) "")))
                            projects "\n"))
       "")
     (format "\nSession default · %s" policy)
     (let ((off (cl-remove-if-not (lambda (c) (not (plist-get c :allowed)))
                                  (plist-get access :computers))))
       (if off
           (format "\nNot this session's (%s): ask the user with request_escalation (attribute computer, value ID%s)."
                   (mapconcat (lambda (c) (plist-get c :name)) off ", ")
                   (let ((first (car off)))
                     (if (plist-get first :capability-names)
                         (format ", capabilities %s"
                                 (string-join (plist-get first :capability-names) ","))
                       "")))
         ""))
     (unless computers
       "\nNo computer registered · a client on a computer registers it from there · the tools that need a machine wait for one"))))

(harness-define-tool "computer_list"
  :label "Computer list"
  :description "List the computers the harness may use: the ones clients registered, each one's state, computer-use capabilities (view, windows, pointer, keyboard, clipboard, audio, camera, files, sandbox, exec), resources and projects, and whether this session may use it. Call it before using another computer_* tool, and to see what a refusal means; with no computer registered it says so, and the harness still works, as a chat until a client registers a computer."
  :kind 'meta
  :schema '(:type "object" :properties :empty)
  :handler
  (lambda (_input ctx)
    (let* ((session-id (plist-get ctx :session-id))
           (computers (if (harness-method-exists-p 'computer/list)
                          (harness-call 'computer/list session-id)
                        nil))
           (access (if (harness-method-exists-p 'computer/access)
                       (harness-call 'computer/access session-id)
                     (list :computers nil :policy 'auto)))
           (projects (if (harness-method-exists-p 'computer/projects)
                         (harness-call 'computer/projects session-id)
                       nil)))
      (harness-tool-ok (harness-tools-computers--list-text computers access projects)))))

;;;; computer_view

(defun harness-tools-computers--view (input ctx)
  "Handler of `computer_view': capture a screen of a computer."
  (let* ((check (harness-tools-computers--check ctx input "view"
                                                (plist-get input :window) nil))
         (request (append (list :window (plist-get input :window)
                                :frame (plist-get input :frame))
                          nil)))
    (harness-then
     (harness-tools-computers--call ctx check "screenshot" request)
     (lambda (result)
       (if (plist-get result :is-error)
           (harness-tools-computers--failed result)
         (harness-tools-computers--image-result
          ctx check (plist-get result :structured)))))))

(harness-define-tool "computer_view"
  :label "Computer view"
  :description "Look at the screen of a computer: the desktop, or one window it names. The picture comes back for you to see (and for the user, in the chat). It needs a computer this session may use, with the `view` capability; while a person has control of it you may still look, but not type or click. Leave window out for the whole desktop, or name one from computer_windows."
  :kind 'read
  :coalescable t
  :computer (lambda (input) (list :computer (plist-get input :computer)
                                  :capability "view"
                                  :window (plist-get input :window)))
  :capability "view"
  :subject (lambda (input)
             (or (plist-get input :window) (plist-get input :computer)))
  :schema '(:type "object"
            :properties (:computer (:type "string" :description "The computer's id or name; nothing for the session's default.")
                         :window (:type "string" :description "One window's id, from computer_windows; the whole desktop when left out.")
                         :frame (:type "string" :description "One Emacs frame's name or id, on a client that draws Emacs.")))
  :handler #'harness-tools-computers--view)

;;;; computer_camera

(defun harness-tools-computers--camera (input ctx)
  "Handler of `computer_camera': take a picture with a computer's camera."
  (let ((check (harness-tools-computers--check ctx input "camera" nil nil)))
    (harness-then
     (harness-tools-computers--call ctx check "camera"
                                    (list :width (plist-get input :width)
                                          :height (plist-get input :height)))
     (lambda (result)
       (if (plist-get result :is-error)
           (harness-tools-computers--failed result)
         (harness-tools-computers--image-result
          ctx check (plist-get result :structured) "Camera"))))))

(harness-define-tool "computer_camera"
  :label "Computer camera"
  :description "Take one picture with a computer's camera. It needs a computer this session may use, with the `camera` capability and a session grant for it; the picture comes back for you to see, and the user sees it in the chat. A computer without a camera, or one whose camera permission is denied, says so."
  :kind 'read
  :coalescable t
  :computer (lambda (input) (list :computer (plist-get input :computer)
                                  :capability "camera"
                                  :input t))
  :capability "camera"
  :subject (lambda (input) (plist-get input :computer))
  :schema '(:type "object"
            :properties (:computer (:type "string" :description "The computer's id or name; nothing for the session's default.")
                         :width (:type "integer" :description "The longest side, in pixels.")
                         :height (:type "integer" :description "The other side, in pixels.")))
  :handler #'harness-tools-computers--camera)

;;;; computer_windows

(defun harness-tools-computers--windows (input ctx)
  "Handler of `computer_windows': list a computer's windows."
  (let ((check (harness-tools-computers--check ctx input "windows" nil nil)))
    (harness-then
     (harness-tools-computers--call ctx check "windows" nil)
     (lambda (result)
       (if (plist-get result :is-error)
           (harness-tools-computers--failed result)
         (let ((windows (plist-get (plist-get result :structured) :windows)))
           (harness-tool-ok
            (if windows
                (concat (format "Windows of %s:\n"
                                (plist-get (plist-get check :computer) :name))
                        (mapconcat #'harness-tools-computers--window-line windows "\n"))
              (format "The computer %s lists no window"
                      (plist-get (plist-get check :computer) :name))))))))))

(harness-define-tool "computer_windows"
  :label "Computer windows"
  :description "List the windows a computer can see, each with its id, application, title and rectangle. Use the id with computer_view or computer_pointer to act on that one window, which is least privilege when the computer's implementation is window-scoped."
  :kind 'read
  :coalescable t
  :computer (lambda (input) (list :computer (plist-get input :computer)
                                  :capability "windows"))
  :capability "windows"
  :subject (lambda (input) (plist-get input :computer))
  :schema '(:type "object"
            :properties (:computer (:type "string" :description "The computer's id or name; nothing for the session's default.")))
  :handler #'harness-tools-computers--windows)

;;;; computer_pointer

(defun harness-tools-computers--pointer (input ctx)
  "Handler of `computer_pointer': drive a computer's pointer."
  (let* ((check (harness-tools-computers--check ctx input "pointer"
                                                (plist-get input :window) t))
         (request (list :action (plist-get input :action)
                        :x (plist-get input :x)
                        :y (plist-get input :y)
                        :button (plist-get input :button)
                        :amount (plist-get input :amount)
                        :direction (plist-get input :direction)
                        :window (plist-get input :window))))
    (harness-then
     (harness-tools-computers--call ctx check "pointer" request)
     (lambda (result)
       (if (plist-get result :is-error)
           (harness-tools-computers--failed result)
         (harness-tool-ok
          (format "%s on %s"
                  (or (harness-tools-computers--text (plist-get result :structured) :done)
                      "done")
                  (plist-get (plist-get check :computer) :name))))))))

(harness-define-tool "computer_pointer"
  :label "Computer pointer"
  :description "Move the pointer, click, scroll or drag on a computer's desktop. Needs the `pointer` capability and a session grant for it; while a person has control of the computer it waits. Prefer acting on one window (`window`, from computer_windows) when the implementation is window-scoped, which is the least access that does the job."
  :kind 'exec
  :computer (lambda (input) (list :computer (plist-get input :computer)
                                  :capability "pointer"
                                  :window (plist-get input :window)
                                  :input t))
  :capability "pointer"
  :subject (lambda (input) (or (plist-get input :action) (plist-get input :computer)))
  :schema '(:type "object"
            :properties (:computer (:type "string" :description "The computer's id or name; nothing for the session's default.")
                         :action (:type "string" :enum ["move" "click" "scroll" "drag"] :description "What to do.")
                         :x (:type "integer" :description "X for move and drag.")
                         :y (:type "integer" :description "Y for move and drag.")
                         :button (:type "integer" :description "The button, 1 by default.")
                         :amount (:type "integer" :description "Scroll steps, 1 by default.")
                         :direction (:type "string" :enum ["up" "down" "left" "right"] :description "Scroll direction.")
                         :window (:type "string" :description "One window's id, from computer_windows."))
            :required ("action"))
  :handler #'harness-tools-computers--pointer)

;;;; computer_keyboard

(defun harness-tools-computers--keyboard (input ctx)
  "Handler of `computer_keyboard': type or press a key on a computer."
  (let* ((check (harness-tools-computers--check ctx input "keyboard"
                                                (plist-get input :window) t))
         (request (list :action (plist-get input :action)
                        :text (plist-get input :text)
                        :key (plist-get input :key)
                        :window (plist-get input :window))))
    (harness-then
     (harness-tools-computers--call ctx check "keyboard" request)
     (lambda (result)
       (if (plist-get result :is-error)
           (harness-tools-computers--failed result)
         (harness-tool-ok
          (format "%s on %s"
                  (or (harness-tools-computers--text (plist-get result :structured) :done)
                      "done")
                  (plist-get (plist-get check :computer) :name))))))))

(harness-define-tool "computer_keyboard"
  :label "Computer keyboard"
  :description "Type text or press a key on a computer. Needs the `keyboard` capability and a session grant for it; while a person has control of the computer it waits. Name one window (`window`, from computer_windows) when the implementation is window-scoped."
  :kind 'exec
  :computer (lambda (input) (list :computer (plist-get input :computer)
                                  :capability "keyboard"
                                  :window (plist-get input :window)
                                  :input t))
  :capability "keyboard"
  :subject (lambda (input) (or (plist-get input :text) (plist-get input :key)
                               (plist-get input :computer)))
  :schema '(:type "object"
            :properties (:computer (:type "string" :description "The computer's id or name; nothing for the session's default.")
                         :action (:type "string" :enum ["type" "key"] :description "Type text, or press one key.")
                         :text (:type "string" :description "The text to type.")
                         :key (:type "string" :description "The key to press, such as Return, Tab or Escape.")
                         :window (:type "string" :description "One window's id, from computer_windows."))
            :required ("action"))
  :handler #'harness-tools-computers--keyboard)

;;;; computer_clipboard

(defun harness-tools-computers--clipboard (input ctx)
  "Handler of `computer_clipboard': read or write a computer's clipboard."
  (let* ((action (downcase (or (harness-computers--name (plist-get input :action)) "get")))
         (check (harness-tools-computers--check ctx input "clipboard" nil
                                                (equal action "set"))))
    (harness-then
     (harness-tools-computers--call
      ctx check "clipboard"
      (list :action action :text (plist-get input :text)))
     (lambda (result)
       (if (plist-get result :is-error)
           (harness-tools-computers--failed result)
         (if (equal action "get")
             (harness-tool-ok
              (format "Clipboard of %s:\n%s"
                      (plist-get (plist-get check :computer) :name)
                      (or (plist-get (plist-get result :structured) :text) "")))
           (harness-tool-ok
            (format "%s on %s"
                    (or (harness-tools-computers--text (plist-get result :structured) :done)
                        "done")
                    (plist-get (plist-get check :computer) :name)))))))))

(harness-define-tool "computer_clipboard"
  :label "Computer clipboard"
  :description "Read (action get) or write (action set, with text) the clipboard of a computer. Needs the `clipboard` capability; writing also waits while a person has control of that computer."
  :kind 'exec
  :computer (lambda (input) (list :computer (plist-get input :computer)
                                  :capability "clipboard"
                                  :input (equal (downcase (or (harness-computers--name
                                                               (plist-get input :action)) "get"))
                                                "set")))
  :capability "clipboard"
  :subject (lambda (input) (or (plist-get input :action) (plist-get input :computer)))
  :schema '(:type "object"
            :properties (:computer (:type "string" :description "The computer's id or name; nothing for the session's default.")
                         :action (:type "string" :enum ["get" "set"] :description "Read or write the clipboard.")
                         :text (:type "string" :description "What to put on the clipboard, for set."))
            :required ("action"))
  :handler #'harness-tools-computers--clipboard)

;;;; computer_tools and computer_call

(harness-define-tool "computer_tools"
  :label "Computer tools"
  :description "List the extra tools a computer's implementation offers beyond the fixed computer-use vocabulary (view, windows, pointer, keyboard, clipboard, audio), with the server that runs them. Call one with computer_call."
  :kind 'meta
  :computer (lambda (input) (list :computer (plist-get input :computer)))
  :subject (lambda (input) (plist-get input :computer))
  :schema '(:type "object"
            :properties (:computer (:type "string" :description "The computer's id or name; nothing for the session's default.")
                         :server (:type "string" :description "The tool server's name, when the computer runs more than one.")))
  :handler
  (lambda (input ctx)
    (let ((check (harness-tools-computers--check ctx input nil nil nil)))
      (harness-then
       (harness-computers-tools (plist-get check :id)
                                (or (plist-get input :server) "computer"))
       (lambda (result)
         (let ((tools (plist-get result :tools)))
           (harness-tool-ok
            (if tools
                (concat (format "Tools of %s:\n"
                                (plist-get (plist-get check :computer) :name))
                        (mapconcat
                         (lambda (tool)
                           (format "- %s · %s"
                                   (or (plist-get tool :name) "?")
                                   (or (plist-get tool :description) "")))
                         tools "\n"))
              (format "The computer %s offers no extra tool"
                      (plist-get (plist-get check :computer) :name))))))))))

(defun harness-tools-computers--call-extra (input ctx)
  "Handler of `computer_call': call an extra tool of a computer."
  (let ((tool (harness-computers--name (plist-get input :tool)))
        (arguments (let ((a (plist-get input :arguments)))
                     (if (and (listp a) (keywordp (car a))) a nil))))
    ;; The tool's name first: a call without one touches no computer.
    (unless tool
      (signal 'harness-error (list "computer_call needs tool: the tool's name")))
    (let ((check (harness-tools-computers--check
                  ctx input (or (plist-get input :capability) "exec") nil t)))
      (harness-then
       (harness-tools-computers--call ctx check tool arguments
                                      (or (plist-get input :server) "computer"))
       (lambda (result)
         (if (plist-get result :is-error)
             (harness-tools-computers--failed result)
           result))))))

(harness-define-tool "computer_call"
  :label "Computer call"
  :description "Call one of the extra tools a computer's implementation offers (computer_tools lists them) with its arguments. It needs the capability named in capability (exec by default) and a session grant for it: an extra tool may do anything its implementation says, so treat it as running a program on that computer. Use files for the file tools a computer scopes to its own storage."
  :kind 'exec
  :computer (lambda (input) (list :computer (plist-get input :computer)
                                  :capability (or (plist-get input :capability) "exec")
                                  :input t))
  :capability "exec"
  :subject (lambda (input) (or (plist-get input :tool) (plist-get input :computer)))
  :schema '(:type "object"
            :properties (:computer (:type "string" :description "The computer's id or name; nothing for the session's default.")
                         :tool (:type "string" :description "The tool's name, from computer_tools.")
                         :arguments (:type "object" :description "The tool's arguments, as an object.")
                         :capability (:type "string" :description "The capability the tool needs, exec by default; files for a computer's scoped file tools.")
                         :server (:type "string" :description "The tool server's name, when the computer runs more than one."))
            :required ("tool"))
  :handler #'harness-tools-computers--call-extra)

;;;; computer_use

(harness-define-tool "computer_use"
  :label "Computer use"
  :description "Choose the computer this session uses when a call names none, among the computers it may use (computer_list says which). It is a preference, not a grant, and not a pin: a call that names a computer, and a resource of one, still goes where it names. Give no computer to clear it."
  :kind 'meta
  :schema '(:type "object"
            :properties (:computer (:type "string" :description "The computer's id or name; nothing to clear the preference.")))
  :subject (lambda (input) (plist-get input :computer))
  :handler
  (lambda (input ctx)
    (let* ((session-id (harness-tools-computers--session-id ctx))
           (computer (harness-computers--name (plist-get input :computer)))
           (id (and computer (or (harness-computers-resolve computer) computer)))
           (access (harness-call 'computer/access session-id))
           (entry (and id (cl-find id (plist-get access :computers)
                                   :key (lambda (c) (plist-get c :id)) :test #'equal))))
      (when (and computer (not (and entry (plist-get entry :allowed))))
        (signal 'harness-error
                (list (format "This session may not use the computer %s; ask the user for it with request_escalation (attribute computer)"
                              computer))))
      (harness-computers-set-preference session-id (and entry (plist-get entry :id)))
      (harness-tool-ok
       (if entry
           (format "This session uses %s when a call names no computer"
                   (plist-get entry :name))
         "This session has no preferred computer")))))

;;;; The system prompt line

(defconst harness-tools-computers--prompt-line
  "\n- Computers: the machines the harness may use. computer_list names them, their resources and what this session may use; computer_view looks at one, computer_camera takes a picture with one, computer_windows lists its windows, and computer_pointer, computer_keyboard, computer_clipboard, computer_tools and computer_call act there. A call that needs a computer this session may not use is refused: ask the user for it with request_escalation (attribute computer).\n"
  "What every session's system prompt says about computers.
It names no computer and no path, so it is the same for every session
of a harness, and a prompt cache survives from one to the next.")

(defun harness-tools-computers--system-prompt (prompt _session)
  "Add the computers line to PROMPT."
  (if (string-match-p "\n- Computers:" prompt)
      prompt
    (concat prompt harness-tools-computers--prompt-line)))

;;;; Module

(defun harness-tools-computers--init ()
  "Hook the module into the bus (idempotent)."
  (harness-add-filter 'agent/system-prompt #'harness-tools-computers--system-prompt 60))

(defun harness-tools-computers--shutdown ()
  "Take the module off the bus."
  (harness-remove-filter 'agent/system-prompt #'harness-tools-computers--system-prompt))

(when (harness-module-ready-p 'tools-computers)
  (harness-tools-computers--init))

(harness-define-module 'tools-computers
  :doc "The tools that use a computer: computer_list, computer_view, computer_windows, computer_pointer, computer_keyboard, computer_clipboard, computer_tools, computer_call and computer_use. Each names the computer it acts on, or leaves it to the session's preference, and the fixed vocabulary is what a computer's MCP server answers."
  :requires '(computers tools)
  :init #'harness-tools-computers--init
  :shutdown #'harness-tools-computers--shutdown)

(provide 'harness-tools-computers)
;;; harness-tools-computers.el ends here
