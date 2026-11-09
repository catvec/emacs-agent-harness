;;; harness-computer-endpoint.el --- What a client lends from the computer it runs on  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A computer offers the harness tools, and the client running on that
;; computer runs and keeps the MCP servers that provide them.  This file
;; is the client's side, as `harness-emacs-endpoint.el' is for the Emacs
;; a client lends: an MCP server over the ACP connection, whose tools are
;; a fixed vocabulary of computer use.
;;
;; The vocabulary is the computer-use interface
;; (lisp/modules/harness-computers.el), the same whichever
;; implementation answers it:
;;
;;   tools/call screenshot {window|frame|desktop}   -> (:data BASE64 :mime "image/png"
;;                                                      :width N :height N :note TEXT)
;;   tools/call windows {}                          -> (:windows ((:id :name :app :kind
;;                                                      :rect (X Y W H) :focused) ...))
;;   tools/call window {id}                         -> (:window (:id :name :app :kind :rect))
;;   tools/call pointer {action x y button amount window}
;;                                                  -> (:done TEXT)
;;   tools/call keyboard {action text key window}   -> (:done TEXT)
;;   tools/call clipboard {action text}             -> (:text TEXT) | (:done TEXT)
;;   tools/call audio {action seconds}              -> (:sources ...) | (:data BASE64 :mime "audio/wav")
;;   tools/call info {}                             -> (:computer ... :capabilities (...))
;;
;; An implementation declares the capabilities it really has
;; (`harness-computer-endpoint-capabilities'): `view' when it can capture
;; the screen or a window, `windows' when it lists the desktop's windows,
;; `pointer' and `keyboard' when it can drive them, `clipboard' when it
;; reads and writes the selection, `audio' when it can record.  A tool
;; whose capability the computer lacks is refused by the harness before
;; it ever reaches this file.  `:window-scoped' says that `view' can name
;; one window and no other, which this implementation can for the Emacs
;; frames it draws itself (`x-export-frames'), and for a Wayland
;; compositor's windows when `swaymsg' and `grim' are there.
;;
;; This implementation works with what the machine has: `grim' or
;; `scrot' for the screen, `swaymsg' or `wmctrl' for the windows,
;; `xdotool', `ydotool' or `wtype' for the pointer and the keyboard, and
;; Emacs itself for its own frames and the clipboard.  What is missing is
;; simply not offered, and the page says so; nothing pretends.
;;
;; The client's computer is described in ACP's `initialize'
;; (`clientCapabilities._harness.computer'), which records where the
;; client is without registering anything.  The client registers its
;; computer only when the user asks it to (the computers page's
;; `[Registration]', or the client's own integration), sending the
;; secret this file keeps (mode 600) and getting back a token that binds
;; the MCP session; `_harness/computer/attach' presents the secret again
;; after a reconnect.  Nothing of the harness's state is kept here, and
;; the harness server has no computer of its own.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-mcp-protocol)

(defvar harness-acp-error-method)
(declare-function harness-acp-respond-error "harness-acp" (respond code message &optional data))
(declare-function harness-then "harness-core" (promise on-ok &optional on-err))

(defgroup harness-computer-endpoint nil
  "What a client lends from the computer it runs on."
  :group 'harness
  :prefix "harness-computer-endpoint-")

(defcustom harness-computer-endpoint-name nil
  "The name this computer is known by, or nil for its host name.
It is what `computer_list' and the computers page show; the same
machine registered from two clients has one name."
  :type '(choice (const :tag "Host name" nil) string)
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-id-file
  (locate-user-emacs-file "harness/computer-id")
  "File where this computer's id is kept, so a registration stays the same.
The id is stable per machine (`cmp-HOST-RANDOM'), and registering the
computer again from the same client uses it."
  :type 'file
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-secret-file
  (locate-user-emacs-file "harness/computer-secret")
  "File where this computer's registration secret is kept, mode 600.
It is made the first time this client registers its computer with a
harness elsewhere, and the harness keeps only a salted hash of it."
  :type 'file
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-resource-roots
  '("~/src" "~/code" "~/projects" "~/documents" "~/work" "~/git")
  "Directories this computer searches for git repositories to offer.
A repository under one of them, at most
`harness-computer-endpoint-resource-depth' levels down, is offered as a
`git-repo' resource.  It is a place this computer has, with the path it
has; the harness needs no path of its own."
  :type '(repeat directory)
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-resource-depth 3
  "How many levels below a resource root to look for git repositories."
  :type 'integer
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-resources nil
  "More resources this computer offers, as plists.
Each is `(:kind \"git-repo\" :name \"…\" :path \"…\")`, as a client
sends them; they are added to the ones found under
`harness-computer-endpoint-resource-roots'."
  :type '(repeat plist)
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-vnc-url nil
  "A URL where this computer's screen is shown, such as a noVNC page.
The computers page opens it with [View]; a person watching a computer is
not a session's call and needs no permission.  Nil means this client
shows no screen of its own."
  :type '(choice (const :tag "None" nil) string)
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-vnc-socket nil
  "The RFB WebSocket where this computer's screen is shown, when it has one.
A client that draws the screen itself -- the Flutter app's VNC view --
speaks RFB to this `ws://' or `wss://' endpoint, the `/websockify' of
the same server `harness-computer-endpoint-vnc-url' names.  A page
opened in a browser uses the URL; nil means this client offers no
socket.  The harness keeps it with the computer and hands it to every
client that may view it."
  :type '(choice (const :tag "None" nil) string)
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-display nil
  "The display this client lends as a computer, or nil for its own.
A string such as \":99\" names the X display whose desktop this client
lends: an Xvfb, or a desktop of its own that is not the one this Emacs
draws in.  The screen, the windows, the pointer and the keyboard then
act on that desktop, and the computer gains the `sandbox' capability.
Nil means the display this client runs on.  The display's own VNC server
is named by `harness-computer-endpoint-vnc-url' and
`harness-computer-endpoint-vnc-socket'."
  :type '(choice (const :tag "This client's display" nil) string)
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-max-image-bytes (* 12 1024 1024)
  "Largest screen capture this client sends back, in bytes."
  :type 'integer
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-max-text 200000
  "Longest text this client types or puts on the clipboard, in characters."
  :type 'integer
  :group 'harness-computer-endpoint)

(defcustom harness-computer-endpoint-max-audio-seconds 15
  "Longest recording this client makes for one call, in seconds."
  :type 'integer
  :group 'harness-computer-endpoint)

(defconst harness-computer-endpoint-mcp-method "_harness/computer/mcp"
  "The one method the harness sends a computer: an MCP message in `:message'.")

(defconst harness-computer-endpoint--prefix "_harness/computer/"
  "Prefix of the methods of the requests the harness sends a computer.")

(defconst harness-computer-endpoint--servers '("computer")
  "The tool servers this client runs for its computer.")

(defvar harness-computer-endpoint--token (make-hash-table :test 'equal)
  "Computer id -> the MCP token the harness gave this client at registration.")

(defvar harness-computer-endpoint--attached nil
  "The computer id this client registered or attached to, or nil.")

(defvar harness-computer-endpoint--last-tools nil
  "The tool list of the last computer this client reported, or nil.")

;;;; The computer this client runs on

(defun harness-computer-endpoint--host ()
  "Return this computer's host name."
  (let ((host (system-name)))
    (if (and (stringp host) (string-match "\\`[^.]+" host))
        (match-string 0 host)
      (or host "computer"))))

(defun harness-computer-endpoint--read-file (path)
  "Return the trimmed text of PATH, or nil."
  (when (and (stringp path) (file-readable-p path))
    (let ((text (string-trim (with-temp-buffer
                               (insert-file-contents path)
                               (buffer-string)))))
      (and (not (string-empty-p text)) text))))

(defun harness-computer-endpoint--write-private (path text)
  "Write TEXT to PATH, making its directory and keeping it mode 600."
  (harness-ensure-directory (file-name-directory path))
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region text nil path nil 'silent))
  (ignore-errors (set-file-modes path #o600))
  text)

(defvar harness-computer-endpoint--id nil
  "This computer's id, once read.")

(defun harness-computer-endpoint-id ()
  "Return this computer's stable id: `cmp-HOST-RANDOM'."
  (or harness-computer-endpoint--id
      (setq harness-computer-endpoint--id
            (or (harness-computer-endpoint--read-file harness-computer-endpoint-id-file)
                (harness-computer-endpoint--write-private
                 harness-computer-endpoint-id-file
                 (format "cmp-%s-%s"
                         (replace-regexp-in-string "[^a-z0-9]+" "-"
                                                   (downcase (harness-computer-endpoint--host)))
                         (harness-short-id 6)))))))

(defun harness-computer-endpoint--name (value)
  "Return VALUE as a trimmed non-blank string, or nil."
  (and (stringp value) (not (harness-string-blank-p value)) (string-trim value)))

(defun harness-computer-endpoint-name ()
  "Return the name this computer is known by."
  (or (harness-computer-endpoint--name harness-computer-endpoint-name)
      (harness-computer-endpoint--host)))

(defun harness-computer-endpoint-secret ()
  "Return this computer's registration secret, making it once.
It is 256 random bits in base64url, kept mode 600 in
`harness-computer-endpoint-secret-file'."
  (or (harness-computer-endpoint--read-file harness-computer-endpoint-secret-file)
      (harness-computer-endpoint--write-private
       harness-computer-endpoint-secret-file
       (base64url-encode-string
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (dotimes (_ 32) (insert-byte (random 256) 1))
          (buffer-string))
        t))))

(defun harness-computer-endpoint--display-override ()
  "Return the display this client lends, or nil for its own."
  (harness-computer-endpoint--name harness-computer-endpoint-display))

(defun harness-computer-endpoint--target-display ()
  "Return the display whose desktop this client lends."
  (or (harness-computer-endpoint--display-override)
      (getenv "WAYLAND_DISPLAY")
      (getenv "DISPLAY")))

(defun harness-computer-endpoint--session-type ()
  "Return `wayland', `x11' or nil, as the display this client lends reports it."
  (let ((override (harness-computer-endpoint--display-override))
        (type (or (getenv "XDG_SESSION_TYPE") "")))
    (cond
     ((and override (string-match-p "wayland" (downcase override))) 'wayland)
     (override 'x11)
     ((string-equal (downcase type) "wayland") 'wayland)
     ((string-equal (downcase type) "x11") 'x11)
     ((and (getenv "WAYLAND_DISPLAY") (not (eq window-system 'x))) 'wayland)
     ((eq window-system 'x) 'x11))))

(defun harness-computer-endpoint--process-environment ()
  "Return the environment for a program that acts on the display lent.
It names the display `harness-computer-endpoint-display' gives, so
`scrot', `wmctrl', `xdotool' and the rest use that desktop and not the
one this Emacs draws in; without an override it is this process's own."
  (let ((display (harness-computer-endpoint--display-override)))
    (if (not display)
        process-environment
      (let ((wayland (eq (harness-computer-endpoint--session-type) 'wayland))
            (environment (cl-remove-if
                          (lambda (entry)
                            (string-match-p "\\`\\(DISPLAY\\|WAYLAND_DISPLAY\\|XDG_SESSION_TYPE\\)=" entry))
                          process-environment)))
        (cons (if wayland
                  (concat "WAYLAND_DISPLAY=" display)
                (concat "DISPLAY=" display))
              (cons (if wayland "XDG_SESSION_TYPE=wayland" "XDG_SESSION_TYPE=x11")
                    environment))))))

(defun harness-computer-endpoint--program (&rest names)
  "Return the first of NAMES that is an executable, or nil."
  (cl-find-if #'executable-find names))

(defun harness-computer-endpoint-capabilities ()
  "Return the computer-use capabilities this client's implementation has.
`view' when it can capture the screen or a window, `windows' when it
lists the desktop's windows, `pointer' and `keyboard' when it can drive
them, `clipboard' for Emacs's selection, `audio' when it can record,
and `sandbox' when `harness-computer-endpoint-display' lends a desktop
other than the client's own.  What the machine lacks is not offered."
  (let* ((override (harness-computer-endpoint--display-override))
         (wayland (eq (harness-computer-endpoint--session-type) 'wayland))
         (grim (and wayland (harness-computer-endpoint--program "grim")))
         (scrot (and (not wayland) (harness-computer-endpoint--program "scrot" "import")))
         (sway (and wayland (harness-computer-endpoint--program "swaymsg")))
         (wmctrl (and (not wayland) (harness-computer-endpoint--program "wmctrl")))
         (xdotool (and (not wayland) (harness-computer-endpoint--program "xdotool")))
         (ydotool (harness-computer-endpoint--program "ydotool"))
         (wtype (and wayland (harness-computer-endpoint--program "wtype")))
         (record (harness-computer-endpoint--program "pw-record" "parecord"))
         (frame (and (not override) (display-graphic-p) (fboundp 'x-export-frames)))
         (clipboard (and (not override) (display-graphic-p)))
         (caps nil))
    (when (or grim scrot frame) (push "view" caps))
    (when (or sway wmctrl) (push "windows" caps))
    (when (or xdotool ydotool (and sway wayland)) (push "pointer" caps))
    (when (or xdotool ydotool wtype) (push "keyboard" caps))
    (when clipboard (push "clipboard" caps))
    (when record (push "audio" caps))
    (when override (push "sandbox" caps))
    (nreverse caps)))

(defun harness-computer-endpoint-window-scoped-p ()
  "Non-nil when this implementation can capture one window alone."
  (or (and (not (harness-computer-endpoint--display-override))
           (display-graphic-p) (fboundp 'x-export-frames))
      (and (eq (harness-computer-endpoint--session-type) 'wayland)
           (harness-computer-endpoint--program "grim")
           (harness-computer-endpoint--program "swaymsg"))))

(defun harness-computer-endpoint-info ()
  "Return the plist that describes this computer to the harness.
It is what `initialize' advertises and what a registration sends; it
says what this machine is and which computer-use capabilities its
implementation has, and registers nothing."
  (list :id (harness-computer-endpoint-id)
        :name (harness-computer-endpoint-name)
        :host (harness-computer-endpoint--host)
        :os (or (and (fboundp 'system-configuration) system-configuration) "unknown")
        :arch (or (and (boundp 'system-configuration-options)
                       (car (split-string system-configuration-options " ")))
                  "unknown")
        :display (harness-computer-endpoint--target-display)
        :vnc harness-computer-endpoint-vnc-url
        :vnc-socket harness-computer-endpoint-vnc-socket
        :window-scoped (harness-computer-endpoint-window-scoped-p)
        :capabilities (harness-computer-endpoint-capabilities)
        :servers (mapcar (lambda (name) (list :name name :title "Computer"))
                         harness-computer-endpoint--servers)))

(defun harness-computer-endpoint-client-capabilities (&optional base)
  "Return BASE, the ACP `clientCapabilities', naming this client's computer.
A client that lends nothing else still describes its computer here; the
harness records it, and a session the client makes may use it."
  (let ((base (or base (list :fs (list :readTextFile :false :writeTextFile :false)
                             :terminal :false))))
    (plist-put (copy-sequence base) :_harness
               (plist-put (copy-sequence (or (plist-get base :_harness) nil))
                          :computer (harness-computer-endpoint-info)))))

;;;; Running programs on this computer

(defun harness-computer-endpoint--run (program args &optional input timeout)
  "Run PROGRAM with ARGS, on this computer; return (STATUS . OUTPUT).
INPUT, when a string, is its standard input.  TIMEOUT, seconds, kills it
and signals.  The output is a unibyte string; the caller decides what
the bytes are."
  (let* ((buffer (generate-new-buffer " *harness-computer-process*"))
         (timeout (or timeout 10))
         (process-environment (harness-computer-endpoint--process-environment))
         (proc (make-process :name "harness-computer"
                             :buffer buffer
                             :command (cons program args)
                             :coding 'binary
                             :connection-type 'pipe
                             :noquery t))
         (deadline (+ (float-time) timeout)))
    (unwind-protect
        (progn
          (when (stringp input)
            (process-send-string proc input))
          (process-send-eof proc)
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output proc 0.05))
          (when (process-live-p proc)
            (ignore-errors (kill-process proc))
            (signal 'harness-error
                    (list (format "%s did not finish in %ss" program timeout))))
          (list (process-exit-status proc)
                (with-current-buffer buffer (buffer-string))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (process-live-p proc) (ignore-errors (delete-process proc))))))

(defun harness-computer-endpoint--output (program args &optional input timeout)
  "Run PROGRAM with ARGS and return its output, or signal when it fails."
  (pcase-let* ((`(,status ,output) (harness-computer-endpoint--run program args input timeout)))
    (unless (zerop status)
      (signal 'harness-error
              (list (format "%s failed%s" program
                            (let ((text (string-trim output)))
                              (if (string-empty-p text) "" (concat ": " (harness-truncate-end text 300))))))))
    output))

(defun harness-computer-endpoint--base64 (bytes)
  "Return BYTES as base64 text."
  (base64-encode-string bytes t))

(defun harness-computer-endpoint--size (bytes)
  "Signal when BYTES is larger than `harness-computer-endpoint-max-image-bytes'."
  (when (> (length bytes) harness-computer-endpoint-max-image-bytes)
    (signal 'harness-error
            (list (format "The screen capture is larger than %s; capture one window instead"
                          (harness-format-bytes harness-computer-endpoint-max-image-bytes)))))
  bytes)

;;;; Screens

(defun harness-computer-endpoint--frames ()
  "Return this Emacs's graphic frames."
  (cl-remove-if-not (lambda (frame) (eq (frame-parameter frame 'window-system) 'x))
                    (frame-list)))

(defun harness-computer-endpoint--frame (value)
  "Return the frame VALUE names, an Emacs frame name or id, or nil."
  (let ((want (harness-computer-endpoint--name (format "%s" (or value "")))))
    (when (and want (not (string-empty-p want)))
      (cl-find-if (lambda (frame)
                    (or (string-equal want (format "%s" (frame-parameter frame 'name)))
                        (string-equal want (harness-computer-endpoint--frame-id frame))))
                  (harness-computer-endpoint--frames)))))

(defun harness-computer-endpoint--target-frame ()
  "Return the frame a screen capture falls back to: the selected one.
A client that lends another display has no frame there, so it falls
back to none."
  (unless (harness-computer-endpoint--display-override)
    (or (and (display-graphic-p) (selected-frame))
        (car (harness-computer-endpoint--frames)))))

(defun harness-computer-endpoint--frame-capture (frame)
  "Return FRAME as a PNG, or nil."
  (when (and frame (fboundp 'x-export-frames))
    (ignore-errors (x-export-frames frame 'png))))

(defun harness-computer-endpoint--sway-tree ()
  "Return the windows of a sway compositor as plists, or nil."
  (when-let* ((swaymsg (harness-computer-endpoint--program "swaymsg")))
    (let ((json (ignore-errors
                  (harness-json-parse
                   (harness-computer-endpoint--output swaymsg '("-t" "get_tree") nil 5))))
          (windows nil))
      (cl-labels ((walk (node)
                    (when (and (listp node)
                               (or (plist-get node :name) (plist-get node :app_id)))
                      (let ((rect (plist-get node :rect)))
                        (when (and (listp rect) (plist-get rect :width) (plist-get rect :height))
                          (push (list :id (format "sway-%s" (plist-get node :id))
                                      :name (or (plist-get node :name) "")
                                      :app (or (plist-get node :app_id) "")
                                      :kind "window"
                                      :rect (list (plist-get rect :x) (plist-get rect :y)
                                                  (plist-get rect :width) (plist-get rect :height))
                                      :focused (and (harness-json-true-p
                                                     (plist-get node :focused)) t))
                                windows))))
                    (dolist (child (append (plist-get node :nodes) nil))
                      (walk child))
                    (dolist (child (append (plist-get node :floating_nodes) nil))
                      (walk child))))
        (walk json))
      (nreverse windows))))

(defun harness-computer-endpoint--wmctrl-windows ()
  "Return the X11 windows `wmctrl' lists, with their rectangles, or nil."
  (when-let* ((wmctrl (harness-computer-endpoint--program "wmctrl")))
    (ignore-errors
      (let ((lines (split-string
                    (harness-computer-endpoint--output wmctrl '("-lGp") nil 5) "\n" t)))
        (delq nil
              (mapcar
               (lambda (line)
                 ;; id desktop pid x y w h host title
                 (when (string-match
                        "\\`\\(0x[0-9a-f]+\\)[ \t]+[-0-9]+[ \t]+[0-9]+[ \t]+\\([-0-9]+\\)[ \t]+\\([-0-9]+\\)[ \t]+\\([0-9]+\\)[ \t]+\\([0-9]+\\)[ \t]+\\([^ \t]+\\)[ \t]+\\(.*\\)\\'"
                        line)
                   (list :id (match-string 1 line)
                         :name (match-string 7 line)
                         :app (match-string 6 line)
                         :kind "window"
                         :rect (list (string-to-number (match-string 2 line))
                                     (string-to-number (match-string 3 line))
                                     (string-to-number (match-string 4 line))
                                     (string-to-number (match-string 5 line)))
                         :focused :false)))
               lines))))))

(defun harness-computer-endpoint--frame-id (frame)
  "Return the id a window plist gives FRAME."
  (format "frame-%s" (or (frame-parameter frame 'window-id)
                         (frame-parameter frame 'name)
                         frame)))

(defun harness-computer-endpoint--frame-windows ()
  "Return this Emacs's frames as windows, for a window-scoped implementation."
  (mapcar (lambda (frame)
            (list :id (harness-computer-endpoint--frame-id frame)
                  :name (format "%s" (frame-parameter frame 'name))
                  :app "Emacs"
                  :kind "frame"
                  :rect (list 0 0 (frame-pixel-width frame) (frame-pixel-height frame))
                  :focused (and (eq frame (selected-frame)) t)))
          (harness-computer-endpoint--frames)))

(defun harness-computer-endpoint--windows ()
  "Return every window this implementation can see.
This Emacs's own frames are windows of its display, so they are named
only when the client lends its own display."
  (append (harness-computer-endpoint--sway-tree)
          (harness-computer-endpoint--wmctrl-windows)
          (unless (harness-computer-endpoint--display-override)
            (harness-computer-endpoint--frame-windows))))

(defun harness-computer-endpoint--window (id)
  "Return the window with ID, or signal."
  (let* ((id (harness-computer-endpoint--name (format "%s" (or id ""))))
         (windows (harness-computer-endpoint--windows))
         (window (cl-find id windows :key (lambda (w) (plist-get w :id)) :test #'equal)))
    (or window
        (signal 'harness-error
                (list (format "No window is named %s; tools/call windows lists them" id))))))

(defun harness-computer-endpoint--capture (window)
  "Return a screen capture of WINDOW, a plist, as PNG bytes, or nil."
  (pcase (plist-get window :kind)
    ("frame" (harness-computer-endpoint--frame-capture
              (harness-computer-endpoint--frame (plist-get window :id))))
    ("window"
     (when-let* ((rect (plist-get window :rect))
                 (grim (harness-computer-endpoint--program "grim")))
       (harness-computer-endpoint--output
        grim (list "-g" (format "%d,%d %dx%d"
                                (nth 0 rect) (nth 1 rect) (nth 2 rect) (nth 3 rect))
                   "-")
        nil 10)))))

(defun harness-computer-endpoint--capture-file (program args)
  "Run PROGRAM with ARGS writing a PNG file; return its bytes.
Some programs write their picture only to a file, and a file of this
computer is read here and sent as bytes: the harness needs no path of
this machine."
  (let ((path (make-temp-file "harness-computer-shot-" nil ".png")))
    (unwind-protect
        (progn
          (harness-computer-endpoint--output program (append args (list path)) nil 15)
          (when (file-exists-p path)
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally path)
              (buffer-string))))
      (ignore-errors (delete-file path)))))

(defun harness-computer-endpoint--desktop-capture ()
  "Return a capture of the desktop as PNG bytes, or nil."
  (let* ((type (harness-computer-endpoint--session-type))
         (grim (harness-computer-endpoint--program "grim"))
         (scrot (harness-computer-endpoint--program "scrot"))
         (import (harness-computer-endpoint--program "import")))
    (cond
     ((and grim (eq type 'wayland))
      (harness-computer-endpoint--output grim (list "-") nil 10))
     (scrot (harness-computer-endpoint--capture-file scrot '("-o")))
     (import (harness-computer-endpoint--capture-file import '("-window" "root" "png")))
     (t nil))))

(defun harness-computer-endpoint--screenshot (params)
  "Answer a screen capture of PARAMS: one window, one frame, or the desktop."
  (let* ((window-id (harness-computer-endpoint--name (plist-get params :window)))
         (frame-id (harness-computer-endpoint--name (plist-get params :frame)))
         (frame (and frame-id (harness-computer-endpoint--frame frame-id)))
         (window (and window-id (harness-computer-endpoint--window window-id)))
         (data (cond (frame (harness-computer-endpoint--frame-capture frame))
                     (window (harness-computer-endpoint--capture window))
                     (t (harness-computer-endpoint--desktop-capture))))
         (fallback (unless data (harness-computer-endpoint--frame-capture
                                 (harness-computer-endpoint--target-frame)))))
    (unless (or data fallback)
      (signal 'harness-error
              (list "This computer can capture no screen: no grim or scrot here, and no graphical Emacs frame")))
    (let ((bytes (or data fallback)))
      (harness-computer-endpoint--size bytes)
      (list :data (harness-computer-endpoint--base64 bytes)
            :mime "image/png"
            ;; `x-export-frames' gives no size, and decoding a PNG here
            ;; would cost more than it says; the harness need not know it.
            :width (and window (nth 2 (plist-get window :rect)))
            :height (and window (nth 3 (plist-get window :rect)))
            :note (cond ((and window (not (equal (plist-get window :kind) "frame")))
                         "the window named")
                        (frame "the Emacs frame named")
                        (data "the desktop")
                        (t "this computer has no screen capture, so this is its Emacs frame"))))))

;;;; Pointer and keyboard

(defun harness-computer-endpoint--int (value default min max)
  "Return VALUE as an integer within MIN and MAX, or DEFAULT."
  (let ((n (cond ((integerp value) value)
                 ((numberp value) (truncate value))
                 ((and (stringp value) (string-match-p "\\`-?[0-9]+\\'" value))
                  (string-to-number value)))))
    (let ((n (or n default)))
      (when n (max min (min max n))))))

(defun harness-computer-endpoint--button (value)
  "Return VALUE as a pointer button number, 1 by default."
  (let ((n (harness-computer-endpoint--int value 1 1 9))) n))

(defun harness-computer-endpoint--tool (&rest names)
  "Return the first executable of NAMES, or signal that none is here."
  (or (apply #'harness-computer-endpoint--program names)
      (signal 'harness-error (list "This computer cannot drive the pointer or the keyboard: no xdotool, ydotool or wtype here"))))

(defun harness-computer-endpoint--sway-cursor (command)
  "Send COMMAND to the sway seat's cursor, or signal when it cannot.
It is how the pointer of a headless Wayland compositor moves and clicks:
no program of the client itself can, and the compositor's IPC can."
  (let ((swaymsg (harness-computer-endpoint--program "swaymsg")))
    (unless swaymsg
      (signal 'harness-error (list "This computer cannot drive a pointer: no swaymsg here")))
    (harness-computer-endpoint--output swaymsg (list "seat" "-" "cursor" command))))

(defun harness-computer-endpoint--sway-button (button press)
  "Press or release BUTTON on the sway seat's cursor, PRESS non-nil to press."
  (harness-computer-endpoint--sway-cursor
   (format "%s button%d" (if press "press" "release") button)))

(defun harness-computer-endpoint--pointer (params)
  "Answer a pointer call of PARAMS."
  (let* ((action (downcase (or (harness-computer-endpoint--name (plist-get params :action)) "move")))
         (x (harness-computer-endpoint--int (plist-get params :x) nil 0 100000))
         (y (harness-computer-endpoint--int (plist-get params :y) nil 0 100000))
         (button (harness-computer-endpoint--button (plist-get params :button)))
         (amount (harness-computer-endpoint--int (plist-get params :amount) 1 1 100))
         (sway (and (eq (harness-computer-endpoint--session-type) 'wayland)
                    (harness-computer-endpoint--program "swaymsg")))
         (tool (unless sway (harness-computer-endpoint--tool "xdotool" "ydotool")))
         (xdotool (and tool (string-equal tool "xdotool"))))
    (pcase action
      ("move"
       (unless (and x y)
         (signal 'harness-error (list "pointer move needs x and y")))
       (cond
        (sway (harness-computer-endpoint--sway-cursor (format "set %d %d" x y)))
        (xdotool
         (harness-computer-endpoint--output tool (list "mousemove" "--sync"
                                                       (number-to-string x) (number-to-string y))))
        (t
         (harness-computer-endpoint--output tool (list "mousemove" "--absolute"
                                                       (number-to-string x) (number-to-string y)))))
       (list :done (format "moved the pointer to %d,%d" x y)))
      ("click"
       (if sway
           (progn
             (harness-computer-endpoint--sway-button button t)
             (harness-computer-endpoint--sway-button button nil))
         (harness-computer-endpoint--output tool (list "click" (number-to-string button))))
       (list :done (format "clicked button %d" button)))
      ((or "scroll" "wheel")
       (let* ((dir (downcase (or (harness-computer-endpoint--name
                                  (plist-get params :direction)) "down")))
              (code (if (member dir '("up" "left")) 4 5)))
         (dotimes (_ amount)
           (if sway
               (progn
                 (harness-computer-endpoint--sway-button code t)
                 (harness-computer-endpoint--sway-button code nil))
             (harness-computer-endpoint--output tool (list "click" (number-to-string code)))))
         (list :done (format "scrolled %s %d" dir amount))))
      ("drag"
       (unless (and x y) (signal 'harness-error (list "pointer drag needs x and y")))
       (cond
        (sway
         (harness-computer-endpoint--sway-button button t)
         (harness-computer-endpoint--sway-cursor (format "set %d %d" x y))
         (harness-computer-endpoint--sway-button button nil))
        (xdotool
         (harness-computer-endpoint--output tool (list "mousedown" (number-to-string button)))
         (harness-computer-endpoint--output
          tool (list "mousemove" "--sync" (number-to-string x) (number-to-string y)))
         (harness-computer-endpoint--output tool (list "mouseup" (number-to-string button))))
        (t (signal 'harness-error (list "This computer's pointer can move and click, not drag"))))
       (list :done (format "dragged to %d,%d" x y)))
      (_ (signal 'harness-error
                 (list (format "No pointer action %s; use move, click, scroll or drag" action)))))))

(defun harness-computer-endpoint--keyboard (params)
  "Answer a keyboard call of PARAMS."
  (let* ((action (downcase (or (harness-computer-endpoint--name (plist-get params :action)) "type")))
         (text (harness-computer-endpoint--name (plist-get params :text)))
         (key (harness-computer-endpoint--name (plist-get params :key)))
         (xdotool (harness-computer-endpoint--program "xdotool"))
         (ydotool (harness-computer-endpoint--program "ydotool"))
         (wtype (and (eq (harness-computer-endpoint--session-type) 'wayland)
                     (harness-computer-endpoint--program "wtype"))))
    (pcase action
      ("type"
       (unless text (signal 'harness-error (list "keyboard type needs text")))
       (when (> (length text) harness-computer-endpoint-max-text)
         (signal 'harness-error
                 (list (format "That text is longer than %d characters" harness-computer-endpoint-max-text))))
       (cond (xdotool (harness-computer-endpoint--output
                       xdotool (list "type" "--clearmodifiers" "--" text)))
             (wtype (harness-computer-endpoint--output wtype (list text)))
             (ydotool (harness-computer-endpoint--output ydotool (list "type" text)))
             (t (harness-computer-endpoint--tool "xdotool" "ydotool")))
       (list :done (format "typed %d characters" (length text))))
      ("key"
       (unless key (signal 'harness-error (list "keyboard key needs key")))
       (let ((key (replace-regexp-in-string "\\`RET\\'" "Return" key)))
         (cond (xdotool (harness-computer-endpoint--output
                         xdotool (list "key" "--clearmodifiers" key)))
               (wtype (harness-computer-endpoint--output wtype (list "-k" key)))
               (ydotool (harness-computer-endpoint--output ydotool (list "key" key)))
               (t (harness-computer-endpoint--tool "xdotool" "ydotool")))
         (list :done (format "pressed %s" key))))
      (_ (signal 'harness-error
                 (list (format "No keyboard action %s; use type or key" action)))))))

;;;; Clipboard and audio

(defun harness-computer-endpoint--clipboard (params)
  "Answer a clipboard call of PARAMS."
  (when (harness-computer-endpoint--display-override)
    (signal 'harness-error
            (list "The clipboard of a lent display is not read: this client has no selection there")))
  (unless (display-graphic-p)
    (signal 'harness-error (list "This Emacs draws no display, so it has no clipboard")))
  (let ((action (downcase (or (harness-computer-endpoint--name (plist-get params :action)) "get"))))
    (pcase action
      ("get"
       (let ((text (ignore-errors (gui-get-selection 'CLIPBOARD 'STRING))))
         (list :text (if (stringp text) (substring text 0 (min (length text)
                                                               harness-computer-endpoint-max-text))
                       ""))))
      ("set"
       (let ((text (or (plist-get params :text) "")))
         (unless (stringp text) (setq text (format "%s" text)))
         (when (> (length text) harness-computer-endpoint-max-text)
           (signal 'harness-error
                   (list (format "That text is longer than %d characters"
                                 harness-computer-endpoint-max-text))))
         (gui-set-selection 'CLIPBOARD text)
         (list :done (format "put %d characters on the clipboard" (length text)))))
      (_ (signal 'harness-error (list (format "No clipboard action %s; use get or set" action)))))))

(defun harness-computer-endpoint--audio (params)
  "Answer an audio call of PARAMS: list the devices, or record a little."
  (pcase (downcase (or (harness-computer-endpoint--name (plist-get params :action)) "list"))
    ("list"
     (let ((pactl (harness-computer-endpoint--program "pactl")))
       (list :sources (and pactl
                           (ignore-errors
                             (split-string
                              (harness-computer-endpoint--output
                               pactl '("list" "short" "sources") nil 5)
                              "\n" t)))
             :sinks (and pactl
                         (ignore-errors
                           (split-string
                            (harness-computer-endpoint--output
                             pactl '("list" "short" "sinks") nil 5)
                            "\n" t))))))
    ("record"
     (let* ((record (or (harness-computer-endpoint--program "pw-record" "parecord")
                        (signal 'harness-error
                                (list "This computer cannot record audio: no pw-record or parecord"))))
            (seconds (harness-computer-endpoint--int
                      (plist-get params :seconds) 3 1
                      harness-computer-endpoint-max-audio-seconds))
            (path (make-temp-file "harness-computer-audio-" nil ".wav")))
       (unwind-protect
           (progn
             (if (string-match-p "parecord\\'" record)
                 (harness-computer-endpoint--output
                  record (list "--format=s16le" "--rate=16000" "--channels=1"
                               "--file-format=wav" path)
                  nil (+ seconds 5))
               (harness-computer-endpoint--output
                record (list "--format" "s16" "--rate" "16000" "--channels" "1" path)
                nil (+ seconds 5)))
             (list :data (harness-computer-endpoint--base64
                          (with-temp-buffer
                            (set-buffer-multibyte nil)
                            (insert-file-contents-literally path)
                            (buffer-string)))
                   :mime "audio/wav"
                   :seconds seconds))
         (ignore-errors (delete-file path)))))
    (_ (signal 'harness-error (list "No audio action; use list or record")))))

;;;; The MCP server

(defun harness-computer-endpoint--tool-call (name params)
  "Run the computer-use tool NAME with PARAMS; return its structured answer."
  (pcase name
    ("info" (list :computer (harness-computer-endpoint-info)
                  :capabilities (harness-computer-endpoint-capabilities)
                  :window-scoped (harness-computer-endpoint-window-scoped-p)))
    ("screenshot" (harness-computer-endpoint--screenshot params))
    ("windows" (list :windows (harness-computer-endpoint--windows)))
    ("window" (list :window (harness-computer-endpoint--window (plist-get params :id))))
    ("pointer" (harness-computer-endpoint--pointer params))
    ("keyboard" (harness-computer-endpoint--keyboard params))
    ("clipboard" (harness-computer-endpoint--clipboard params))
    ("audio" (harness-computer-endpoint--audio params))
    (_ (signal 'harness-error (list (format "This computer answers no tool %s" name))))))

(defun harness-computer-endpoint--schema (properties &optional required)
  "Return a JSON schema object with PROPERTIES and REQUIRED."
  (append (list :type "object" :properties properties)
          (and required (list :required (apply #'vector required)))))

(defconst harness-computer-endpoint--tools
  '(("info" "Computer information" "Say what this computer is and which computer-use capabilities its implementation has." nil)
    ("screenshot" "Screen capture" "Capture the desktop, one window, or one Emacs frame, as a PNG." nil)
    ("windows" "Windows" "List the windows this computer can see, with their rectangles." nil)
    ("window" "Window" "Describe one window this computer can see." nil)
    ("pointer" "Pointer" "Move the pointer, click, scroll or drag, on this computer's desktop." nil)
    ("keyboard" "Keyboard" "Type text or press a key on this computer." nil)
    ("clipboard" "Clipboard" "Read or write this computer's clipboard." nil)
    ("audio" "Audio" "List this computer's audio devices, or record a few seconds from its microphone." nil))
  "The computer-use tools this client serves: (NAME TITLE DESCRIPTION SCHEMA).")

(defun harness-computer-endpoint--mcp-tool (entry)
  "Return ENTRY as an MCP tool of the computer server."
  (pcase-let ((`(,name ,title ,description ,schema) entry))
    (harness-mcp-make-tool
     :name name
     :title title
     :description description
     :schema (or schema (harness-computer-endpoint--schema
                         '(:computer (:type "string" :description "The computer this call is for; the harness resolves it."))
                         nil))
     :annotations (list :readOnlyHint (if (member name '("info" "screenshot" "windows" "window"))
                                          t :false))
     :handler (lambda (arguments _context)
                (condition-case err
                    (let ((value (harness-computer-endpoint--tool-call name arguments)))
                      (harness-mcp-call-result
                       (harness-truncate-end (format "%S" value) 2000)
                       :structured value))
                  (error
                   (harness-mcp-call-result
                    (error-message-string err) :is-error t)))))))

(defvar harness-computer-endpoint-server
  (harness-mcp-make-server
   :name "computer"
   :title "Computer"
   :version "1"
   :instructions "The computer this client runs on: its screen, its windows, its pointer and keyboard, its clipboard and its audio."
   :tools (mapcar #'harness-computer-endpoint--mcp-tool harness-computer-endpoint--tools))
  "The MCP server this client runs for the computer it is on.")

(defun harness-computer-endpoint-answer (method params respond)
  "Answer METHOD with PARAMS through RESPOND when it is for this computer.
Return non-nil when METHOD carries MCP for this computer (see the
Commentary), nil for any other method, which is left to the caller.  A
message this client refuses or cannot answer gets a JSON-RPC error."
  (when (string-prefix-p harness-computer-endpoint--prefix method)
    (when respond
      (let ((answered nil))
        (condition-case err
            (cond
             ((equal method harness-computer-endpoint-mcp-method)
              (let* ((computer (harness-computer-endpoint--name
                                (format "%s" (or (plist-get params :computer) ""))))
                     (server (harness-computer-endpoint--name
                              (format "%s" (or (plist-get params :server) "computer"))))
                     (token (harness-computer-endpoint--name (plist-get params :token)))
                     (expected (gethash computer harness-computer-endpoint--token)))
                (unless (and (equal computer (harness-computer-endpoint-id))
                             (member server harness-computer-endpoint--servers))
                  (signal 'harness-error
                          (list (format "This computer is no %s, and runs no tool server named %s"
                                        computer server))))
                (when (and expected token (not (harness-instance-equal-p expected token)))
                  (signal 'harness-error (list "The MCP token does not match this registration")))
                (when (and expected (null token))
                  (signal 'harness-error (list "The MCP message carries no token")))
                (let ((response (harness-mcp-serve harness-computer-endpoint-server
                                                   (plist-get params :message))))
                  (setq answered t)
                  (funcall respond response))))
             (t (error "This computer answers no request %s"
                       (string-remove-prefix harness-computer-endpoint--prefix method))))
          (error (unless answered
                   (harness-acp-respond-error respond harness-acp-error-method
                                              (error-message-string err)))))))
    t))

;;;; Registering this computer with a harness elsewhere

(defun harness-computer-endpoint--resources ()
  "Return the resources this computer offers, as plists.
They are the git repositories under the resource roots, at most
`harness-computer-endpoint-resource-depth' levels down, and those of
`harness-computer-endpoint-resources'."
  (let ((seen nil) (out nil))
    (dolist (root harness-computer-endpoint-resource-roots)
      (when (and (stringp root) (file-directory-p (expand-file-name root)))
        (let ((stack (list (cons (file-name-as-directory (expand-file-name root)) 0))))
          (while stack
            (let* ((pair (pop stack))
                   (dir (car pair))
                   (depth (cdr pair)))
              (when (and (not (member dir seen)) (< (length out) 200))
                (push dir seen)
                (when (file-exists-p (expand-file-name ".git" dir))
                  (push (list :kind "git-repo"
                              :name (file-name-nondirectory (directory-file-name dir))
                              :path (directory-file-name dir)
                              :branch (harness-computer-endpoint--branch dir))
                        out))
                (when (< depth harness-computer-endpoint-resource-depth)
                  (dolist (child (ignore-errors
                                   (directory-files dir t "\\`[^.]" t)))
                    (when (and (file-directory-p child)
                               (not (member (file-name-nondirectory child)
                                            '("node_modules" "target" "build" "dist" ".git"))))
                      (push (cons (file-name-as-directory child) (1+ depth)) stack))))))))))
    (append (nreverse out) harness-computer-endpoint-resources)))

(defun harness-computer-endpoint--branch (dir)
  "Return the branch checked out in DIR, or nil."
  (when-let* ((head (harness-computer-endpoint--read-file
                     (expand-file-name ".git/HEAD" dir))))
    (and (string-prefix-p "ref: refs/heads/" head)
         (string-remove-prefix "ref: refs/heads/" head))))

(defun harness-computer-endpoint--then (promise ok &optional err)
  "Call OK with PROMISE's value, or ERR with its error; return a promise."
  (harness-then promise ok (or err (lambda (e) (ignore e) nil))))

(defun harness-computer-endpoint-register (request &optional callback on-error)
  "Register this computer with the harness REQUEST talks to.
REQUEST is a function of (METHOD PARAMS) returning a promise, such as
`harness-ui-request'.  CALLBACK gets the record; ON-ERROR gets a
failure.  Nothing is registered without this call, on the harness's
own machine as anywhere else."
  (let ((info (harness-computer-endpoint-info)))
    (harness-computer-endpoint--then
     (funcall request "_harness/computer/register"
              (list :computer info
                    :secret (harness-computer-endpoint-secret)
                    :resources (harness-computer-endpoint--resources)
                    :servers (plist-get info :servers)))
     (lambda (result)
       (let ((record (plist-get result :computer)))
         (harness-computer-endpoint-set-token (plist-get record :id)
                                              (plist-get result :token))
         (when callback (funcall callback record))
         record))
     on-error)))

(defun harness-computer-endpoint-attach (request computer &optional callback on-error)
  "Attach this client to COMPUTER, registered before, with its secret.
REQUEST is a function of (METHOD PARAMS) returning a promise.  The
harness binds this client, and the token it answers with is what the
MCP messages carry."
  (harness-computer-endpoint--then
   (funcall request "_harness/computer/attach"
            (list :id computer :secret (harness-computer-endpoint-secret)))
   (lambda (result)
     (let ((record (plist-get result :computer)))
       (harness-computer-endpoint-set-token (plist-get record :id)
                                            (plist-get result :token))
       (when callback (funcall callback record))
       record))
   on-error))

(defun harness-computer-endpoint-refresh (request &optional computer callback on-error)
  "Report this computer's resources and capabilities again, through REQUEST.
COMPUTER defaults to the one this client attached to.  CALLBACK gets
the record."
  (let ((id (or computer harness-computer-endpoint--attached)))
    (if (null id)
        (when on-error
          (funcall on-error (list 'harness-error "This client has no computer attached")))
      (harness-computer-endpoint--then
       (funcall request "_harness/computer/update"
                (list :id id
                      :secret (harness-computer-endpoint-secret)
                      :resources (harness-computer-endpoint--resources)
                      :capabilities (harness-computer-endpoint-capabilities)
                      :display (harness-computer-endpoint--target-display)
                      :vnc harness-computer-endpoint-vnc-url
                      :vnc-socket harness-computer-endpoint-vnc-socket
                      :window-scoped (harness-computer-endpoint-window-scoped-p)))
       (lambda (record) (when callback (funcall callback record)) record)
       on-error))))

(defun harness-computer-endpoint-unregister (request computer &optional callback on-error)
  "Unregister COMPUTER from the harness REQUEST talks to."
  (harness-computer-endpoint--then
   (funcall request "_harness/computer/unregister" (list :id computer))
   (lambda (result)
     (when (equal computer harness-computer-endpoint--attached)
       (setq harness-computer-endpoint--attached nil))
     (remhash computer harness-computer-endpoint--token)
     (when callback (funcall callback result))
     result)
   on-error))

;;;; The interface the UI calls

(defun harness-computer-endpoint--token-for (computer)
  "Return the MCP token this client was given for COMPUTER, or nil."
  (gethash computer harness-computer-endpoint--token))

(defun harness-computer-endpoint-set-token (computer token)
  "Remember TOKEN, the MCP token the harness gave for COMPUTER."
  (when computer
    (puthash computer token harness-computer-endpoint--token)
    (setq harness-computer-endpoint--attached computer)
    token))

(defun harness-computer-endpoint-attached ()
  "Return the computer this client registered or attached to, or nil."
  harness-computer-endpoint--attached)

(defun harness-computer-endpoint-view (url)
  "Open URL, the screen of a computer, in the user's browser."
  (when (and (stringp url) (not (string-blank-p url)))
    (browse-url url)
    url))

(provide 'harness-computer-endpoint)
;;; harness-computer-endpoint.el ends here
