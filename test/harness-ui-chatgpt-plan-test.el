;;; harness-ui-chatgpt-plan-test.el --- Tests for signing in from the settings page  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The ChatGPT section of the settings page, and the page of its own.
;; Nothing here signs in or talks to OpenAI: the harness's answer to
;; `_harness/chatgpt-plan/status' is canned, and the sign-in and sign-out
;; calls are caught and answered with what the harness would say, so what
;; a button does is visible without a browser or an account.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-ui-chatgpt-plan--status)
(defvar harness-ui-chatgpt-plan--page-status)

(defconst harness-ui-chatgpt-plan-test--nobody
  '(:host-id "urn:uuid:11111111-2222-3333-4444-555555555555"
    :file "/tmp/chatgpt-plan.json" :active nil :accounts () :signed-in nil
    :plan-usage nil)
  "What the harness answers when nobody is signed in.
`:host-id' is there, so the section is drawn: a harness without the
chatgpt-plan module answers nothing at all, which is a different case.")

(defconst harness-ui-chatgpt-plan-test--paying
  '(:host-id "urn:uuid:11111111-2222-3333-4444-555555555555"
    :file "/tmp/chatgpt-plan.json" :active "acct-1" :signed-in t :plan-usage t
    :accounts ((:id "acct-1" :label "you@example.com" :email "you@example.com"
                :client-id "oaiapp_7Qd" :signed-in t :plan-usage t
                :expires-at 1793000000.0)))
  "What the harness answers for one account whose plan pays.")

(defconst harness-ui-chatgpt-plan-test--cannot-pay
  '(:host-id "urn:uuid:11111111-2222-3333-4444-555555555555"
    :file "/tmp/chatgpt-plan.json" :active "acct-2" :signed-in t :plan-usage nil
    :accounts ((:id "acct-2" :label "other@example.com" :email "other@example.com"
                :signed-in t :plan-usage nil :expires-at 1793000000.0)))
  "What the harness answers for an account whose grant cannot pay.")

(defvar harness-ui-chatgpt-plan-test--calls nil
  "The calls the tests' harness was asked to make, newest first: (:method :params).")

(defvar harness-ui-chatgpt-plan-test--status
  '(:host-id "urn:uuid:11111111-2222-3333-4444-555555555555"
    :file "/tmp/chatgpt-plan.json" :active nil :accounts () :signed-in nil
    :plan-usage nil)
  "The status the fake harness answers with; a test binds it.")

(defmacro harness-ui-chatgpt-plan-test-with (&rest body)
  "Load the modules the section needs, fake the harness, and run BODY.
`harness-ui-chatgpt-plan-test--calls' holds what was asked, so a test can say
what a button did without a browser."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil)
           (harness-ui-chatgpt-plan-test--calls nil)
           (default-directory (harness-test-temp-dir)))
       (dolist (m '(store project config acp ui ui-config ui-chatgpt-plan))
         (harness-test-load-module m))
       (unwind-protect
           (cl-letf (((symbol-function 'harness-ui-chatgpt-plan--on-event) #'ignore))
             ,@body)
         (dolist (b (harness-ui-chatgpt-plan--buffers)) (kill-buffer b))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-chatgpt-plan-test--answer (method params)
  "Return what the fake harness answers METHOD with PARAMS."
  (push (list :method method :params params) harness-ui-chatgpt-plan-test--calls)
  (pcase method
    ("_harness/chatgpt-plan/status" harness-ui-chatgpt-plan-test--status)
    ("_harness/chatgpt-plan/sign-in" harness-ui-chatgpt-plan-test--status)
    ("_harness/chatgpt-plan/sign-out" (list :revocation nil))
    ("_harness/config/describe"
     (list :cwd default-directory :root default-directory :project "test"
           :in-project t
           :files (list :project nil :project-exists :false :directory nil :directory-exists :false)
           :sections nil :modules nil :settings nil :policy nil :host-id nil))
    (_ nil)))

(defmacro harness-ui-chatgpt-plan-test-answering (&rest body)
  "Run BODY with the UI's requests answered by the fake harness."
  `(cl-letf (((symbol-function 'harness-ui-request)
              (lambda (method params)
                (harness-resolved (harness-ui-chatgpt-plan-test--answer method params))))
             ((symbol-function 'harness-ui-notify) #'ignore))
     ,@body))

(defun harness-ui-chatgpt-plan-test--called (method)
  "Return the params the fake harness last got for METHOD, or nil.
Also non-nil for a call with no params, which is why it answers a cons."
  (assoc method (mapcar (lambda (c) (cons (plist-get c :method) (plist-get c :params)))
                        harness-ui-chatgpt-plan-test--calls)))

(defun harness-ui-chatgpt-plan-test--text ()
  "Return the text of the current buffer."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun harness-ui-chatgpt-plan-test--open-settings ()
  "Open a settings page and wait for its data and the ChatGPT fetch."
  (harness-ui-chatgpt-plan-test-answering
   (set-buffer (harness-settings default-directory))
   (harness-test-wait (lambda () (and harness-ui-config--data
                                      (not harness-ui-config--loading)
                                      harness-ui-chatgpt-plan--fetched))
                      5 "settings and the ChatGPT fetch")))

;;;; The section on the settings page

(ert-deftest harness-ui-chatgpt-settings-shows-no-account-and-a-way-in ()
  "With nobody signed in, the section says so and offers [Sign in]."
  (harness-ui-chatgpt-plan-test-with
    (let ((harness-ui-chatgpt-plan-test--status harness-ui-chatgpt-plan-test--nobody))
      (harness-ui-chatgpt-plan-test--open-settings)
      (should (derived-mode-p 'harness-ui-config-mode))
      (let ((text (harness-ui-chatgpt-plan-test--text)))
        ;; The section is at the top, above the settings.
        (should (string-match-p "\\`\n Settings" text))
        (should (string-match-p "^ ChatGPT plan$" text))
        (should (string-match-p "No ChatGPT account is signed in" text))
        ;; It says what signing in gets you, in the words of the feature.
        (should (string-match-p "Plus or Pro" text))
        (should (string-match-p "No API key" text))
        (should (string-match-p "\\[Sign in\\]" text))
        ;; And nothing to sign out of yet.
        (should-not (string-match-p "\\[Sign out\\]" text)))
      ;; The section comes before the first settings heading.
      (let ((plan (string-match "^ ChatGPT plan$" (harness-ui-chatgpt-plan-test--text)))
            (sessions (string-match "^ New sessions$" (harness-ui-chatgpt-plan-test--text))))
        (should plan)
        (should (or (null sessions) (< plan sessions)))))))

(ert-deftest harness-ui-chatgpt-settings-shows-an-account-that-pays ()
  "A signed-in account shows whose it is, that the plan pays, and its buttons."
  (harness-ui-chatgpt-plan-test-with
    (let ((harness-ui-chatgpt-plan-test--status harness-ui-chatgpt-plan-test--paying))
      (harness-ui-chatgpt-plan-test--open-settings)
      (let ((text (harness-ui-chatgpt-plan-test--text)))
        (should (string-match-p "1 account signed in, and the plan pays for inference" text))
        (should (string-match-p "you@example.com" text))
        (should (string-match-p "plan pays for inference" text))
        (should (string-match-p "chatgpt:" text))
        (should (string-match-p "\\[Sign out\\]" text))
        (should (string-match-p "\\[Sign in again\\]" text))
        ;; The token itself is nowhere: the harness never sends one.
        (should-not (string-match-p "access-token\\|Bearer " text))))))

(ert-deftest harness-ui-chatgpt-settings-explains-a-grant-that-cannot-pay ()
  "An account whose grant lacks the plan scope says why, and can sign in again."
  (harness-ui-chatgpt-plan-test-with
    (let ((harness-ui-chatgpt-plan-test--status harness-ui-chatgpt-plan-test--cannot-pay))
      (harness-ui-chatgpt-plan-test--open-settings)
      (let ((text (harness-ui-chatgpt-plan-test--text)))
        (should (string-match-p "grant lacks chatgpt\\.tokens\\.use\\.direct" text))
        (should (string-match-p "cannot pay" text))
        ;; The way out is offered.
        (should (string-match-p "\\[Sign in again\\]" text))))))

(ert-deftest harness-ui-chatgpt-settings-is-absent-without-the-module ()
  "A harness without chatgpt-plan draws no section at all."
  (harness-ui-chatgpt-plan-test-with
    ;; Nothing at all is what the harness answers when the module is not
    ;; loaded, which is different from "nobody signed in".
    (let ((harness-ui-chatgpt-plan-test--status nil))
      (harness-ui-chatgpt-plan-test--open-settings)
      (should-not (string-match-p "ChatGPT plan" (harness-ui-chatgpt-plan-test--text))))))

(ert-deftest harness-ui-chatgpt-settings-signs-in-from-the-button ()
  "The [Sign in] button signs in, with no account named."
  (harness-ui-chatgpt-plan-test-with
    (let ((harness-ui-chatgpt-plan-test--status harness-ui-chatgpt-plan-test--nobody))
      (harness-ui-chatgpt-plan-test--open-settings)
      (harness-ui-chatgpt-plan-test-answering
       (harness-ui-chatgpt-plan--sign-in-here))
      (let ((call (harness-ui-chatgpt-plan-test--called "_harness/chatgpt-plan/sign-in")))
        (should call)
        ;; A first sign-in names no account: the flow registers one.
        (should-not (cdr call))))))

(ert-deftest harness-ui-chatgpt-settings-signs-out-after-asking ()
  "Signing out asks first, and does nothing when the answer is no."
  (harness-ui-chatgpt-plan-test-with
    (let ((harness-ui-chatgpt-plan-test--status harness-ui-chatgpt-plan-test--paying)
          (asked nil))
      (harness-ui-chatgpt-plan-test--open-settings)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (setq asked prompt) nil)))
        (harness-ui-chatgpt-plan-test-answering
         (harness-ui-chatgpt-plan--sign-out-here)))
      ;; It said whose account it was about to sign out.
      (should (string-match-p "you@example.com" asked))
      (should-not (harness-ui-chatgpt-plan-test--called "_harness/chatgpt-plan/sign-out"))
      ;; Answering yes does it, naming the active account.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (harness-ui-chatgpt-plan-test-answering
         (harness-ui-chatgpt-plan--sign-out-here)))
      (let ((call (harness-ui-chatgpt-plan-test--called "_harness/chatgpt-plan/sign-out")))
        (should call)
        (should (equal "acct-1" (plist-get (cdr call) :account)))))))

(ert-deftest harness-ui-chatgpt-settings-says-it-is-waiting ()
  "A sign-in is a person's to finish in a browser, so the page says it waits."
  (harness-ui-chatgpt-plan-test-with
    (let ((harness-ui-chatgpt-plan-test--status harness-ui-chatgpt-plan-test--nobody))
      (harness-ui-chatgpt-plan-test--open-settings)
      ;; The request is made but not answered, as it is while the browser
      ;; is open: the harness answers only when the callback arrives.
      (cl-letf (((symbol-function 'harness-ui-request)
                 (lambda (method params)
                   (push (list :method method :params params)
                         harness-ui-chatgpt-plan-test--calls)
                   (harness-make-promise))))
        (harness-ui-chatgpt-plan--sign-in-here))
      (should (equal "signing in" harness-ui-chatgpt-plan--waiting))
      (should (string-match-p "Signing in…" (harness-ui-chatgpt-plan-test--text)))
      ;; A page drawn again while it waits still says so.
      (harness-ui-config--render)
      (should (string-match-p "Signing in…" (harness-ui-chatgpt-plan-test--text))))))

;;;; The page of its own

(ert-deftest harness-ui-chatgpt-page-lists-every-account ()
  "The page of its own shows one line per account, with what each may do."
  (harness-ui-chatgpt-plan-test-with
    (let ((harness-ui-chatgpt-plan-test--status
           (list :host-id "urn:uuid:x" :active "acct-1" :signed-in t :plan-usage t
                 :accounts (list (list :id "acct-1" :email "a@example.com"
                                       :client-id "oaiapp_1" :signed-in t :plan-usage t
                                       :expires-at 1793000000.0)
                                 (list :id "acct-2" :email "b@example.com"
                                       :signed-in t :plan-usage nil
                                       :expires-at 1793000000.0)))))
      (harness-ui-chatgpt-plan-test-answering
       (harness-chatgpt-plan-page)
       (harness-test-wait (lambda () harness-ui-chatgpt-plan--page-status) 5 "the page"))
      (should (derived-mode-p 'harness-ui-chatgpt-plan-mode))
      (let ((text (harness-ui-chatgpt-plan-test--text)))
        (should (string-match-p "^ ChatGPT plan$" text))
        (should (string-match-p "a@example\\.com" text))
        (should (string-match-p "b@example\\.com" text))
        (should (string-match-p "client oaiapp_1" text))
        (should (string-match-p "2 accounts signed in" text))
        (should (string-match-p "\\[Sign in\\]" text))
        (should (string-match-p "\\[Sign out\\]" text))
        (should (string-match-p "\\[Read again\\]" text))
        ;; No token, ever.
        (should-not (string-match-p "access_token" text)))
      ;; RET on an account's line signs that one in again.
      (goto-char (point-min))
      (search-forward "b@example.com")
      (beginning-of-line)
      (should (equal "acct-2" (plist-get (harness-ui-chatgpt-plan--account-at-point) :id)))
      (harness-ui-chatgpt-plan-test-answering
       (call-interactively #'harness-ui-chatgpt-plan-sign-in-this))
      (let ((call (harness-ui-chatgpt-plan-test--called "_harness/chatgpt-plan/sign-in")))
        (should (equal "acct-2" (plist-get (cdr call) :account)))))))

(ert-deftest harness-ui-chatgpt-page-says-what-to-do-with-no-account ()
  "An empty page still says how to get an account, rather than showing nothing."
  (harness-ui-chatgpt-plan-test-with
    (let ((harness-ui-chatgpt-plan-test--status harness-ui-chatgpt-plan-test--nobody))
      (harness-ui-chatgpt-plan-test-answering
       (harness-chatgpt-plan-page)
       (harness-test-wait (lambda () harness-ui-chatgpt-plan--page-status) 5 "the page"))
      (let ((text (harness-ui-chatgpt-plan-test--text)))
        (should (string-match-p "No account yet" text))
        (should (string-match-p "\\[Sign in\\]" text))))))

(ert-deftest harness-ui-chatgpt-page-follows-the-accounts ()
  "A change the harness announces is read again without asking the user to."
  (harness-ui-chatgpt-plan-test-with
    (let ((harness-ui-chatgpt-plan-test--status harness-ui-chatgpt-plan-test--nobody))
      (harness-ui-chatgpt-plan-test-answering
       (harness-chatgpt-plan-page)
       (harness-test-wait (lambda () harness-ui-chatgpt-plan--page-status) 5 "the page"))
      (should (string-match-p "No account yet" (harness-ui-chatgpt-plan-test--text)))
      ;; Signing in elsewhere says so on the bus; the page reads again.
      (let ((harness-ui-chatgpt-plan-test--status harness-ui-chatgpt-plan-test--paying)
            (buf (current-buffer)))
        (harness-ui-chatgpt-plan-test-answering
         (with-current-buffer buf
           (harness-ui-chatgpt-plan--on-event "chatgpt-plan/accounts-changed" nil))
         (harness-test-wait
          (lambda () (with-current-buffer buf
                       (string-match-p "you@example\\.com"
                                       (buffer-substring-no-properties (point-min) (point-max)))))
          5 "the account on the page"))))))

(ert-deftest harness-ui-chatgpt-page-has-a-menu-entry ()
  "The page is reachable from the harness menu, next to the settings."
  (harness-ui-chatgpt-plan-test-with
    (should (fboundp 'harness-chatgpt-plan-page))
    (should (commandp #'harness-chatgpt-plan-page))
    ;; The commands the page binds are the ones its keys name.
    (with-temp-buffer
      (harness-ui-chatgpt-plan-mode)
      (should (eq #'harness-ui-chatgpt-plan-sign-in (key-binding (kbd "s"))))
      (should (eq #'harness-ui-chatgpt-plan-sign-out (key-binding (kbd "o"))))
      (should (eq #'harness-ui-chatgpt-plan-revert (key-binding (kbd "g"))))
      (should (eq #'harness-ui-chatgpt-plan-sign-in-this (key-binding (kbd "RET")))))))

(provide 'harness-ui-chatgpt-plan-test)
;;; harness-ui-chatgpt-plan-test.el ends here
