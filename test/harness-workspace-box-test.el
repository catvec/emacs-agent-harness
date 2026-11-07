;;; harness-workspace-box-test.el --- Tests for the workspace computer  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-workspace-box--records)
(defvar harness-workspace-box--processes)
(defvar harness-workspace-box--loaded)
(defvar harness-workspace-box--subscribed)
(defvar harness-workspace-box-tool-directories)
(defvar harness-workspace-box-tools)
(defvar harness-workspace-box-autostart-browser)
(defvar harness-acp-remote-tunnels)

(defmacro harness-workspace-box-test-with (&rest body)
  "Load the box with a fresh state, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-workspace-box-tool-directories nil)
           (harness-workspace-box-tools '(Xvfb x11vnc xdotool))
           (harness-workspace-box-autostart-browser nil))
       (harness-test-load-module 'store)
       (harness-test-load-module 'workspace-box)
       ;; The browser mutations ask the workspace for its record and for the
       ;; resources answer; these tests are about the profile, so the state
       ;; layer answers the little they read.
       (unless (harness-method-exists-p 'workspace/get)
         (harness-defmethod workspace/get (id)
           "Answer ID as the state layer does."
           (list :id id :name "Test")))
       (unless (harness-method-exists-p 'workspace/resources/status)
         (harness-defmethod workspace/resources/status (id)
           "Answer the resources state the browser mutations read."
           (list :id id :status "ready" :metadata-only t)))
       (clrhash harness-workspace-box--records)
       (clrhash harness-workspace-box--processes)
       (setq harness-workspace-box--loaded nil
             harness-workspace-box--subscribed nil)
       (unwind-protect (progn ,@body)
         (harness-workspace-box--shutdown)
         (harness-workspace-box--stop-processes "w-1")))))

(defun harness-workspace-box-test-fake-running (id)
  "Store a running record for ID whose pids look alive."
  (setq harness-workspace-box--loaded t)
  (puthash id (list :workspace id :backend "local" :state "running"
                    :control "agent" :display "127.0.0.1:90"
                    :width 1280 :height 800 :vnc-port 5901 :web-port 6080
                    :token "token-1" :pids '(:xvfb 11 :vnc 12 :web 13))
           harness-workspace-box--records))

(ert-deftest harness-workspace-box-status-says-what-is-missing ()
  "Without the tools the computer is unavailable and names them, not a screen."
  (harness-workspace-box-test-with
    (let ((exec-directory (harness-test-temp-dir))
          (status (harness-call 'workspace/box/status "w-1")))
      (should (equal "local" (plist-get status :backend)))
      (should-not (harness-json-true-p (plist-get status :running)))
      (should-not (harness-json-true-p (plist-get status :available)))
      (should (equal "stopped" (plist-get status :state)))
      (should (equal "box-tools-missing" (plist-get (plist-get status :reason) :code)))
      (should (memq 'Xvfb (plist-get status :missing)))
      (should-not (plist-get status :url))
      (should-not (plist-get status :socket))
      (should-not (plist-get status :token))
      (let ((vnc (harness-call 'workspace/box/vnc "w-1")))
        (should-not (harness-json-true-p (plist-get vnc :available)))
        (should-not (plist-get vnc :url))
        (should-not (plist-get vnc :socket))
        (should (equal "box-tools-missing"
                       (plist-get (plist-get vnc :reason) :code)))))))

(ert-deftest harness-workspace-box-status-has-the-screen ()
  "A running record answers its display, VNC page and RFB socket."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t)))
      (let ((status (harness-call 'workspace/box/status "w-1")))
        (should (harness-json-true-p (plist-get status :running)))
        (should (harness-json-true-p (plist-get status :available)))
        (should (equal "running" (plist-get status :health)))
        (should (equal "127.0.0.1:90" (plist-get status :display)))
        (should (equal "http://127.0.0.1:6080/vnc_lite.html?path=websockify%3Ftoken%3Dtoken-1&autoconnect=1"
                       (plist-get status :url)))
        (should (equal "ws://127.0.0.1:6080/websockify?token=token-1&workspace=w-1"
                       (plist-get status :socket)))
        (should-not (plist-get status :token))
        (let ((vnc (harness-call 'workspace/box/vnc "w-1")))
          (should (harness-json-true-p (plist-get vnc :available)))
          (should (equal (plist-get status :socket) (plist-get vnc :socket)))
          (should-not (plist-get vnc :token)))))))

(ert-deftest harness-workspace-box-control-refuses-the-agent ()
  "Take over gives the reviewer the screen; an input method refuses until
control is returned, and the state is on disk."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t))
              ((symbol-function 'harness-workspace-box--call)
               (lambda (&rest _) (list 0 "" nil)))
              ((symbol-function 'harness-workspace-box--tool)
               (lambda (&rest _) "tool")))
      (should (equal "user" (plist-get (harness-call 'workspace/box/take-over "w-1")
                                      :control)))
      (should (equal "user" (plist-get (harness-call 'workspace/box/status "w-1")
                                      :control)))
      (should-error (harness-call 'workspace/box/click "w-1" 10 20)
                    :type 'harness-error)
      (should-error (harness-call 'workspace/box/type "w-1" "hello")
                    :type 'harness-error)
      (should (equal "agent" (plist-get (harness-call 'workspace/box/return-control "w-1")
                                       :control)))
      (should (equal "agent" (plist-get (harness-call 'workspace/box/status "w-1")
                                       :control))))))

(ert-deftest harness-workspace-box-reads-no-input-over-the-user ()
  "The input methods never type over the reviewer."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t))
              ((symbol-function 'harness-workspace-box--call)
               (lambda (&rest _) (list 0 "" nil)))
              ((symbol-function 'harness-workspace-box--tool)
               (lambda (&rest _) "tool")))
      (should (stringp (harness-call 'workspace/box/click "w-1" 1 2)))
      (harness-call 'workspace/box/take-over "w-1")
      (should-error (harness-call 'workspace/box/key "w-1" "Return")
                    :type 'harness-error)
      (should-error (harness-call 'workspace/box/scroll "w-1" 1 2 -3)
                    :type 'harness-error)
      (should-error (harness-call 'workspace/box/drag "w-1" '(1 2) '(3 4))
                    :type 'harness-error))))

(ert-deftest harness-workspace-box-parses-windows ()
  "The window list is xwininfo's tree, one plist per named window."
  (harness-workspace-box-test-with
    (let ((windows (harness-workspace-box--parse-windows
                    "     1 child:
     0x200024 \"xmessage\": (\"xmessage\" \"Xmessage\")  265x70+0+0  +0+0
        1 child:
        0x200025 (has no name): ()  265x70+0+0  +1+1")))
      (should (= 1 (length windows)))
      (should (equal "0x200024" (plist-get (car windows) :id)))
      (should (equal "xmessage" (plist-get (car windows) :title)))
      (should (= 265 (plist-get (car windows) :width)))
      (should (= 70 (plist-get (car windows) :height))))))

(ert-deftest harness-workspace-box-browser-is-metadata-only ()
  "The browser resources count sites and logins and never carry a value."
  (harness-workspace-box-test-with
    (let* ((profile (harness-workspace-box--profile "w-1"))
           (cookies (expand-file-name "cookies.sqlite" profile)))
      (harness-ensure-directory profile)
      (when (fboundp 'sqlite-open)
        (let ((db (sqlite-open cookies)))
          (sqlite-execute db "CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, host TEXT, name TEXT, value TEXT, expiry INTEGER)")
          (sqlite-execute db "INSERT INTO moz_cookies (host, name, value, expiry) VALUES ('stoneco.example', 'session', 'SESSION-VALUE', 2000000000)")
          (sqlite-execute db "INSERT INTO moz_cookies (host, name, value, expiry) VALUES ('stoneco.example', 'theme', 'dark', 2000000000)")
          (sqlite-execute db "INSERT INTO moz_cookies (host, name, value, expiry) VALUES ('bank.example', 'auth', 'TOKEN-VALUE', 2000000000)")
          (sqlite-close db))
        (with-temp-file (expand-file-name "logins.json" profile)
          (insert (json-encode '((logins . (((hostname . "https://stoneco.example")
                                             (encryptedUsername . "USER-SECRET")
                                             (timeCreated . 1) (timeLastUsed . 2))))))))
        (harness-ensure-directory (expand-file-name "storage/default" profile))
        (with-temp-file (expand-file-name "storage/default/data.sqlite" profile)
          (insert "x"))
        (harness-ensure-directory (expand-file-name "cache2" profile))
        (with-temp-file (expand-file-name "cache2/entry" profile) (insert "yy"))
        (let ((browser (harness-workspace-box--browser "w-1")))
          (should (= 2 (length (plist-get browser :sites))))
          (should (= 3 (plist-get browser :cookies)))
          (should (= 3 (plist-get (plist-get browser :totals) :cookies)))
          (should (= 1 (length (plist-get browser :logins))))
          (should (equal "https://stoneco.example"
                         (plist-get (car (plist-get browser :logins)) :origin)))
          (should (equal "stoneco.example"
                         (plist-get (car (plist-get browser :logins)) :id)))
          (should (equal "Firefox" (plist-get (plist-get browser :profile) :kind)))
          (should (>= (plist-get browser :bytes) 3))
          (should (>= (plist-get (plist-get browser :totals) :bytes) 3))
          (dolist (forbidden '(:value :secret :token :password :pan :cvv :number
                               :encryptedUsername))
            (should-not (string-match-p (format "%s" forbidden)
                                        (format "%S" browser)))))))))

(defconst harness-workspace-box-test-storage-layout
  '("default/https+++stoneco.example/idb/a.sqlite"
    "default/https+++stoneco.example+8443/idb/a.sqlite"
    "default/http+++stoneco.example/idb/a.sqlite"
    "default/https+++www.stoneco.example/idb/a.sqlite"
    "default/https+++bank.example/idb/b.sqlite"
    "permanent/https+++stoneco.example/idb/a.sqlite"
    "permanent/https+++bank.example/idb/b.sqlite"
    "temporary/https+++stoneco.example/idb/a.sqlite"
    "temporary/https+++bank.example/idb/b.sqlite")
  "A realistic Firefox storage tree: two sites, schemes and a port.")

(defun harness-workspace-box-test-storage (profile)
  "Write `harness-workspace-box-test-storage-layout' under PROFILE."
  (dolist (name harness-workspace-box-test-storage-layout)
    (let ((file (expand-file-name (concat "storage/" name) profile)))
      (harness-ensure-directory (file-name-directory file))
      (with-temp-file file (insert "fixture")))))

(defun harness-workspace-box-test-storage-p (profile name)
  "Non-nil when NAME's directory exists under PROFILE's storage."
  (file-directory-p (expand-file-name (concat "storage/" name) profile)))

(defun harness-workspace-box-test-cookies (profile &rest hosts)
  "Make PROFILE's cookies database with one cookie for each of HOSTS."
  (when (fboundp 'sqlite-open)
    (let ((db (sqlite-open (expand-file-name "cookies.sqlite" profile))))
      (unwind-protect
          (progn
            (sqlite-execute db "CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, host TEXT, name TEXT, value TEXT, expiry INTEGER)")
            (dolist (host hosts)
              (sqlite-execute db "INSERT INTO moz_cookies (host, name, value, expiry) VALUES (?, ?, ?, ?)"
                              (list host "session" "VALUE" 2000000000))))
        (sqlite-close db)))))

(defun harness-workspace-box-test-cookie-hosts (profile)
  "Return the distinct hosts in PROFILE's cookies database."
  (when (and (fboundp 'sqlite-open)
             (file-readable-p (expand-file-name "cookies.sqlite" profile)))
    (let ((db (sqlite-open (expand-file-name "cookies.sqlite" profile))))
      (unwind-protect
          (mapcar #'car
                  (sqlite-select db "SELECT DISTINCT host FROM moz_cookies ORDER BY host"))
        (sqlite-close db)))))

(defun harness-workspace-box-test-permissions (profile &rest origins)
  "Make PROFILE's permissions database with one row per ORIGIN."
  (when (fboundp 'sqlite-open)
    (let ((db (sqlite-open (expand-file-name "permissions.sqlite" profile))))
      (unwind-protect
          (progn
            (sqlite-execute db "CREATE TABLE moz_perms (id INTEGER PRIMARY KEY, origin TEXT, type TEXT, permission INTEGER)")
            (dolist (origin origins)
              (sqlite-execute db "INSERT INTO moz_perms (origin, type, permission) VALUES (?, ?, ?)"
                              (list origin "geo" 1))))
        (sqlite-close db)))))

(defun harness-workspace-box-test-permission-origins (profile)
  "Return the origins in PROFILE's permissions database."
  (when (and (fboundp 'sqlite-open)
             (file-readable-p (expand-file-name "permissions.sqlite" profile)))
    (let ((db (sqlite-open (expand-file-name "permissions.sqlite" profile))))
      (unwind-protect
          (mapcar #'car
                  (sqlite-select db "SELECT DISTINCT origin FROM moz_perms ORDER BY origin"))
        (sqlite-close db)))))

(ert-deftest harness-workspace-box-kinds-normalize-and-validate ()
  "Omitted kinds mean all, strings and symbols are understood, junk is not."
  (harness-workspace-box-test-with
    (should (equal '("cookies" "storage" "cache" "permissions")
                   (harness-workspace-box--browser-kinds nil)))
    (should (equal '("cookies" "storage")
                   (harness-workspace-box--browser-kinds '("storage" "cookies"))))
    (should (equal '("cookies" "cache")
                   (harness-workspace-box--browser-kinds '(cookies cache))))
    (should (equal '("cache")
                   (harness-workspace-box--browser-kinds "cache")))
    (should-error (harness-workspace-box--browser-kinds '("cookies" "passwords"))
                  :type 'harness-error)
    (should-error (harness-workspace-box--browser-kinds 42) :type 'harness-error)))

(ert-deftest harness-workspace-box-clear-omitted-kinds-clears-every-kind ()
  "A clear with no kinds clears cookies, storage, cache and permissions."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (let* ((profile (harness-workspace-box--profile "w-1")))
      (harness-ensure-directory profile)
      (harness-workspace-box-test-storage profile)
      (harness-workspace-box-test-cookies profile "stoneco.example" "bank.example")
      (harness-workspace-box-test-permissions profile "https://stoneco.example")
      (harness-ensure-directory (expand-file-name "cache2" profile))
      (with-temp-file (expand-file-name "cache2/entry" profile) (insert "fixture"))
      (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t)))
        (let ((answer (harness-call 'workspace/browser/clear "w-1" "profile")))
          (should (equal '("cookies" "storage" "cache" "permissions")
                         (plist-get answer :kinds)))
          (should (harness-json-true-p (plist-get answer :changed)))
          (should-not (file-directory-p (expand-file-name "storage" profile)))
          (should-not (file-directory-p (expand-file-name "cache2" profile)))
          (should-not (harness-workspace-box-test-cookie-hosts profile))
          (should-not (harness-workspace-box-test-permission-origins profile)))))))

(ert-deftest harness-workspace-box-clear-named-kinds-leave-the-rest ()
  "Explicit string kinds clear only what they name; a symbol list does too."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (let ((profile (harness-workspace-box--profile "w-1")))
      (harness-ensure-directory profile)
      (harness-workspace-box-test-storage profile)
      (harness-workspace-box-test-cookies profile "stoneco.example" "bank.example")
      (harness-workspace-box-test-permissions profile "https://stoneco.example")
      (harness-ensure-directory (expand-file-name "cache2" profile))
      (with-temp-file (expand-file-name "cache2/entry" profile) (insert "fixture"))
      (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t)))
        (let ((answer (harness-call 'workspace/browser/clear "w-1" "profile" nil
                                    '("cookies"))))
          (should (equal '("cookies") (plist-get answer :kinds)))
          ;; A profile clear of cookies is all of them; the kinds it did not
          ;; name are still there.
          (should-not (harness-workspace-box-test-cookie-hosts profile))
          (should (file-directory-p (expand-file-name "storage/default/https+++bank.example"
                                                      profile)))
          (should (file-directory-p (expand-file-name "cache2" profile)))
          (should (equal '("https://stoneco.example")
                         (harness-workspace-box-test-permission-origins profile))))
        (let ((answer (harness-call 'workspace/browser/clear "w-1" "profile" nil
                                    '(storage cache))))
          (should (equal '("storage" "cache") (plist-get answer :kinds)))
          (should-not (file-directory-p (expand-file-name "storage" profile)))
          (should-not (file-directory-p (expand-file-name "cache2" profile)))
          (should (equal '("https://stoneco.example")
                         (harness-workspace-box-test-permission-origins profile))))))))

(ert-deftest harness-workspace-box-clear-refuses-unknown-kinds-untouched ()
  "An invalid kind signals before anything in the profile is touched."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (let* ((profile (harness-workspace-box--profile "w-1"))
           (stopped nil))
      (harness-ensure-directory profile)
      (harness-workspace-box-test-storage profile)
      (harness-workspace-box-test-cookies profile "stoneco.example")
      (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t))
                ((symbol-function 'harness-workspace-box--stop-browser)
                 (lambda (_id) (setq stopped t) t)))
        (should-error (harness-call 'workspace/browser/clear "w-1" "profile" nil
                                    '("cookies" "passwords"))
                      :type 'harness-error))
      (should-not stopped)
      (should (equal '("stoneco.example") (harness-workspace-box-test-cookie-hosts profile)))
      (should (harness-workspace-box-test-storage-p profile "default/https+++stoneco.example")))))

(ert-deftest harness-workspace-box-clear-site-keeps-other-origins ()
  "A site storage clear removes only that origin's directories."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (let* ((profile (harness-workspace-box--profile "w-1")))
      (harness-ensure-directory profile)
      (harness-workspace-box-test-storage profile)
      (harness-workspace-box-test-cookies profile "stoneco.example" "bank.example")
      (harness-workspace-box-test-permissions profile "https://stoneco.example"
                                              "https://bank.example")
      (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t)))
        (let ((answer (harness-call 'workspace/browser/clear "w-1" "site"
                                    "https://stoneco.example" '("storage"))))
          (should (equal '("storage") (plist-get answer :kinds)))
          (should (plist-get answer :changed))
          (should-not (harness-workspace-box-test-storage-p
                       profile "default/https+++stoneco.example"))
          (should-not (harness-workspace-box-test-storage-p
                       profile "permanent/https+++stoneco.example"))
          (should-not (harness-workspace-box-test-storage-p
                       profile "temporary/https+++stoneco.example"))
          ;; Another origin is not this site: a scheme, a subdomain or a port
          ;; is an origin of its own.
          (should (harness-workspace-box-test-storage-p
                   profile "default/http+++stoneco.example"))
          (should (harness-workspace-box-test-storage-p
                   profile "default/https+++www.stoneco.example"))
          (should (harness-workspace-box-test-storage-p
                   profile "default/https+++stoneco.example+8443"))
          (should (harness-workspace-box-test-storage-p
                   profile "default/https+++bank.example"))
          (should (harness-workspace-box-test-storage-p
                   profile "permanent/https+++bank.example"))
          ;; Kinds it did not name are untouched too.
          (should (equal '("bank.example" "stoneco.example")
                         (harness-workspace-box-test-cookie-hosts profile)))
          (should (equal '("https://bank.example" "https://stoneco.example")
                         (harness-workspace-box-test-permission-origins profile))))))))

(ert-deftest harness-workspace-box-clear-site-cookies-and-permissions ()
  "A site clear deletes its cookies and permissions, and another site's stay.
Another scheme or port of the same host is another origin: its
permissions stay, while cookies, which Firefox keeps per host, go with
the host."
  (skip-unless (fboundp 'sqlite-open))
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (let* ((profile (harness-workspace-box--profile "w-1")))
      (harness-ensure-directory profile)
      (harness-workspace-box-test-cookies profile "stoneco.example" ".stoneco.example"
                                          "www.stoneco.example" "bank.example")
      (harness-workspace-box-test-permissions profile "https://stoneco.example"
                                              "http://stoneco.example"
                                              "https://stoneco.example:8443"
                                              "https://bank.example")
      (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t)))
        (let ((answer (harness-call 'workspace/browser/clear "w-1" "site"
                                    "https://stoneco.example" '("cookies" "permissions"))))
          (should (equal '("cookies" "permissions") (plist-get answer :kinds)))
          (should (harness-json-true-p (plist-get answer :changed)))
          (should (equal '("bank.example" "www.stoneco.example")
                         (harness-workspace-box-test-cookie-hosts profile)))
          (should (equal '("http://stoneco.example"
                           "https://bank.example"
                           "https://stoneco.example:8443")
                         (harness-workspace-box-test-permission-origins profile))))))))

(ert-deftest harness-workspace-box-login-forget-scopes-storage-and-stops-browser ()
  "Forgetting a login stops the browser and removes only that origin."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (let* ((profile (harness-workspace-box--profile "w-1"))
           (stopped nil))
      (harness-ensure-directory profile)
      (harness-workspace-box-test-storage profile)
      (harness-workspace-box-test-cookies profile "stoneco.example" "bank.example")
      (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t))
                ((symbol-function 'harness-workspace-box--stop-browser)
                 (lambda (id) (setq stopped id) t)))
        (let ((answer (harness-call 'workspace/browser/login/forget "w-1"
                                    "https://stoneco.example")))
          (should (equal "w-1" stopped))
          (should (harness-json-true-p (plist-get answer :changed)))
          (should-not (harness-workspace-box-test-storage-p
                       profile "default/https+++stoneco.example"))
          (should-not (harness-workspace-box-test-storage-p
                       profile "permanent/https+++stoneco.example"))
          (should-not (harness-workspace-box-test-storage-p
                       profile "temporary/https+++stoneco.example"))
          (should (harness-workspace-box-test-storage-p
                   profile "default/http+++stoneco.example"))
          (should (harness-workspace-box-test-storage-p
                   profile "default/https+++www.stoneco.example"))
          (should (harness-workspace-box-test-storage-p
                   profile "default/https+++stoneco.example+8443"))
          (should (harness-workspace-box-test-storage-p
                   profile "default/https+++bank.example"))
          (should (equal '("bank.example")
                         (harness-workspace-box-test-cookie-hosts profile))))))))

(ert-deftest harness-workspace-box-exec-defaults-to-the-box-home ()
  "A box command with no :cwd runs in the box's home, not in nil."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (harness-ensure-directory (harness-workspace-box--home "w-1"))
    (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t)))
      (let ((answer (harness-call 'workspace/box/exec "w-1" "echo exec-ok")))
        (should (string-match-p "exec-ok" (plist-get answer :stdout)))
        (should (equal (harness-workspace-box--home "w-1")
                       (plist-get answer :cwd)))))))

(ert-deftest harness-workspace-box-tunnel-names-only-a-running-box ()
  "The VNC tunnel answers a workspace's own RFB port, never a port of the device."
  (harness-workspace-box-test-with
    (harness-workspace-box-test-fake-running "w-1")
    (let ((harness-acp-remote-tunnels nil))
      (harness-workspace-box--install-acp)
      (should (equal "/workspace/vnc"
                     (car (assoc "/workspace/vnc" harness-acp-remote-tunnels))))
      (let ((tunnel (cdr (assoc "/workspace/vnc" harness-acp-remote-tunnels))))
        (cl-letf (((symbol-function 'process-attributes) (lambda (&rest _) t)))
          (should (equal '(:host "127.0.0.1" :port 5901)
                         (funcall tunnel '(:query (("workspace" . "w-1"))) nil))))
        ;; A stopped box has no screen to carry, and an unknown workspace no
        ;; port at all.
        (puthash "w-1" (plist-put (copy-sequence (gethash "w-1"
                                                         harness-workspace-box--records))
                                  :state "stopped")
                 harness-workspace-box--records)
        (should-not (funcall tunnel '(:query (("workspace" . "w-1"))) nil))
        (should-not (funcall tunnel '(:query (("workspace" . "w-unknown"))) nil))
        (should-not (funcall tunnel '(:query nil) nil)))
      (harness-workspace-box--shutdown)
      (should-not (assoc "/workspace/vnc" harness-acp-remote-tunnels)))))

(ert-deftest harness-workspace-box-methods-exist ()
  "The box exposes the methods the app, the presenter and the demo call."
  (harness-workspace-box-test-with
    (dolist (method '(workspace/box/status workspace/box/start workspace/box/stop
                      workspace/box/restart workspace/box/reset workspace/box/vnc
                      workspace/box/take-over workspace/box/return-control
                      workspace/box/exec workspace/box/screenshot
                      workspace/box/click workspace/box/type workspace/box/key
                      workspace/box/scroll workspace/box/drag workspace/box/windows
                      workspace/box/launch workspace/box/clipboard workspace/box/logs
                      workspace/box/browser workspace/browser/open
                      workspace/browser/screenshot workspace/browser/clear
                      workspace/browser/login/forget))
      (should (harness-method-exists-p method)))))
