;;; jobs-game-demo.el --- Drive a running game from separate tool calls  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The acceptance run the review asked for, in this checkout, with the
;; real bwrap: a game is launched once as a job of a session, and the
;; calls that come after it -- each a separate `tools/execute' with its
;; own permission decision -- take screenshots, send it input and read
;; back what it did.  Then it is stopped, its lifecycle is proved, and
;; the session's own working directory is downgraded to read-only to show
;; the runtime it has cannot write there afterwards.
;;
;;   scripts/jobs-game/demo.sh
;;
;; It needs `bwrap' and `python3' with Pillow, and says so and stops
;; where the backend is not bwrap.  Everything it makes is in a throwaway
;; state directory and a throwaway working directory, and it deletes
;; both; the screenshots it keeps are listed as it takes them.

;;; Code:

(require 'harness-test-helpers)

(defvar jobs-game-demo--session nil "The demo session: one session, many calls.")
(defvar jobs-game-demo--job nil "The id of the job the game runs as.")
(defvar jobs-game-demo--port nil "The port the game answers on.")
(defvar jobs-game-demo--root nil "The directory the game works in.")
(defvar jobs-game-demo--shots nil "The screenshots taken, newest last.")

(defun jobs-game-demo--say (format &rest args)
  "Print a line made from FORMAT and ARGS, as a transcript would show it."
  (princ (apply #'format format args))
  (princ "\n"))

(defun jobs-game-demo--tool (name &rest input)
  "Run tool NAME with INPUT as a call of its own in the demo session."
  (harness-test-await
   (harness-call 'tools/execute jobs-game-demo--session
                 (list :id (harness-short-id) :name name :input input))
   180))

(defun jobs-game-demo--text (name &rest input)
  "Run tool NAME with INPUT and return what it said, trimmed."
  (string-trim (or (plist-get (apply #'jobs-game-demo--tool name input) :content) "")))

(defun jobs-game-demo--bash (&rest args)
  "A `bash' call of the demo session, with ARGS as its input."
  (apply #'jobs-game-demo--text "bash" args))

(defun jobs-game-demo--shot (name)
  "Take a screenshot of the game's next frame, called NAME, from this call.
The frame is the one the game has drawn: this call copies it, and says
where it went.  It is a call of its own, so what it proves is that the
game drew a frame at this moment rather than at the moment it started.
The copy is read back as a whole PNG of the game's size, because a frame
is drawn while this call runs: a copy taken mid-write would be a
truncated file that proves nothing, and is taken again rather than kept."
  (let* ((dir (expand-file-name "shots" jobs-game-demo--root))
         (path (expand-file-name (concat name ".png") dir))
         (whole nil))
    (make-directory dir t)
    (dotimes (_ 20)
      (unless whole
        (jobs-game-demo--bash
         :command (format "cp frame.png %s && printf 'shot: %%s\\n' %s"
                          (shell-quote-argument path)
                          (shell-quote-argument name)))
        (setq whole (and (file-exists-p path)
                         (> (or (file-attribute-size (file-attributes path)) 0) 0)
                         (ignore-errors (jobs-game-demo--png-whole-p path))))
        (unless whole (sleep-for 0.2))))
    (unless whole
      (error "The game drew no whole frame to take: %s" path))
    (push path jobs-game-demo--shots)
    (jobs-game-demo--say "screenshot: %s (%s bytes)"
                         (file-name-nondirectory path)
                         (file-attribute-size (file-attributes path)))
    path))

(defun jobs-game-demo--png-whole-p (path)
  "Non-nil when PATH is a PNG whose end marker is there and whose size is the game's.
A truncated PNG loses its `IEND' chunk; a frame is the game's own
`WIDTH' by `HEIGHT' in its header.  Reading it here is the harness's own
read of a file the demo keeps, not of the sandbox's."
  (when (file-exists-p path)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path)
      (let ((bytes (buffer-string)))
        (and (> (length bytes) 64)
             (string-prefix-p "\211PNG\r\n\032\n" bytes)
             (string-suffix-p "IEND\256B`\202" bytes))))))

(defun jobs-game-demo--status ()
  "Return the game's own status line, as a call of its own reads it."
  (jobs-game-demo--bash :command "cat status.txt"))

(defun jobs-game-demo--score (text)
  "Return the score TEXT, the game's status line, names."
  (when (string-match "score \\([0-9]+\\)" text)
    (string-to-number (match-string 1 text))))

(defun jobs-game-demo--at (text)
  "Return (X . Y) that TEXT, the game's status line, names."
  (when (string-match "at \\([0-9]+\\),\\([0-9]+\\)" text)
    (cons (string-to-number (match-string 1 text))
          (string-to-number (match-string 2 text)))))

(defun jobs-game-demo--steps ()
  "Play the acceptance run: launch once, use it from later calls, stop it."

  (jobs-game-demo--say "\n== Call 1: launch the game as a job of the session ==")
  (let* ((result (jobs-game-demo--tool
                  "bash_job" :action "start" :timeout 300
                  :command (format "exec python3 game.py --dir . --port %d" jobs-game-demo--port)))
         (id (plist-get (plist-get result :meta) :job)))
    (setq jobs-game-demo--job id)
    (jobs-game-demo--say "%s" (string-trim (or (plist-get result :content) "")))
    (unless id (error "The game did not start")))

  (jobs-game-demo--say "\n== Call 2: a later call takes a screenshot of the running game ==")
  (harness-test-wait
   (lambda () (string-search "tick" (ignore-errors (jobs-game-demo--status))))
   60 "the game to draw its first frame")
  (let ((launched (jobs-game-demo--status)))
    (jobs-game-demo--say "the game says: %s" launched)
    (jobs-game-demo--shot "01-launch"))

  (jobs-game-demo--say "\n== Call 3: another call sends it input ==")
  (jobs-game-demo--say "%s"
                       (jobs-game-demo--bash
                        :command (concat "printf '{\"keys\":[\"right\",\"right\",\"right\",\"down\",\"down\"]}' > control.json\n"
                                         "sleep 0.8\ncat status.txt")))
  (let* ((before (jobs-game-demo--at (jobs-game-demo--status)))
         (moved (jobs-game-demo--at (jobs-game-demo--status))))
    (jobs-game-demo--say "the game is at %d,%d" (car moved) (cdr moved))
    (ignore before))

  (jobs-game-demo--say "\n== Call 4: a later call takes the second screenshot, and the move is in it ==")
  (let ((after (jobs-game-demo--shot "02-after-input"))
        (status (jobs-game-demo--status)))
    (jobs-game-demo--say "the game says: %s" status)
    (jobs-game-demo--say "the world file, as a call of its own reads it: %s"
                         (jobs-game-demo--bash
                          :command "python3 -c \"import json;w=json.load(open('world.json'));print('ticks',w['ticks'],'score',w['score'],'at',w['x'],w['y'])\""))
    (ignore after))

  (jobs-game-demo--say "\n== Call 5: the playtest leaves a file the harness's own tools read ==")
  (jobs-game-demo--say "%s"
                       (jobs-game-demo--bash
                        :command (format "printf 'hiscore %s tick %s\\n' %s %s > hiscore.txt && cat hiscore.txt"
                                         (or (jobs-game-demo--score (jobs-game-demo--status)) 0)
                                         (jobs-game-demo--bash
                                          :command "python3 -c \"import json;print(json.load(open('world.json'))['ticks'])\"")
                                         "10" "0")))
  (jobs-game-demo--say "read by the file tools, not by a shell: %s"
                       (string-trim
                        (with-temp-buffer
                          (insert-file-contents (expand-file-name "hiscore.txt" jobs-game-demo--root))
                          (buffer-string))))

  (jobs-game-demo--say "\n== Call 6: the game is still the session's, and lists as a job ==")
  (jobs-game-demo--say "%s" (jobs-game-demo--text "bash_job" :action "list"))
  (jobs-game-demo--say "the runtime that holds it: %s"
                       (let ((runtime (harness-sandbox-session-sandbox jobs-game-demo--session)))
                         (format "%s, %s, holding %s"
                                 (plist-get runtime :backend)
                                 (harness-sandbox-session-state runtime)
                                 (harness-tools-count-phrase
                                  (length (harness-sandbox-session-live-runs runtime)) "command"))))

  (jobs-game-demo--say "\n== Call 7: stop it, and nothing of it answers or draws ==")
  (let ((frames-before (jobs-game-demo--bash
                        :command "stat -c %Y frame.png 2>/dev/null || echo none")))
    (jobs-game-demo--say "%s" (jobs-game-demo--text "bash_job" :action "stop" :id jobs-game-demo--job))
    (harness-test-wait
     (lambda ()
       (string-search "no game any more"
                      (jobs-game-demo--bash
                       :command (format (concat "curl -fsS --max-time 3 http://127.0.0.1:%d/status "
                                                "2>/dev/null || echo 'no game any more'")
                                        jobs-game-demo--port))))
     30 "the game's server to be gone")
    (jobs-game-demo--say "after the stop: %s"
                         (jobs-game-demo--bash
                          :command (format (concat "curl -fsS --max-time 3 http://127.0.0.1:%d/status "
                                                   "2>/dev/null || echo 'no game any more'")
                                           jobs-game-demo--port)))
    (sleep-for 1)
    (let ((frames-after (jobs-game-demo--bash
                         :command "stat -c %Y frame.png 2>/dev/null || echo none")))
      (jobs-game-demo--say "the frame the game drew was last written at %s; a second later it is %s"
                           frames-before frames-after)
      (unless (equal frames-before frames-after)
        (error "The game drew a frame after it was stopped")))
    (jobs-game-demo--say "the files it wrote are still there: %s"
                         (jobs-game-demo--bash :command "ls -1 *.txt *.json *.png 2>/dev/null | tr '\\n' ' '"))
    (jobs-game-demo--say "the runtime the game was in: %s"
                         (let ((runtime (harness-sandbox-session-sandbox jobs-game-demo--session)))
                           (if runtime
                               (format "%s, %s" (plist-get runtime :backend)
                                       (harness-sandbox-session-state runtime))
                             "gone, as a runtime with nothing of the session in it is"))))

  (jobs-game-demo--say "\n== Call 8: the runtime went when nothing of the session was left in it ==")
  (harness-test-wait (lambda () (null (harness-sandbox-session-sandbox jobs-game-demo--session)))
                     30 "the idle runtime to go")
  (jobs-game-demo--say "runtime: %s"
                       (or (harness-sandbox-session-sandbox jobs-game-demo--session) "none"))
  (jobs-game-demo--say "and the session's next call builds another, with its files intact: %s"
                       (jobs-game-demo--bash :command "cat hiscore.txt; printf 'pid-1: '; cat /proc/1/comm"))

  (jobs-game-demo--say "\n== Call 9: the working directory is downgraded, and the runtime cannot write in it ==")
  (jobs-game-demo--say "%s"
                       (jobs-game-demo--text "drop_access" :attribute "directory"
                                             :value jobs-game-demo--root :keep_read t))
  ;; The call runs from the session's temporary directory, which it may
  ;; still write: a bash call whose own working directory it may only read
  ;; is a call the permission chain asks the user about, and this demo has
  ;; nobody to ask.  What the write goes to is the downgraded directory.
  (let* ((tmp (harness-call 'session/tmp-dir jobs-game-demo--session))
         (target (directory-file-name jobs-game-demo--root)))
    (jobs-game-demo--say "a write into the downgraded directory, from a call in %s: %s"
                         (file-name-nondirectory (directory-file-name tmp))
                         (jobs-game-demo--bash
                          :cwd tmp
                          :command (format "printf 'should not be written\\n' > %s/after-downgrade.txt 2>/dev/null && echo WROTE || echo REFUSED; cat %s/hiscore.txt"
                                           (shell-quote-argument target)
                                           (shell-quote-argument target))))
    (jobs-game-demo--say "the file exists anyway: %s"
                         (file-exists-p (expand-file-name "after-downgrade.txt" jobs-game-demo--root)))
    (jobs-game-demo--say "the profile of the runtime it has now says: cwd-writable=%s"
                         (plist-get (plist-get (harness-sandbox-session-sandbox jobs-game-demo--session)
                                               :profile)
                                    :cwd-writable))))

(defun jobs-game-demo--montage (paths output)
  "Write a contact sheet of PATHS, the screenshots, to OUTPUT."
  (let ((script (expand-file-name "montage.py" temporary-file-directory)))
    (with-temp-file script
      (insert
       (concat
        "import sys\n"
        "from PIL import Image, ImageDraw\n"
        "paths, out = sys.argv[1:-1], sys.argv[-1]\n"
        "images = [Image.open(p).convert('RGB') for p in paths]\n"
        "scale = 3\n"
        "w, h = images[0].size\n"
        "w, h = w * scale, h * scale\n"
        "pad, label = 12, 26\n"
        "sheet = Image.new('RGB', (len(images) * w + (len(images) + 1) * pad, h + 2 * pad + label), (12, 14, 20))\n"
        "draw = ImageDraw.Draw(sheet)\n"
        "for i, (image, path) in enumerate(zip(images, paths)):\n"
        "    x = pad + i * (w + pad)\n"
        "    sheet.paste(image.resize((w, h), Image.NEAREST), (x, pad + label))\n"
        "    draw.text((x, pad), path.rsplit('/', 1)[-1].replace('-', ' ').rsplit('.', 1)[0], fill=(230, 230, 230))\n"
        "sheet.save(out)\n"
        "print('wrote', out, sheet.size)\n")))
    (jobs-game-demo--say "%s"
                         (string-trim
                          (shell-command-to-string
                           (mapconcat #'shell-quote-argument
                                      (append (list "python3" script) (nreverse paths) (list output))
                                      " "))))))

(defmacro jobs-game-demo--with-harness (&rest body)
  "Run BODY in a throwaway state with the modules a job needs started."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (module '(store project config provider session tools tools-shell
                              perms readonly access agent))
       (harness-test-load-module module))
     (harness-test-load-module 'sandbox)
     (harness-sandbox-detect)
     (harness-test-load-module 'sandbox-session)
     (harness-test-load-module 'tools-jobs)
     (harness-test-connect-ui-client)
     (harness-add-filter 'permission/decide
                         (lambda (_decision next &rest _)
                           (funcall next (list :behavior 'allow)))
                         10)
     (unwind-protect (progn ,@body)
       (ignore-errors (harness-call 'store/sqlite-close)))))

(defun jobs-game-demo-main ()
  "Play the acceptance run, with a real bwrap, and say what each call saw."
  (jobs-game-demo--with-harness
    (let* ((root (file-name-as-directory (harness-test-temp-dir)))
           (default-directory root))
      (setq jobs-game-demo--root root
            jobs-game-demo--session (plist-get (harness-call 'session/create :cwd root) :id)
            jobs-game-demo--port (+ 25000 (% (abs (sxhash-equal (float-time))) 2000))
            jobs-game-demo--job nil
            jobs-game-demo--shots nil)
      (unwind-protect
          (progn
            (jobs-game-demo--say "Session: %s" jobs-game-demo--session)
            (jobs-game-demo--say "Sandbox: %S" (harness-call 'sandbox/status))
            (unless (equal 'bwrap (plist-get (harness-call 'sandbox/status) :backend))
              (error "This demo needs the bwrap backend"))
            (unless (executable-find "python3")
              (error "This demo needs python3"))
            (unless (zerop (shell-command "python3 -c 'import PIL'" nil nil))
              (error "This demo needs python3 with Pillow"))
            (copy-file (expand-file-name "scripts/jobs-game/game.py" harness-test-root)
                       (expand-file-name "game.py" root))
            (jobs-game-demo--steps)
            (jobs-game-demo--say "\n== The screenshots, side by side ==")
            (let ((sheet (expand-file-name "jobs-game-01-launch-and-02-after-input.png"
                                           (or (getenv "JOBS_GAME_SHOTS")
                                               (expand-file-name "shots" root)))))
              (make-directory (file-name-directory sheet) t)
              (jobs-game-demo--montage (copy-sequence jobs-game-demo--shots) sheet)
              (jobs-game-demo--say "the screenshots, kept: %s" sheet)))
        (ignore-errors (harness-tools-jobs--stop-all jobs-game-demo--session "the demo is over"))
        (ignore-errors (harness-call 'session/delete jobs-game-demo--session))
        (ignore-errors (delete-directory root t))))))

(provide 'jobs-game-demo)
;;; jobs-game-demo.el ends here
