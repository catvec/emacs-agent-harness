;;; harness-ui-chatgpt-plan.el --- Sign in with ChatGPT from the settings page  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The user's side of signing in with ChatGPT (harness-chatgpt-plan.el
;; does the OAuth in the harness process; harness-provider-responses.el
;; spends the tokens).  A plan that pays for inference is something you
;; turn on once and look at now and then, and the place you look for it is
;; the settings page:
;;
;; - A "ChatGPT plan" section at the top of `harness-settings', above the
;;   settings themselves, saying whether an account is signed in, whose it
;;   is, whether its plan may pay (the grant must include
;;   `chatgpt.tokens.use.direct'), and when the token lapses.  Its buttons
;;   are [Sign in] -- which opens the browser at the authorization URL and
;;   waits for the loopback callback -- [Sign in again] for an account
;;   that cannot pay or has to sign in again, and [Sign out], which
;;   revokes the session at ChatGPT and clears the tokens here.
;; - A page of its own, `harness-chatgpt-plan-page' (C-c h G), one line
;;   per account: its email, whether it may pay, when its token lapses and
;;   its issued client id.  RET signs that account in again, `s' signs in,
;;   `o' signs out, `g' reads the state again.  The page is what more than
;;   one account needs; the button in the section acts on the active one.
;;
;; Nothing here ever holds a token: `harness-chatgpt-plan-status' drops
;; them before they cross the wire, and the browser is the only place a
;; credential is typed.  The section reads `_harness/chatgpt-plan/status'
;; when the page fetches its data (`harness-ui-config-load-hooks'), and
;; again when `chatgpt-plan/accounts-changed' says the accounts moved.
;;
;; A sign-in waits on a person: the browser opens, they approve, the
;; callback arrives, and only then does the harness answer.  So each
;; request here says in the page that it waits, rather than looking
;; frozen, and the message that follows says how it went.

;;; Code:

(require 'harness-ui)
(require 'harness-ui-config)

(defvar harness-ui-chatgpt-plan--status nil
  "The last `chatgpt-plan/status' answer, or nil when the harness has none.
It stays nil for a harness whose chatgpt-plan module is not loaded,
which answers nothing; `harness-ui-chatgpt-plan--fetched' tells that apart
from a request that has not been answered yet.")
(defvar harness-ui-chatgpt-plan--fetched nil
  "Non-nil once a status request has been answered, whatever it said.")
(defvar harness-ui-chatgpt-plan--error nil
  "Message of the last failed status request, or nil.")
(defvar harness-ui-chatgpt-plan--waiting nil
  "What a request of this module is waiting for, as a short word, or nil.")
(defvar-local harness-ui-chatgpt-plan--page-status nil
  "The status the ChatGPT-plan page last drew, which is its own.")

;;;; Talking to the harness

(defun harness-ui-chatgpt-plan--call (method params &optional on-success on-error)
  "Call the harness METHOD with PARAMS; ON-SUCCESS or ON-ERROR gets the answer.
A rejection is shown in the echo area when ON-ERROR says nothing, as
`harness-ui-call' does, and the waiting state is cleared either way."
  (let ((buf (current-buffer)))
    (harness-ui-call
     method params
     (lambda (value)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq harness-ui-chatgpt-plan--waiting nil)
           (when on-success (funcall on-success value)))))
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq harness-ui-chatgpt-plan--waiting nil)
           (if on-error
               (funcall on-error err)
             (harness-ui--report-failed method err))))))))

(defun harness-ui-chatgpt-plan-refresh (&optional callback)
  "Ask the harness what the ChatGPT accounts are, then call CALLBACK.
The answer is kept for the buffer the request was made in: the settings
page and the page of its own each keep their own."
  (let ((buf (current-buffer)))
    (harness-ui-chatgpt-plan--call
     "_harness/chatgpt-plan/status" nil
     (lambda (status)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if (derived-mode-p 'harness-ui-chatgpt-plan-mode)
               (setq harness-ui-chatgpt-plan--page-status status)
             (setq harness-ui-chatgpt-plan--status status
                   harness-ui-chatgpt-plan--fetched t))
           (setq harness-ui-chatgpt-plan--error nil)
           (when callback (funcall callback)))))
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq harness-ui-chatgpt-plan--error (harness-error-message err))
           (when callback (funcall callback))))))))

(defun harness-ui-chatgpt-plan--status ()
  "Return the status of the buffer this is called in."
  (if (derived-mode-p 'harness-ui-chatgpt-plan-mode)
      harness-ui-chatgpt-plan--page-status
    harness-ui-chatgpt-plan--status))

;;;; Reading it

(defun harness-ui-chatgpt-plan--true (value)
  "Non-nil when VALUE, which came over ACP, is true.
A JSON false is `:false', which is not nil and must not read as true."
  (and value (not (eq value :false))))

(defun harness-ui-chatgpt-plan--accounts ()
  "Return the account plists of the status."
  (append (plist-get (harness-ui-chatgpt-plan--status) :accounts) nil))

(defun harness-ui-chatgpt-plan--signed-in-p ()
  "Non-nil when at least one account holds a usable token."
  (harness-ui-chatgpt-plan--true (plist-get (harness-ui-chatgpt-plan--status) :signed-in)))

(defun harness-ui-chatgpt-plan-usage-p (&optional account)
  "Non-nil when ACCOUNT, or any account, may pay for inference.
That is when its granted scopes contain `chatgpt.tokens.use.direct'."
  (if account
      (harness-ui-chatgpt-plan--true (plist-get account :plan-usage))
    (harness-ui-chatgpt-plan--true (plist-get (harness-ui-chatgpt-plan--status) :plan-usage))))

(defun harness-ui-chatgpt-plan--label (account)
  "Return what to call ACCOUNT: its email, else its label, else its id."
  (or (plist-get account :email) (plist-get account :label) (plist-get account :id)
      "this account"))

(defun harness-ui-chatgpt-plan--active-account ()
  "Return the account the harness has selected, else the only one there is."
  (let ((accounts (harness-ui-chatgpt-plan--accounts))
        (active (plist-get (harness-ui-chatgpt-plan--status) :active)))
    (or (cl-find active accounts :key (lambda (a) (plist-get a :id)) :test #'equal)
        (car accounts))))

(defun harness-ui-chatgpt-plan--expiry (account)
  "Return when ACCOUNT's access token lapses, in words."
  (let ((at (plist-get account :expires-at)))
    (cond
     ((not (numberp at)) "expiry not known")
     ((<= at (float-time)) "token expired, refreshed on the next call")
     (t (format "token lapses %s" (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time at)))))))

(defun harness-ui-chatgpt-plan--grant (account)
  "Return whether ACCOUNT may pay for inference, in words."
  (if (harness-ui-chatgpt-plan-usage-p account)
      "plan pays for inference"
    "cannot pay: the grant lacks chatgpt.tokens.use.direct"))

(defun harness-ui-chatgpt-plan--summary ()
  "Return a sentence saying where the ChatGPT plan stands, and what to do.
It is the line under the title, and it makes the state readable without
opening anything."
  (let ((accounts (harness-ui-chatgpt-plan--accounts))
        (status (harness-ui-chatgpt-plan--status)))
    (cond
     (harness-ui-chatgpt-plan--error
      (format "Could not read the ChatGPT state: %s" harness-ui-chatgpt-plan--error))
     ((null status)
      "Reading the ChatGPT state…")
     ((null accounts)
      "No ChatGPT account is signed in.  An eligible Plus or Pro plan can pay for inference: no API key, nothing to install.")
     ((harness-ui-chatgpt-plan-usage-p)
      (format "%d account%s signed in, and the plan pays for inference.  Its models appear as chatgpt:… in the model picker."
              (length accounts) (if (= 1 (length accounts)) "" "s")))
     ((harness-ui-chatgpt-plan--signed-in-p)
      "An account is signed in, but its grant lacks chatgpt.tokens.use.direct, so the plan cannot pay.  Sign in again and allow it.")
     (t
      "An account is signed in but has to sign in again: its tokens were refused or cleared."))))

;;;; Signing in and out

(defun harness-ui-chatgpt-plan-sign-in (&optional account)
  "Sign in to ChatGPT, or sign ACCOUNT in again when one is given.
The browser opens at the authorization URL and the harness answers when
the callback arrives, so this says it is waiting rather than looking
frozen: a sign-in is a person's to finish in their browser."
  (setq harness-ui-chatgpt-plan--waiting "signing in")
  (message "Harness: opening your browser to sign in to ChatGPT…")
  (harness-ui-chatgpt-plan--redraw)
  (let ((buf (current-buffer)))
    (harness-ui-chatgpt-plan--call
     "_harness/chatgpt-plan/sign-in"
     (when account (list :account (plist-get account :id)))
     (lambda (status)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if (derived-mode-p 'harness-ui-chatgpt-plan-mode)
               (setq harness-ui-chatgpt-plan--page-status status)
             (setq harness-ui-chatgpt-plan--status status))
           (message "Harness: signed in to ChatGPT%s"
                    (if-let* ((one (car (harness-ui-chatgpt-plan--accounts))))
                        (format " as %s" (harness-ui-chatgpt-plan--label one))
                      ""))
           (harness-ui-chatgpt-plan--redraw))))
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq harness-ui-chatgpt-plan--waiting nil)
           (message "Harness: signing in to ChatGPT did not finish: %s"
                    (harness-error-message err))
           (harness-ui-chatgpt-plan--redraw)))))))

(defun harness-ui-chatgpt-plan-sign-out (&optional account)
  "Sign ACCOUNT out of ChatGPT, revoking its session, after asking.
With none, it is the account whose line point is on, else the active one."
  (let* ((account (or account (harness-ui-chatgpt-plan--account-at-point)))
         (label (if account (harness-ui-chatgpt-plan--label account) "your ChatGPT account")))
    (when (y-or-n-p (format "Sign %s out of ChatGPT?  Its session is revoked at ChatGPT, and its tokens are cleared here. " label))
      (setq harness-ui-chatgpt-plan--waiting "signing out")
      (harness-ui-chatgpt-plan--redraw)
      (let ((buf (current-buffer)))
        (harness-ui-chatgpt-plan--call
         "_harness/chatgpt-plan/sign-out"
         (when account (list :account (plist-get account :id)))
         (lambda (result)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (if-let* ((unconfirmed (plist-get result :revocation)))
                   (message "Harness: signed out of ChatGPT here; the revocation was not confirmed (%s)"
                            unconfirmed)
                 (message "Harness: signed out of ChatGPT, and its session was revoked"))
               (harness-ui-chatgpt-plan-refresh #'harness-ui-chatgpt-plan--redraw)))))
         (lambda (err)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (setq harness-ui-chatgpt-plan--waiting nil)
               (message "Harness: could not sign out of ChatGPT: %s"
                        (harness-error-message err))
               (harness-ui-chatgpt-plan-refresh #'harness-ui-chatgpt-plan--redraw))))))))

;;;; The section on the settings page

(declare-function harness-ui-config--insert-heading "harness-ui-config" (title &optional doc))
(declare-function harness-ui-config--button "harness-ui-config" (label help fn &optional redraws))
(declare-function harness-ui-config--render "harness-ui-config" ())

(defun harness-ui-chatgpt-plan--insert-waiting ()
  "Insert the line saying what this module waits for, when it waits."
  (when harness-ui-chatgpt-plan--waiting
    (insert "   "
            (propertize (format "%s…  finish it in your browser; this page says how it went."
                                (capitalize harness-ui-chatgpt-plan--waiting))
                        'face 'harness-dim-face)
            "\n")))

(defun harness-ui-chatgpt-plan--insert-section ()
  "Insert the ChatGPT-plan section above the settings of the page.
Nothing is drawn for a harness whose chatgpt-plan module is not loaded:
a section offering a sign-in the harness cannot do would be a lie."
  (when (and harness-ui-chatgpt-plan--fetched (plist-get (harness-ui-chatgpt-plan--status) :host-id))
    (harness-ui-config--insert-heading
     "ChatGPT plan"
     "An eligible ChatGPT Plus or Pro plan can pay for inference: sign in, and its models appear as chatgpt:…  No API key, and nothing to install.")
    (insert " " (propertize (harness-ui-chatgpt-plan--summary) 'face 'harness-settings-doc-face) "\n")
    (dolist (account (harness-ui-chatgpt-plan--accounts))
      (insert "   " (propertize (harness-ui-chatgpt-plan--label account) 'face 'harness-settings-label-face)
              (propertize (format "  %s  ·  %s" (harness-ui-chatgpt-plan--grant account)
                                  (harness-ui-chatgpt-plan--expiry account))
                          'face 'harness-settings-doc-face)
              "\n"))
    (harness-ui-chatgpt-plan--insert-waiting)
    (insert " ")
    (if (null (harness-ui-chatgpt-plan--accounts))
        (harness-ui-config--button
         "Sign in" "Open your browser at the ChatGPT sign-in page (it is a person's to finish there)"
         #'harness-ui-chatgpt-plan--sign-in-here t)
      (harness-ui-config--button
       "Sign in again" "Sign the active account in again, to accept a new grant"
       #'harness-ui-chatgpt-plan--sign-in-again-here t)
      (insert "  ")
      (harness-ui-config--button
       "Sign out" "Revoke the session at ChatGPT and clear the tokens here"
       #'harness-ui-chatgpt-plan--sign-out-here t)
      (insert "  ")
      (harness-ui-config--button
       "Accounts…" "Every account signed in, with what each may do (C-c h G)"
       #'harness-chatgpt-plan-page t))
    (insert "\n\n")))

(defun harness-ui-chatgpt-plan--sign-in-here ()
  "Sign in, from a button of the settings page."
  (interactive)
  (harness-ui-chatgpt-plan-sign-in))

(defun harness-ui-chatgpt-plan--sign-in-again-here ()
  "Sign the active account in again, from a button of the settings page."
  (interactive)
  (harness-ui-chatgpt-plan-sign-in (harness-ui-chatgpt-plan--active-account)))

(defun harness-ui-chatgpt-plan--sign-out-here ()
  "Sign the active account out, from a button of the settings page.
The settings page lists no account of its own to point at, so it is the
active one; the page of its own signs out whichever line point is on."
  (interactive)
  (harness-ui-chatgpt-plan-sign-out (harness-ui-chatgpt-plan--active-account)))

(defun harness-ui-chatgpt-plan--redraw ()
  "Draw the page this is called in again, whichever page it is."
  (cond
   ((derived-mode-p 'harness-ui-config-mode) (harness-ui-config--render))
   ((derived-mode-p 'harness-ui-chatgpt-plan-mode) (harness-ui-chatgpt-plan--render))))

;;;; The page of its own

(defvar harness-ui-chatgpt-plan-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "s") #'harness-ui-chatgpt-plan-sign-in)
    (define-key map (kbd "o") #'harness-ui-chatgpt-plan-sign-out)
    (define-key map (kbd "g") #'harness-ui-chatgpt-plan-revert)
    (define-key map (kbd "RET") #'harness-ui-chatgpt-plan-sign-in-this)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-chatgpt-plan-mode'.")

(define-derived-mode harness-ui-chatgpt-plan-mode special-mode "ChatGPT plan"
  "Major mode of the ChatGPT-plan page.
\\{harness-ui-chatgpt-plan-mode-map}"
  (setq truncate-lines t buffer-read-only t))

(defun harness-ui-chatgpt-plan--account-at-point ()
  "Return the account whose line point is on, or nil."
  (get-text-property (line-beginning-position) 'harness-ui-chatgpt-plan-account))

(defun harness-ui-chatgpt-plan--page-button (label help fn)
  "Insert a button LABEL with tooltip HELP calling FN in this page."
  (let ((buf (current-buffer)))
    (harness-ui-button label (lambda () (with-current-buffer buf (funcall fn)))
                       :help help)))

(defun harness-ui-chatgpt-plan--render ()
  "Draw the ChatGPT-plan page from the status it holds."
  (let ((inhibit-read-only t)
        (position (point)))
    (erase-buffer)
    (insert "\n " (propertize "ChatGPT plan" 'face 'harness-settings-title-face) "\n\n ")
    (insert (propertize (harness-ui-chatgpt-plan--summary) 'face 'harness-settings-doc-face) "\n")
    (harness-ui-chatgpt-plan--insert-waiting)
    (insert "\n ")
    (harness-ui-chatgpt-plan--page-button "[Sign in]" "Sign a ChatGPT account in (s)"
                                     #'harness-ui-chatgpt-plan-sign-in)
    (insert "  ")
    (harness-ui-chatgpt-plan--page-button "[Sign out]" "Revoke and clear an account's tokens (o)"
                                     #'harness-ui-chatgpt-plan-sign-out)
    (insert "  ")
    (harness-ui-chatgpt-plan--page-button "[Read again]" "Ask the harness for the state (g)"
                                     #'harness-ui-chatgpt-plan-revert)
    (insert "\n\n")
    (harness-ui-chatgpt-plan--insert-accounts)
    (goto-char (min position (point-max)))))

(defun harness-ui-chatgpt-plan--insert-accounts ()
  "Insert a line per account signed in, the fold of each saying what it may do."
  (let ((accounts (harness-ui-chatgpt-plan--accounts)))
    (if (null accounts)
        (insert " " (propertize (concat "No account yet.  Sign in opens your browser at the"
                                        " authorization page; come back when it says you are"
                                        " signed in.")
                                'face 'harness-dim-face)
                "\n")
      (insert " " (propertize "Account" 'face 'harness-settings-label-face) "\n")
      (dolist (account accounts)
        (let ((start (point)))
          (insert " "
                  (propertize (harness-ui-chatgpt-plan--label account)
                              'face 'harness-settings-label-face)
                  "\n")
          (put-text-property start (point) 'harness-ui-chatgpt-plan-account account))
        (insert "   " (propertize (harness-ui-chatgpt-plan--account-line account)
                                  'face 'harness-settings-doc-face)
                "\n\n")))))

(defun harness-ui-chatgpt-plan--account-line (account)
  "Return what ACCOUNT may do, on one line."
  (let ((client (plist-get account :client-id)))
    (format "%s  ·  %s%s"
            (harness-ui-chatgpt-plan--grant account)
            (harness-ui-chatgpt-plan--expiry account)
            (if (stringp client) (format "  ·  client %s" client) ""))))


;;;###autoload
(defun harness-chatgpt-plan-page ()
  "Show the ChatGPT-plan page: the accounts signed in, and what each may do."
  (interactive)
  (let ((buf (get-buffer-create "*harness chatgpt*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-chatgpt-plan-mode)
        (harness-ui-chatgpt-plan-mode))
      (setq harness-ui-chatgpt-plan--page-status nil
            harness-ui-chatgpt-plan--error nil
            harness-ui-chatgpt-plan--waiting nil)
      (harness-ui-chatgpt-plan--render)
      (harness-ui-chatgpt-plan-refresh #'harness-ui-chatgpt-plan--render))
    (pop-to-buffer buf)))

(defun harness-ui-chatgpt-plan-sign-in-this ()
  "Sign the account whose line point is on in again."
  (interactive)
  (if-let* ((account (harness-ui-chatgpt-plan--account-at-point)))
      (harness-ui-chatgpt-plan-sign-in account)
    (harness-ui-chatgpt-plan-sign-in)))

(defun harness-ui-chatgpt-plan-revert ()
  "Read the ChatGPT state again."
  (interactive)
  (harness-ui-chatgpt-plan-refresh #'harness-ui-chatgpt-plan--redraw))

;;;; Following the harness

(defun harness-ui-chatgpt-plan--on-event (event _args)
  "Read the state again when EVENT says the ChatGPT accounts changed."
  (when (equal event "chatgpt-plan/accounts-changed")
    (dolist (buf (harness-ui-chatgpt-plan--buffers))
      (with-current-buffer buf
        (harness-ui-chatgpt-plan-refresh #'harness-ui-chatgpt-plan--redraw)))))

(defun harness-ui-chatgpt-plan--buffers ()
  "Return the settings pages and ChatGPT pages open now."
  (cl-remove-if-not
   (lambda (b)
     (with-current-buffer b
       (or (derived-mode-p 'harness-ui-chatgpt-plan-mode)
           (derived-mode-p 'harness-ui-config-mode))))
   (buffer-list)))

(defun harness-ui-chatgpt-plan--on-redraw ()
  "Fetch the ChatGPT state for every page open, after a reload or reconnect.
As `harness-ui-config--redraw-all' does for the settings: the hook runs
as a connection opens, so it is put off a moment."
  (dolist (buf (harness-ui-chatgpt-plan--buffers))
    (with-current-buffer buf
      (harness-debounce (list 'harness-ui-chatgpt-plan-refresh buf) 0.15
                        (lambda ()
                          (when (buffer-live-p buf)
                            (with-current-buffer buf
                              (harness-ui-chatgpt-plan-refresh #'harness-ui-chatgpt-plan--redraw))))))))

(defun harness-ui-chatgpt-plan--menu-install ()
  "Put the ChatGPT-plan page in the harness menu, after Settings."
  (condition-case err
      (transient-append-suffix 'harness-menu "S"
        '("h" "ChatGPT plan…" harness-chatgpt-plan-page
          :if (lambda () (harness-ui--command-available-p 'harness-chatgpt-plan-page))))
    (error (harness-log 'warn "chatgpt: no menu entry: %s" (error-message-string err)))))

(defun harness-ui-chatgpt-plan--init ()
  "Wire the ChatGPT section into the settings page, and follow the accounts."
  (add-hook 'harness-ui-config-sections-functions #'harness-ui-chatgpt-plan--insert-section)
  (add-hook 'harness-ui-config-load-hooks #'harness-ui-chatgpt-plan-refresh)
  (add-hook 'harness-ui-event-functions #'harness-ui-chatgpt-plan--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-chatgpt-plan--on-redraw)
  (harness-ui-chatgpt-plan--menu-install)
  (define-key harness-ui-map (kbd "h") #'harness-chatgpt-plan-page))

(defun harness-ui-chatgpt-plan--shutdown ()
  "Take the ChatGPT section out of the settings page, and stop following it."
  (remove-hook 'harness-ui-config-sections-functions #'harness-ui-chatgpt-plan--insert-section)
  (remove-hook 'harness-ui-config-load-hooks #'harness-ui-chatgpt-plan-refresh)
  (remove-hook 'harness-ui-event-functions #'harness-ui-chatgpt-plan--on-event)
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-chatgpt-plan--on-redraw)
  (ignore-errors (transient-remove-suffix 'harness-menu "h"))
  (when (eq (lookup-key harness-ui-map (kbd "h")) #'harness-chatgpt-plan-page)
    (define-key harness-ui-map (kbd "h") nil)))

(harness-define-module 'ui-chatgpt-plan
  :doc "Sign in with ChatGPT from the settings page, with the accounts and what they may do."
  :requires nil
  :init #'harness-ui-chatgpt-plan--init
  :shutdown #'harness-ui-chatgpt-plan--shutdown)

(provide 'harness-ui-chatgpt-plan)
;;; harness-ui-chatgpt-plan.el ends here
