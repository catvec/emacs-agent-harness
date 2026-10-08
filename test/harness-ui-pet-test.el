;;; harness-ui-pet-test.el --- Tests for the companion pet's buffer  -*- lexical-binding: t; -*-
;;; Commentary:

;; The pet's buffer against the real state layer, the in-process ACP
;; connection and the demo provider: the art of every species, the egg
;; and its [Hatch it], the card it hatches into, what it says on a band
;; of its own, a narrow window, the harness told while the buffer is on
;; screen and no longer once it goes, and animations that stop on their
;; own.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-model)
(defvar harness-pet--pet)
(defvar harness-pet--loaded)
(defvar harness-pet--dirty)
(defvar harness-pet--watchers)
(defvar harness-pet--hatching)
(defvar harness-pet--speaking)
(defvar harness-pet--last-unasked)
(defvar harness-pet--last-spoke)
(defvar harness-pet--last-pet)
(defvar harness-pet--save-timer)
(defvar harness-pet-reactions)
(defvar harness-pet-model)
(defvar harness-pet-chance)
(defvar harness-pet-cooldown)
(defvar harness-pet-species)
(defvar harness-pet-eyes)
(defvar harness-pet-hats)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-default-position)
(defvar harness-ui-pet-animations)
(defvar harness-ui-pet--sprites)
(defvar harness-ui-pet--heads)
(defvar harness-ui-pet--hats)
(defvar harness-ui-pet--hearts)
(defvar harness-ui-pet--sparkles)
(defvar harness-ui-pet--stats-column)
(defvar harness-ui-pet--view)
(defvar harness-ui-pet--anim)
(defvar harness-ui-pet--queued)
(defvar harness-ui-pet--timer)
(defvar harness-ui-pet--error)
(defvar harness-ui-pet--faces)
(defvar harness-ui-pet--current)
(defvar harness-ui-pet--saying-lifetime)
(defvar harness-ui-pet-places)
(defvar harness-ui-pet--min-lines)
(defvar harness-ui-pet--panel-shown)
(defvar harness-compose-redraw-function)
(defvar harness-pet-eyes)
(defvar harness-pet-hats)
(defvar harness-pet-species)
(defvar harness-pet-enabled)
(defvar harness-chat-header-end-functions)
(defvar harness-chat-panel-functions)
(defvar harness-chat--loading)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-ui-tasks-header-functions)
(defvar harness-ui-tasks-tail-functions)
(defvar harness-ui-tasks--loading)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-worktrees)
(declare-function harness-pet "harness-ui-pet")
(declare-function harness-ui-pet-face "harness-ui-pet")
(declare-function harness-ui-pet--blink-p "harness-ui-pet")
(declare-function harness-ui-pet--active-p "harness-ui-pet")
(declare-function harness-ui-pet--fetch "harness-ui-pet")
(declare-function harness-ui-pet--client-id "harness-ui-pet")
(declare-function harness-ui-pet--chat-header "harness-ui-pet")
(declare-function harness-ui-pet--board-header "harness-ui-pet")
(declare-function harness-ui-pet--saying-for "harness-ui-pet")
(declare-function harness-ui-pet--seen "harness-ui-pet")
(declare-function harness-ui-pet--figure "harness-ui-pet")
(declare-function harness-ui-pet--figure-art "harness-ui-pet")
(declare-function harness-ui-pet--figure-width "harness-ui-pet")
(declare-function harness-ui-pet--fit "harness-ui-pet")
(declare-function harness-ui-pet--wrap "harness-ui-pet")
(declare-function harness-ui-pet--spec "harness-ui-pet")
(declare-function harness-ui-pet--speech "harness-ui-pet")
(declare-function harness-ui-pet--rarity-face "harness-ui-pet")
(declare-function harness-ui-pet--panel "harness-ui-pet")
(declare-function harness-ui-pet--board-tail "harness-ui-pet")
(declare-function harness-ui-pet--sync-panels "harness-ui-pet")
(declare-function harness-ui-pet--init "harness-ui-pet")
(declare-function harness-ui-pet-toggle-enabled "harness-ui-pet")
(declare-function harness-ui-pet-turn-on "harness-ui-pet")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat--header "harness-ui-chat")
(declare-function harness-ui-tasks--header "harness-ui-tasks")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-pet-art "harness-ui-pet")
(declare-function harness-ui-pet--header "harness-ui-pet")
(declare-function harness-ui-pet--render "harness-ui-pet")
(declare-function harness-ui-pet--animate "harness-ui-pet")
(declare-function harness-ui-pet--step "harness-ui-pet")
(declare-function harness-ui-pet--on-event "harness-ui-pet")
(declare-function harness-ui-pet--shutdown "harness-ui-pet")
(declare-function harness-ui-pet--window-width "harness-ui-pet")
(declare-function harness-ui-pet-hatch "harness-ui-pet")
(declare-function harness-ui-pet-pet "harness-ui-pet")
(declare-function harness-ui-pet-rename "harness-ui-pet")
(declare-function harness-ui-pet-toggle-mute "harness-ui-pet")
(declare-function harness-ui-pet-release "harness-ui-pet")
(declare-function harness-ui-pet-refresh "harness-ui-pet")
(declare-function harness-ui-pet--stop "harness-ui-pet")
(declare-function harness-ui-pet--shown-p "harness-ui-pet")
(declare-function harness-ui-pet--update-watch "harness-ui-pet")
(declare-function harness-ui-pet--on-window-buffer "harness-ui-pet")
(declare-function harness-ui-pet--when "harness-ui-pet")
(declare-function harness-acp--drop-client "harness-acp")

(defconst harness-ui-pet-test--buffer "*harness pet*")

(defun harness-ui-pet-test-reset ()
  "Forget the pet the harness knows of, as a fresh harness would."
  (when (timerp harness-pet--save-timer) (cancel-timer harness-pet--save-timer))
  (setq harness-pet--pet nil harness-pet--loaded nil harness-pet--dirty nil
        harness-pet--hatching nil harness-pet--speaking nil harness-pet--save-timer nil
        harness-pet--last-unasked 0 harness-pet--last-spoke 0 harness-pet--last-pet 0)
  (clrhash harness-pet--watchers))

(defmacro harness-ui-pet-test-with (&rest body)
  "Load the state layer with the pet and the demo provider, then the UI; run BODY.
The pet speaks with the demo model each time it may (chance 1, no
cooldown).  Animations are off unless BODY turns them on; views take
the whole frame."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent pet acp))
         (harness-test-load-module m)))
     (harness-ui-pet-test-reset)
     (clrhash harness-sessions)
     (setq harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-acp-token nil)
           (harness-model "demo:scripted")
           (harness-pet-model "demo:scripted")
           (harness-pet-reactions t)
           (harness-pet-chance 1)
           (harness-pet-cooldown 0)
           (harness-ui-pet-animations nil)
           (harness-ui-default-position 'full)
           (default-directory dir))
       ;; The UI modules load once the client list is clear, so their
       ;; connection is the one the harness events reach.
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-pet)
       (clrhash harness-ui--sessions)
       (unwind-protect (progn ,@body)
         (when (get-buffer harness-ui-pet-test--buffer)
           (kill-buffer harness-ui-pet-test--buffer))
         (harness-ui-pet--shutdown)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))
         (harness-ui-pet-test-reset)))))

(defun harness-ui-pet-test--text ()
  "The pet's buffer as plain text."
  (with-current-buffer harness-ui-pet-test--buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-pet-test--flat-text ()
  "The pet's buffer as plain text, its runs of whitespace one space."
  (replace-regexp-in-string "[ \t\n]+" " " (harness-ui-pet-test--text)))

(defun harness-ui-pet-test--wait-text (regexp)
  "Wait until the pet's buffer shows REGEXP."
  (harness-test-wait (lambda () (string-match-p regexp (harness-ui-pet-test--text)))
                     5 (format "the pet's buffer to show %s" regexp)))

(defun harness-ui-pet-test--open ()
  "Open the pet's buffer and wait for the pet; return the buffer."
  (harness-pet)
  (harness-test-wait (lambda () (buffer-local-value 'harness-ui-pet--view
                                                    (get-buffer harness-ui-pet-test--buffer)))
                     5 "the pet to arrive")
  (get-buffer harness-ui-pet-test--buffer))

(defun harness-ui-pet-test--hatch ()
  "Hatch the egg from the open buffer and wait for its first words."
  (with-current-buffer harness-ui-pet-test--buffer (harness-ui-pet-hatch))
  (harness-test-wait (lambda () (plist-get (buffer-local-value 'harness-ui-pet--view
                                                               (get-buffer harness-ui-pet-test--buffer))
                                           :said))
                     5 "the pet's first words"))

(defun harness-ui-pet-test--line-of (regexp)
  "The text of the line of the pet's buffer that matches REGEXP, or nil."
  (with-current-buffer harness-ui-pet-test--buffer
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward regexp nil t)
        (buffer-substring-no-properties (line-beginning-position) (line-end-position))))))

;;;; The art

(ert-deftest harness-ui-pet-art-draws-every-species ()
  "Every species has three frames of five lines, clear of the stats beside it."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (should (equal (sort (mapcar #'car harness-ui-pet--sprites) #'string<)
                 (sort (copy-sequence harness-pet-species) #'string<)))
  (dolist (species harness-pet-species)
    (should (= 3 (length (alist-get species harness-ui-pet--sprites))))
    (should (alist-get species harness-ui-pet--heads))
    (dotimes (frame 3)
      (dolist (eye harness-pet-eyes)
        (let ((art (harness-ui-pet-art species eye 'none frame)))
          (should (= 5 (length art)))
          (dolist (line art)
            (should-not (string-search "{E}" line))
            ;; Drawn at 1.25 times the size, two columns in: short of the stats.
            (should (<= (+ 2 (* 1.25 (string-width line))) harness-ui-pet--stats-column)))
          (when (= frame 0)
            (should (string-search eye (string-join art "\n")))))))))

(ert-deftest harness-ui-pet-art-wears-its-hat ()
  "A hat sits on the first line, over the head; none leaves it be."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (dolist (hat (remq 'none harness-pet-hats))
    (should (assq hat harness-ui-pet--hats)))
  (dolist (species harness-pet-species)
    (let ((head (alist-get species harness-ui-pet--heads))
          (blank (string-blank-p (car (harness-ui-pet-art species "o" 'none 0)))))
      (dolist (hat (remq 'none harness-pet-hats))
        (let* ((drawn (alist-get hat harness-ui-pet--hats))
               (line (car (harness-ui-pet-art species "o" hat 0))))
          (if (not blank)
              (should (equal line (car (harness-ui-pet-art species "o" 'none 0))))
            (should (string-suffix-p drawn line))
            ;; Centred on the head, within a column.
            (let ((middle (+ (- (length line) (length drawn)) (/ (1- (length drawn)) 2.0))))
              (should (<= (abs (- middle head)) 1.0))))))))
  ;; Hats and species by name work as strings too, as they come from the wire.
  (should (equal (harness-ui-pet-art 'duck "o" 'crown 0) (harness-ui-pet-art "duck" "o" "crown" 0)))
  ;; A frame that draws above the head keeps that over a hat.
  (should (string-search "~" (car (harness-ui-pet-art 'dragon "o" 'crown 2))))
  ;; An unknown species is drawn as a blob, not an error.
  (should (equal (harness-ui-pet-art 'blob "o" 'none 0) (harness-ui-pet-art 'gryphon "o" 'none 0))))

(ert-deftest harness-ui-pet-face-on-one-line ()
  "Every species has a face on one line, as header lines show it; it blinks
once in the fifteen half seconds of its idle loop."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (should (equal (sort (mapcar #'car harness-ui-pet--faces) #'string<)
                 (sort (copy-sequence harness-pet-species) #'string<)))
  (dolist (species harness-pet-species)
    (let ((face (harness-ui-pet-face species "o"))
          (shut (harness-ui-pet-face (symbol-name species) "o" t)))
      (should-not (string-search "\n" face))
      (should-not (string-search "{E}" face))
      (should (string-search "o" face))
      (should (<= (string-width face) 10))
      (should (string-search "-" shut))
      (should (= (length face) (length shut)))))
  ;; An unknown species is a blob; no eye shows as o.
  (should (equal (harness-ui-pet-face 'blob "o") (harness-ui-pet-face 'gryphon nil)))
  (should (equal "(oo)" (harness-ui-pet-face 'blob "")))
  (should (= 1 (cl-count-if #'harness-ui-pet--blink-p (number-sequence 0 7 0.5)))))

;;;; The buffer

(ert-deftest harness-ui-pet-egg-hatches-into-a-card ()
  "The egg offers [Hatch it]; hatched, the card shows the pet and its first words."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (should (eq buf (window-buffer (selected-window))))
      (should (with-current-buffer buf (derived-mode-p 'harness-ui-pet-mode)))
      (let ((text (harness-ui-pet-test--text)))
        (should (string-match-p "An egg" text))
        (should (string-match-p "Hatch it" text))
        (should (string-match-p "one of 18 species" text)))
      (should (string-match-p "Hatch" (format "%s" (with-current-buffer buf (harness-ui-pet--header)))))
      (harness-ui-pet-test--hatch)
      (let* ((view (buffer-local-value 'harness-ui-pet--view buf))
             (text (harness-ui-pet-test--flat-text)))
        (should (eq t (plist-get view :hatched)))
        (should (string-match-p (regexp-quote (plist-get view :name)) text))
        (should (string-match-p (upcase (plist-get view :species)) text))
        (should (string-match-p (upcase (plist-get view :rarity)) text))
        (should (string-match-p "Level 1" text))
        (should (string-match-p "rates every function by how it would taste" text))
        (dolist (stat '("DEBUGGING" "PATIENCE" "CHAOS" "WISDOM" "SNARK"))
          (should (string-match-p stat text)))
        (should (string-match-p "now and then has a word to say, through .*m mutes it" text)))
      ;; Its first words, the action set apart without its asterisks, on the band.
      (harness-ui-pet-test--wait-text "Is it always this bright in here")
      (with-current-buffer buf
        (goto-char (point-min))
        (search-forward "blinks")
        (should-not (eq ?* (char-after (match-end 0))))
        (should (memq 'harness-pet-action-face (ensure-list (get-text-property (match-beginning 0) 'face))))
        (search-forward "bright")
        (should (memq 'harness-pet-speech-face (ensure-list (get-text-property (match-beginning 0) 'face)))))
      (let ((header (format "%s" (with-current-buffer buf (harness-ui-pet--header)))))
        (dolist (label '("Pet" "Rename" "Mute" "Release"))
          (should (string-match-p label header)))
        (should-not (string-match-p "Hatch" header))))))

(ert-deftest harness-ui-pet-buttons-reach-the-harness ()
  "Petting, renaming, muting and releasing go to the harness, and show."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      ;; Asked, it answers at once, but not within seconds of its greeting.
      (setq harness-pet--last-spoke 0)
      (with-current-buffer buf (harness-ui-pet-pet))
      (harness-ui-pet-test--wait-text "petted 1 time")
      (harness-ui-pet-test--wait-text "Yes\\. That\\.")
      (with-current-buffer buf (harness-ui-pet-rename "Pickle"))
      (harness-ui-pet-test--wait-text "Pickle")
      (should (equal "Pickle" (plist-get harness-pet--pet :name)))
      (with-current-buffer buf (harness-ui-pet-toggle-mute))
      (harness-ui-pet-test--wait-text "Muted: it asks no model anything")
      (should (string-match-p "Unmute" (format "%s" (with-current-buffer buf (harness-ui-pet--header)))))
      (with-current-buffer buf (harness-ui-pet-toggle-mute))
      (harness-ui-pet-test--wait-text "now and then has a word to say")
      (with-current-buffer buf (harness-ui-pet-release t))
      (harness-ui-pet-test--wait-text "An egg")
      (should-not harness-pet--pet))))

(ert-deftest harness-ui-pet-fits-a-narrow-window ()
  "Beside the creature in a wide window, the stats go below it in a narrow one,
and the prose is filled to the window."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (harness-ui-pet-test--wait-text "Is it always this bright")
      (cl-letf (((symbol-function 'harness-ui-pet--window-width) (lambda () 100)))
        (with-current-buffer buf (harness-ui-pet--render))
        ;; The second stat shares a line with the creature's head.
        (should (string-match-p "\\S-.*PATIENCE" (harness-ui-pet-test--line-of "PATIENCE"))))
      (cl-letf (((symbol-function 'harness-ui-pet--window-width) (lambda () 44)))
        (with-current-buffer buf (harness-ui-pet--render))
        (should (string-match-p "\\`\\s-*PATIENCE" (harness-ui-pet-test--line-of "PATIENCE")))
        ;; Prose wraps short of the edge; only the stats' meters may reach it.
        (dolist (line (split-string (harness-ui-pet-test--text) "\n"))
          (unless (string-match-p "DEBUGGING\\|PATIENCE\\|CHAOS\\|WISDOM\\|SNARK" line)
            (should (<= (string-width line) 44))))
        (should (string-match-p "rates every function by how it would taste"
                                (harness-ui-pet-test--flat-text)))))))

(ert-deftest harness-ui-pet-tells-the-harness-while-shown ()
  "The harness hears the buffer is on screen, and that it left the screen."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-test-wait (lambda () (> (hash-table-count harness-pet--watchers) 0)) 5 "the watch")
      ;; Redisplay runs the hook as windows change buffers; a batch Emacs
      ;; does not redisplay, so the test runs it.
      (should (memq #'harness-ui-pet--on-window-buffer window-buffer-change-functions))
      ;; Another buffer in its window: not on screen any more.
      (switch-to-buffer (get-buffer-create "*harness-ui-pet-test other*"))
      (harness-ui-pet--update-watch (selected-frame))
      (harness-test-wait (lambda () (= 0 (hash-table-count harness-pet--watchers))) 5 "the watch to end")
      ;; Changes that leave it as it was tell the harness nothing.
      (cl-letf (((symbol-function 'harness-ui-call) (lambda (&rest _) (error "Told the harness again"))))
        (harness-ui-pet--update-watch (selected-frame)))
      ;; Back, then killed.
      (switch-to-buffer buf)
      (harness-ui-pet--update-watch (selected-frame))
      (harness-test-wait (lambda () (> (hash-table-count harness-pet--watchers) 0)) 5 "the watch again")
      (kill-buffer buf)
      (harness-test-wait (lambda () (= 0 (hash-table-count harness-pet--watchers))) 5 "the watch to end at last")
      (kill-buffer "*harness-ui-pet-test other*"))))

(ert-deftest harness-ui-pet-follows-events ()
  "The buffer follows `pet/changed' from elsewhere, and says when there is no pet module."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      ;; Hatched from another UI, or by the harness itself.
      (harness-test-await (harness-call 'pet/hatch))
      (harness-test-wait (lambda () (plist-get (buffer-local-value 'harness-ui-pet--view buf) :name))
                         5 "the pet hatched elsewhere")
      (harness-ui-pet-test--wait-text (regexp-quote (plist-get harness-pet--pet :name)))
      ;; A harness without the pet module.
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (_method _params _callback &optional errback)
                   (funcall errback (list 'error "Method not found: _harness/pet/get")))))
        (with-current-buffer buf (harness-ui-pet-refresh)))
      (should (string-match-p "The harness has no pet" (harness-ui-pet-test--text))))))

(ert-deftest harness-ui-pet-names-the-session-a-saying-is-about ()
  "A saying names its session, by the name it has now when it had none then."
  (harness-ui-pet-test-with
    (let ((now (float-time)))
      (should (equal "just now, about Parser work"
                     (harness-ui-pet--when (list :ts now :session "s1" :session-name "Parser work"))))
      (should (equal "just now" (harness-ui-pet--when (list :ts now :session "s2" :session-name nil))))
      (puthash "s2" (list :id "s2" :name "Renaming things") harness-ui--sessions)
      (should (equal "just now, about Renaming things"
                     (harness-ui-pet--when (list :ts now :session "s2" :session-name nil))))
      (should (equal "just now" (harness-ui-pet--when (list :ts now :session nil :session-name "  ")))))))

;;;; Elsewhere

(defun harness-ui-pet-test--know-the-pet ()
  "Have this Emacs ask for the pet, and wait until it knows it."
  (harness-ui-pet--fetch)
  (harness-test-wait (lambda () harness-ui-pet--current) 5 "the pet"))

(defun harness-ui-pet-test--hatch-elsewhere ()
  "Hatch the pet from the harness, not its buffer; wait until this Emacs knows."
  (harness-test-await (harness-call 'pet/hatch))
  (harness-test-wait #'harness-ui-pet--active-p 5 "the pet to hatch"))

(defun harness-ui-pet-test--own-hooks (hook)
  "The pet's functions on HOOK, as set for every buffer."
  (and (boundp hook)
       (cl-remove-if-not (lambda (fn) (string-prefix-p "harness-ui-pet-" (format "%s" fn)))
                         (default-value hook))))

(defun harness-ui-pet-test--watching ()
  "Where this Emacs told the harness it shows the pet: t, session ids, or nil."
  (gethash (harness-ui-pet--client-id) harness-pet--watchers))

(defun harness-ui-pet-test--figure (buffer)
  "The pet's figure above BUFFER's compose box: (TEXT . START), or nil.
TEXT is the figure as plain text, START where it begins."
  (with-current-buffer buffer
    (when-let* ((start (text-property-any (point-min) (point-max) 'harness-ui-pet-figure t)))
      (cons (buffer-substring-no-properties
             start (or (text-property-not-all start (point-max) 'harness-ui-pet-figure t) (point-max)))
            start))))

(defun harness-ui-pet-test--figure-text (buffer)
  "The pet's figure above BUFFER's compose box as plain text, or \"\"."
  (or (car (harness-ui-pet-test--figure buffer)) ""))

(defun harness-ui-pet-test--check-figure (buffer)
  "Check the pet's figure in BUFFER is whole, fits its window and is the pet's.
Every line of the creature and its name, all as wide, each right-aligned
by a space that ends where the line, as drawn, ends a column short of the
window's edge; in its rarity's colour on the window's own background,
hovering names it and a click shows it."
  (pcase-let* ((view harness-ui-pet--current)
               (`(,text . ,start) (harness-ui-pet-test--figure buffer))
               (lines (split-string text "\n" t))
               (window (get-buffer-window buffer)))
    (should text)
    (dolist (line (car (harness-ui-pet--figure-art view)))
      (should (string-search (string-trim line) text)))
    (should (string-search (plist-get view :name) text))
    (should (= 1 (length (delete-dups (mapcar #'string-width lines)))))
    (with-current-buffer buffer
      (save-excursion
        (goto-char start)
        (dolist (line lines)
          ;; In batch a pixel is a column: the line, then its newline.
          (let ((align (plist-get (cdr (get-text-property (point) 'display)) :align-to)))
            (should (equal (list '- 'right (list (1+ (string-width (substring line 1))))) align)))
          (should (< (string-width line) (window-body-width window)))
          (forward-line 1)))
      (goto-char start)
      (search-forward (string-trim (car (last (car (harness-ui-pet--figure-art view))))))
      (let ((faces (flatten-tree (get-text-property (match-beginning 0) 'face))))
        (should (eq (harness-ui-pet--rarity-face (plist-get view :rarity)) (car faces)))
        (should (memq 'harness-pet-figure-face faces))
        ;; The window's own background, over whatever the host puts behind.
        (should (equal 'default (car (last (cl-remove 'harness-chat-panel-face faces))))))
      (should (eq #'harness-ui-pet--face-help (get-text-property (match-beginning 0) 'help-echo)))
      (should (keymapp (get-text-property (match-beginning 0) 'keymap))))))

(ert-deftest harness-ui-pet-shows-in-a-chat ()
  "Hatched, the whole pet sits at the right above a chat's compose box, its
name below it.  What it says about the session shows beside it, in a
bubble joined to it at its eyes, until the session's next turn.  Its face
can end the chat's header line too, the first thing to go when it is
narrow, blinking while the session works."
  (harness-ui-pet-test-with
    (harness-test-load-module 'ui-chat)
    (let* ((sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted" :name "Parser work") :id))
           (buf (harness-chat-buffer sid))
           (other (get-buffer-create "*harness-ui-pet-test other*")))
      (unwind-protect
          (progn
            (harness-test-wait (lambda () (with-current-buffer buf (and (not harness-chat--loading) harness-compose-end)))
                               5 "the chat to load")
            (switch-to-buffer buf)
            ;; An egg shows nowhere: nothing is even wired for it.
            (harness-ui-pet-test--know-the-pet)
            (dolist (hook '(harness-chat-header-end-functions harness-chat-panel-functions
                            window-size-change-functions))
              (should-not (harness-ui-pet-test--own-hooks hook)))
            (should-not (harness-ui-pet-test--watching))
            (should-not (harness-ui-pet-test--figure buf))
            (harness-ui-pet-test--hatch-elsewhere)
            ;; The whole creature, above the compose box.
            (harness-test-wait (lambda () (harness-ui-pet-test--figure buf)) 5 "the pet above the compose box")
            (harness-ui-pet-test--check-figure buf)
            (should (< (cdr (harness-ui-pet-test--figure buf)) (with-current-buffer buf harness-compose-start)))
            ;; Not in the header line, unless asked for.
            (let* ((view harness-ui-pet--current)
                   (face (harness-ui-pet-face (plist-get view :species) (plist-get view :eye))))
              (should-not (string-search face (with-current-buffer buf (harness-chat--header most-positive-fixnum))))
              (let ((places harness-ui-pet-places))
                (unwind-protect
                    (progn
                      (customize-set-variable 'harness-ui-pet-places '(chat chat-header))
                      (let* ((header (with-current-buffer buf (harness-chat--header most-positive-fixnum)))
                             (at (string-search face header)))
                        ;; At the end, before [menu]: hovering names it, a click shows it.
                        (should at)
                        (should (< (string-search "Parser work" header) at (string-search "[menu]" header)))
                        (should (string-search (plist-get view :name)
                                               (funcall (get-text-property at 'help-echo header))))
                        (should (keymapp (get-text-property at 'local-map header)))
                        ;; A window narrower by a column: it goes first.
                        (let ((narrower (with-current-buffer buf
                                          (harness-chat--header (1- (harness-ui-header-string-width header))))))
                          (should-not (string-search face narrower))
                          (should (string-search "Parser work" narrower))))
                      ;; Its eyes shut now and then while the session works, never while it idles.
                      (cl-letf (((symbol-function 'harness-ui-pet--blink-p) (lambda (&optional _) t)))
                        (should (string-search face (with-current-buffer buf (car (harness-ui-pet--chat-header)))))
                        (puthash sid (plist-put (copy-sequence (harness-ui-session sid)) :status "running")
                                 harness-ui--sessions)
                        (should (string-search (harness-ui-pet-face (plist-get view :species) nil t)
                                               (with-current-buffer buf (car (harness-ui-pet--chat-header)))))
                        (puthash sid (plist-put (copy-sequence (harness-ui-session sid)) :status "idle")
                                 harness-ui--sessions)))
                  (customize-set-variable 'harness-ui-pet-places places))))
            (should-not (harness-ui-pet-test--own-hooks 'harness-chat-header-end-functions))
            ;; The chat on screen lets it speak about its session, and only that.
            (harness-test-wait (lambda () (equal (list sid) (harness-ui-pet-test--watching)))
                               5 "the harness told the chat is on screen")
            (let ((harness-ui-pet-places '(chat-header board)))
              (should-not (harness-ui-pet--seen)))
            (harness-call 'session/append sid (list :kind 'user :content "rewrite the tokenizer"))
            (harness-test-wait (lambda () (string-search "Tokenizer? Bold" (harness-ui-pet-test--figure-text buf)))
                               5 "its words beside it")
            (harness-ui-pet-test--check-figure buf)
            (with-current-buffer buf
              (save-excursion
                (goto-char (cdr (harness-ui-pet-test--figure buf)))
                (let ((words (search-forward "Tokenizer? Bold")))
                  (should (< words harness-compose-start))
                  ;; On the line of the pet's eyes, joined to them.
                  (pcase-let ((`(,art . ,eyes) (harness-ui-pet--figure-art harness-ui-pet--current))
                              (line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
                    (should (string-search (string-trim (nth eyes art)) line))
                    (should (string-match-p "[├|][─-]+ " line)))
                  ;; Hovering says when, and about which session.
                  (should (string-search "about Parser work"
                                         (funcall (get-text-property (1- words) 'help-echo)))))))
            ;; The session's next turn takes them away; the pet stays.
            (harness-ui-pet--on-event "agent/turn-started" (list sid))
            (should-not (string-search "Tokenizer? Bold" (harness-ui-pet-test--figure-text buf)))
            (harness-ui-pet-test--check-figure buf)
            ;; Nor do they last, nor show while it is muted or out of the places.
            (let* ((now (float-time))
                   (harness-ui-pet--current
                    (plist-put (copy-sequence harness-ui-pet--current) :said
                               (list (list :text "Hm." :ts now :session "s9")))))
              (should (harness-ui-pet--saying-for "s9" now))
              (should-not (harness-ui-pet--saying-for "s8" now))
              (should-not (harness-ui-pet--saying-for "s9" (+ now harness-ui-pet--saying-lifetime 1)))
              (let ((harness-ui-pet--current (plist-put (copy-sequence harness-ui-pet--current) :muted t)))
                (should-not (harness-ui-pet--saying-for "s9" now)))
              (let ((harness-ui-pet-places '(chat-header)))
                (should-not (harness-ui-pet--saying-for "s9" now))))
            ;; A window too short for it: it leaves, and comes back with the room.
            (with-current-buffer buf
              (let ((harness-ui-pet--min-lines 1000))
                (harness-ui-pet--sync-panels)
                (should-not (harness-ui-pet-test--figure buf)))
              (harness-ui-pet--sync-panels)
              (should (harness-ui-pet-test--figure buf)))
            ;; Drawn for a window that is not the selected one, its point at the
            ;; top: still below the transcript, right above the compose box.
            (let ((harness-ui-pet--min-lines 1)
                  (window (split-window)))
              (unwind-protect
                  (progn
                    (switch-to-buffer other)
                    (should (eq buf (window-buffer window)))
                    (set-window-point window (with-current-buffer buf (point-min)))
                    (with-current-buffer buf (setq harness-ui-pet--panel-shown nil))
                    (harness-ui-pet--sync-panels)
                    (let ((start (cdr (harness-ui-pet-test--figure buf))))
                      (should start)
                      (with-current-buffer buf
                        (should (< (save-excursion (goto-char (point-min)) (search-forward "rewrite the tokenizer"))
                                   start harness-compose-start))))
                    (harness-ui-pet-test--check-figure buf))
                (delete-window window)
                (switch-to-buffer buf)))
            ;; The chat off screen: it is quiet again.
            (switch-to-buffer other)
            (harness-ui-pet--update-watch (selected-frame))
            (harness-test-wait (lambda () (null (harness-ui-pet-test--watching))) 5 "the watch to end")
            ;; Nor is its figure drawn again for want of a window...
            (let ((shown (buffer-local-value 'harness-ui-pet--panel-shown buf)))
              (should (nth 3 shown))
              (harness-ui-pet--sync-panels)
              (should (eq shown (buffer-local-value 'harness-ui-pet--panel-shown buf))))
            ;; ...and drawn off screen, for no window, it fits the next to show it.
            (with-current-buffer buf (funcall harness-compose-redraw-function))
            (should (harness-ui-pet-test--figure buf))
            (should-not (nth 3 (buffer-local-value 'harness-ui-pet--panel-shown buf)))
            (switch-to-buffer buf)
            (harness-ui-pet--on-window-buffer (selected-frame))
            (harness-test-wait (lambda () (nth 3 (buffer-local-value 'harness-ui-pet--panel-shown buf)))
                               5 "the figure fitted to the window")
            (harness-ui-pet-test--check-figure buf))
        (kill-buffer buf)
        (kill-buffer other)))))

(ert-deftest harness-ui-pet-shows-on-the-board ()
  "Hatched, the whole pet sits above the board's compose box, saying what it
said last about anything: the board on screen lets it speak.  Its face
and name can show in the board's header line too; a narrower board loses
its name first, then its face."
  (harness-ui-pet-test-with
    (let ((harness-acp--server-enabled nil))
      (harness-test-load-module 'tasks))
    (clrhash harness-tasks--table)
    (clrhash harness-tasks--starting)
    (setq harness-tasks--loaded t)
    (harness-test-load-module 'ui-tasks)
    (let ((harness-tasks-worktrees nil)
          (board (harness-tasks dir)))
      (unwind-protect
          (progn
            (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board)))
                               5 "the board to load")
            (harness-ui-pet-test--know-the-pet)
            (should-not (harness-ui-pet-test--own-hooks 'harness-ui-tasks-tail-functions))
            (should-not (harness-ui-pet-test--figure board))
            (harness-ui-pet-test--hatch-elsewhere)
            ;; The whole creature, above the compose label.
            (harness-test-wait (lambda () (harness-ui-pet-test--figure board)) 5 "the pet on the board")
            (harness-ui-pet-test--check-figure board)
            (with-current-buffer board
              (goto-char (cdr (harness-ui-pet-test--figure board)))
              (should (search-forward "New task" nil t)))
            ;; The board on screen lets it speak about anything, and it shows.
            (harness-test-wait (lambda () (eq t (harness-ui-pet-test--watching))) 5 "the board's watch")
            (should-not (harness-ui-pet-test--own-hooks 'harness-ui-tasks-header-functions))
            (harness-call 'pet/pet)
            (harness-test-wait (lambda () (string-search "Yes. That." (harness-ui-pet-test--figure-text board)))
                               5 "its words on the board")
            (harness-ui-pet-test--check-figure board)
            ;; Muted, its words leave the board; the pet stays.
            (harness-call 'pet/set-muted t)
            (harness-test-wait (lambda () (not (string-search "Yes. That." (harness-ui-pet-test--figure-text board))))
                               5 "its words to leave")
            (harness-ui-pet-test--check-figure board)
            (harness-call 'pet/set-muted :false)
            ;; Its face and name in the header line, when asked for.
            (let ((places harness-ui-pet-places))
              (unwind-protect
                  (progn
                    (customize-set-variable 'harness-ui-pet-places '(board board-header))
                    (let* ((view harness-ui-pet--current)
                           (face (harness-ui-pet-face (plist-get view :species) (plist-get view :eye)))
                           (name (plist-get view :name))
                           (header (with-current-buffer board (harness-ui-tasks--header most-positive-fixnum)))
                           (width (harness-ui-header-string-width header)))
                      (should (string-search (concat face " " name) header))
                      (should (< (string-search face header) (string-search "[BTW]" header)))
                      (let ((narrower (with-current-buffer board
                                        (harness-ui-tasks--header (- width (length name) 1)))))
                        (should (string-search face narrower))
                        (should-not (string-search name narrower)))
                      (let ((narrower (with-current-buffer board
                                        (harness-ui-tasks--header (- width (length name) (length face) 4)))))
                        (should-not (string-search face narrower)))))
                (customize-set-variable 'harness-ui-pet-places places)))
            ;; Out of the places, it leaves the board.
            (let ((places harness-ui-pet-places))
              (unwind-protect
                  (progn
                    (customize-set-variable 'harness-ui-pet-places '(chat))
                    (should-not (harness-ui-pet-test--figure board))
                    (should-not (harness-ui-pet-test--own-hooks 'harness-ui-tasks-tail-functions)))
                (customize-set-variable 'harness-ui-pet-places places)))
            (should (harness-ui-pet-test--figure board)))
        (kill-buffer board)))))

(defun harness-ui-pet-test--draw (view saying room)
  "VIEW's figure with SAYING, fitted to ROOM columns: its lines, or nil."
  (with-temp-buffer
    (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list room 40 1))))
      (let* ((harness-ui-pet--current view)
             (spec (harness-ui-pet--spec saying)))
        (and spec (split-string (harness-ui-pet--figure view (nth 1 spec) (nth 2 spec)) "\n" t))))))

(ert-deftest harness-ui-pet-figure-fits-its-room ()
  "Every species, in every hat, whole and right-aligned in the room it has:
its bubble beside it, joined at its eyes, with room; above it with less;
left out with less still; and no figure where even the pet does not fit."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  ;; Where the bubble goes.
  (should (eq 'none (harness-ui-pet--fit 10 12 nil)))
  (should-not (harness-ui-pet--fit 80 12 nil))
  (should (equal '(beside . 40) (harness-ui-pet--fit 80 12 (make-string 60 ?a))))
  (should (equal '(beside . 5) (harness-ui-pet--fit 80 12 "Hello")))
  (should (equal '(above . 24) (harness-ui-pet--fit 30 12 (make-string 60 ?a))))
  (should-not (harness-ui-pet--fit 11 7 (make-string 60 ?a)))
  (should (eq 'none (harness-ui-pet--fit 13 12 "Hello")))
  ;; Words wrap at spaces; a word longer than a line is cut.
  (should (equal '("one two" "three") (harness-ui-pet--wrap "one two  three" 7)))
  (should (equal '("a" "veryl" "ongwo" "rdind" "eed b") (harness-ui-pet--wrap "a verylongwordindeed b" 5)))
  (should (eq 'bold (get-text-property 0 'face (car (harness-ui-pet--wrap (propertize "hi there" 'face 'bold) 20)))))
  (let ((said (list :text "*tilts head* Tokenizer? Bold. I like it, and the tests will too." :ts (float-time))))
    (dolist (species harness-pet-species)
      (dolist (hat harness-pet-hats)
        (let* ((view (list :species (symbol-name species) :eye "o" :hat (symbol-name hat)
                           :rarity "rare" :name "Fennel"))
               (art (harness-ui-pet--figure-art view)))
          (dolist (room '(100 40 24 14))
            (dolist (saying (list nil said))
              (let ((lines (harness-ui-pet-test--draw view saying room))
                    (text nil))
                (should lines)
                (setq text (string-join lines "\n"))
                ;; Whole, named, right-aligned and within the room.
                (dolist (line (car art))
                  (should (string-search (string-trim line) text)))
                (should (string-search "Fennel" text))
                (dolist (line lines)
                  (should (eq 'space (car (get-text-property 0 'display line))))
                  (should (<= (string-width (substring line 1)) (- room 2))))
                (should (= 1 (length (delete-dups (mapcar #'string-width lines)))))
                (when saying
                  (pcase (car (harness-ui-pet--fit room (harness-ui-pet--figure-width (car art) "Fennel")
                                                   (harness-ui-pet--speech (plist-get saying :text))))
                    ('beside
                     (should (string-search "Tokenizer?" text))
                     ;; Its first words on the line of its eyes.
                     (let ((joined (cl-find-if (lambda (line) (string-search "├" line)) lines)))
                       (should joined)
                       (should (string-search (string-trim (nth (cdr art) (car art))) joined))))
                    ('above
                     (should (string-search "Tokenizer?" text))
                     (should (string-search "╰" (nth (1- (- (length lines) (length (car art)) 1)) lines))))
                    (_ (should-not (string-search "Tokenizer?" text)))))))))))
    ;; A room too narrow for the pet: no figure at all.
    (should-not (harness-ui-pet-test--draw (list :species "chonk" :eye "o" :hat "none" :name "Fennel") said 8))))

(ert-deftest harness-ui-pet-places-are-optional ()
  "`harness-ui-pet-places' says where the pet shows; nothing is wired for the rest."
  (harness-ui-pet-test-with
    (harness-ui-pet-test--know-the-pet)
    (harness-ui-pet-test--hatch-elsewhere)
    ;; By default by the compose boxes of chats and the board, not in header lines.
    (dolist (hook '(harness-chat-panel-functions harness-ui-tasks-tail-functions
                    window-size-change-functions text-scale-mode-hook))
      (should (harness-ui-pet-test--own-hooks hook)))
    (dolist (hook '(harness-chat-header-end-functions harness-ui-tasks-header-functions))
      (should-not (harness-ui-pet-test--own-hooks hook)))
    (let ((places harness-ui-pet-places))
      (unwind-protect
          (progn
            (customize-set-variable 'harness-ui-pet-places '(chat-header board-header))
            (dolist (hook '(harness-chat-header-end-functions harness-ui-tasks-header-functions))
              (should (harness-ui-pet-test--own-hooks hook)))
            (dolist (hook '(harness-chat-panel-functions harness-ui-tasks-tail-functions
                            window-size-change-functions text-scale-mode-hook))
              (should-not (harness-ui-pet-test--own-hooks hook)))
            (should (harness-ui-pet--chat-header))
            (should (harness-ui-pet--board-header))
            (should-not (harness-ui-pet--panel))
            (should-not (harness-ui-pet--board-tail)))
        (customize-set-variable 'harness-ui-pet-places places)))
    (should (harness-ui-pet-test--own-hooks 'harness-chat-panel-functions))
    (should-not (harness-ui-pet--board-header))
    ;; The module stopped, the pet leaves every place.
    (harness-ui-pet--shutdown)
    (dolist (hook '(harness-chat-header-end-functions harness-chat-panel-functions
                    harness-ui-tasks-header-functions harness-ui-tasks-tail-functions
                    window-buffer-change-functions window-size-change-functions text-scale-mode-hook))
      (should-not (harness-ui-pet-test--own-hooks hook)))
    (should-not (harness-ui-pet--board-tail))
    (should-not (harness-ui-pet--board-header))))

(ert-deftest harness-ui-pet-turned-off-shows-nowhere ()
  "Turned off, the pet leaves every place and its buffer says so, offering
only to turn it on; that is saved, and turned on it is back as it was."
  (harness-ui-pet-test-with
    (let* ((harness-pet-enabled t)
           ;; Like a normal session: customize refuses to save under "emacs -q".
           (init-file-user "")
           (user-init-file (expand-file-name "init.el" dir))
           (custom-file (expand-file-name "custom.el" dir))
           (buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (let ((name (plist-get harness-ui-pet--current :name)))
        (should (harness-ui-pet-test--own-hooks 'harness-chat-panel-functions))
        (should (harness-ui-pet-test--own-hooks 'harness-ui-tasks-tail-functions))
        (with-current-buffer buf (harness-ui-pet-toggle-enabled))
        (harness-ui-pet-test--wait-text (regexp-quote (format "%s is asleep" name)))
        (should-not harness-pet-enabled)
        (should (eq :false (plist-get harness-ui-pet--current :enabled)))
        ;; Nowhere else, and nothing wired for it but the buffer's watch.
        (dolist (hook '(harness-chat-header-end-functions harness-chat-panel-functions
                        harness-ui-tasks-header-functions harness-ui-tasks-tail-functions
                        window-size-change-functions text-scale-mode-hook))
          (should-not (harness-ui-pet-test--own-hooks hook)))
        (let ((harness-ui-pet-places '(chat board chat-header board-header)))
          (should-not (harness-ui-pet--chat-header))
          (should-not (harness-ui-pet--board-header))
          (should-not (harness-ui-pet--panel))
          (should-not (harness-ui-pet--board-tail)))
        ;; Its buffer offers to turn it on, and nothing else.
        (let ((header (format "%s" (with-current-buffer buf (harness-ui-pet--header)))))
          (should (string-match-p "Turn on" header))
          (dolist (label '("Pet" "Rename" "Mute" "Release" "Hatch"))
            (should-not (string-match-p (format "\\_<%s\\_>" label) header))))
        (should (string-match-p "Turn it on" (harness-ui-pet-test--text)))
        (with-current-buffer buf
          (should-error (harness-ui-pet-pet) :type 'user-error)
          (should-error (harness-ui-pet-toggle-mute) :type 'user-error)
          (should-error (harness-ui-pet-release t) :type 'user-error))
        ;; Kept so, as the Settings page keeps a setting.
        (harness-test-wait (lambda () (and (file-exists-p custom-file)
                                           (string-match-p "harness-pet-enabled" (harness-read-file custom-file))))
                           5 "the custom file")
        ;; On again: as it was.
        (with-current-buffer buf (harness-ui-pet-turn-on))
        (harness-test-wait #'harness-ui-pet--active-p 5 "the pet back")
        (should harness-pet-enabled)
        (harness-ui-pet-test--wait-text "Level 1")
        (should (equal name (plist-get harness-ui-pet--current :name)))
        (should (harness-ui-pet-test--own-hooks 'harness-chat-panel-functions))
        (should (string-match-p "Turn off" (format "%s" (with-current-buffer buf (harness-ui-pet--header)))))))))

;;;; Animations

(ert-deftest harness-ui-pet-animations-stop-on-their-own ()
  "Each animation is a few frames on a timer that ends with it."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (with-current-buffer buf
        (let ((harness-ui-pet-animations t))
          (should-not harness-ui-pet--anim)
          (dolist (kind '(hearts sparkle fidget))
            (harness-ui-pet--animate kind)
            (should (timerp harness-ui-pet--timer))
            (should (eq kind (plist-get harness-ui-pet--anim :kind)))
            (let ((steps 0))
              (while (and harness-ui-pet--anim (< steps 20))
                (harness-ui-pet--step)
                (cl-incf steps))
              (should (< steps 10)))
            (should-not harness-ui-pet--anim)
            (should-not harness-ui-pet--timer))
          ;; Hearts show above the creature while they play, in their own colour.
          (harness-ui-pet--animate 'hearts)
          (harness-ui-pet--step)
          (should (string-search (string-trim (nth 1 harness-ui-pet--hearts)) (harness-ui-pet-test--text)))
          (goto-char (point-min))
          (search-forward "♥")
          (let ((faces (ensure-list (get-text-property (match-beginning 0) 'face))))
            (should (eq 'harness-pet-heart-face (car faces)))
            (should (memq 'harness-pet-art-face (flatten-tree faces))))
          (harness-ui-pet--stop)
          (should-not harness-ui-pet--timer)
          ;; Its first words come as it hatches: it fidgets once the sparkles end.
          (harness-ui-pet--animate 'sparkle)
          (harness-ui-pet--on-event "pet/said" (list (list :text "hi")))
          (should (eq 'sparkle (plist-get harness-ui-pet--anim :kind)))
          (should (eq 'fidget harness-ui-pet--queued))
          (let ((kinds nil))
            (while harness-ui-pet--anim
              (push (plist-get harness-ui-pet--anim :kind) kinds)
              (harness-ui-pet--step))
            (should (equal '(sparkle fidget) (delete-dups (nreverse kinds)))))
          (should-not harness-ui-pet--timer))))))

(ert-deftest harness-ui-pet-animations-only-on-screen ()
  "Nothing moves off screen or with animations off; leaving the screen stops it."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (with-current-buffer buf
        (setq harness-ui-pet--anim nil)
        ;; Off by option.
        (let ((harness-ui-pet-animations nil))
          (harness-ui-pet--animate 'hearts)
          (should-not harness-ui-pet--timer)
          (should-not harness-ui-pet--anim))
        (let ((harness-ui-pet-animations t))
          ;; Off screen.
          (cl-letf (((symbol-function 'harness-ui-pet--shown-p) #'ignore))
            (harness-ui-pet--animate 'hearts)
            (should-not harness-ui-pet--timer))
          ;; Leaving the screen mid-animation stops it at the next frame.
          (harness-ui-pet--animate 'hearts)
          (should (timerp harness-ui-pet--timer))
          (cl-letf (((symbol-function 'harness-ui-pet--shown-p) #'ignore))
            (harness-ui-pet--step))
          (should-not harness-ui-pet--timer)
          (should-not harness-ui-pet--anim))))))

(provide 'harness-ui-pet-test)
;;; harness-ui-pet-test.el ends here
