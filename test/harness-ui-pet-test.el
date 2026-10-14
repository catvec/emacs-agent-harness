;;; harness-ui-pet-test.el --- Tests for the companion pet's buffer  -*- lexical-binding: t; -*-
;;; Commentary:

;; The pet's buffer against the real state layer, the in-process ACP
;; connection and the demo provider: the art of every species, the egg
;; and its [Hatch it], the card it hatches into, what it says on a band
;; of its own, a narrow window, the harness told while the buffer is on
;; screen and no longer once it goes, animations that stop on their own,
;; and the beats of the figure by a compose box, which swap what it
;; displays and nothing else.  The rare 3D spin shows as slices of an
;; image over the creature's lines; a batch Emacs is no graphical frame,
;; so the tests that spin stand in for one (`harness-ui-pet-test-with-3d').

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

;; The harness loads its files compiled, and so do the tests: the renderer
;; the spin is drawn with is as quick here as it is there.
(dolist (name '("harness-ui-pet-models" "harness-ui-pet-3d"))
  (harness-load-compiled (expand-file-name (format "lisp/ui/%s.el" name) harness-test-root)))

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
(defvar harness-pet--recap-asked)
(defvar harness-pet--save-timer)
(defvar harness-pet-reactions)
(defvar harness-pet-model)
(defvar harness-pet-chance)
(defvar harness-pet-cooldown)
(defvar harness-pet-overrides)
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
(defvar harness-ui-pet--spin-turns)
(defvar harness-ui-pet-3d-count)
(defvar harness-ui-pet-3d-tick)
(defvar harness-ui-pet--sprite-cache)
(defvar harness-ui-pet--stats-column)
(defvar harness-ui-pet--view)
(defvar harness-ui-pet--anim)
(defvar harness-ui-pet--queued)
(defvar harness-ui-pet--timer)
(defvar harness-ui-pet--beat)
(defvar harness-ui-pet--beat-timer)
(defvar harness-ui-pet--idle-timer)
(defvar harness-ui-pet--moved)
(defvar harness-ui-pet--runs)
(defvar harness-ui-pet--live)
(defvar harness-ui-pet--fidget)
(defvar harness-ui-pet--idle-beats)
(defvar harness-ui-pet--idle-gap)
(defvar harness-ui-pet--tick)
(defvar harness-ui-pet--error)
(defvar harness-ui-pet--faces)
(defvar harness-ui-pet--current)
(defvar harness-ui-pet-saying-lifetime)
(defvar harness-ui-pet--fade-timer)
(defvar harness-ui-pet--watching)
(defvar harness-ui-pet--watch-timer)
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
(defvar harness-chat-top-functions)
(defvar harness-ui-sessions-footer-functions)
(defvar harness-ui-pet--lines-kept)
(defvar harness-ui-pet--figure-faces)
(defvar harness-chat--loading)
(defvar harness-chat--todos)
(defvar harness-chat--pending)
(defvar harness-chat--activity-overlay)
(defvar harness-chat--transcript-end)
(defvar harness-ui-sessions--buffer-name)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-ui-tasks-header-functions)
(defvar harness-ui-tasks-corner-functions)
(defvar harness-ui-pet-figure)
(defvar harness-ui-pet--whole-columns)
(defvar harness-ui-pet--bubble-max)
(defvar harness-ui-pet--quip-width)
(defvar harness-compose-overlay)
(defvar harness-ui-tasks--list-end)
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
(declare-function harness-ui-pet--figure-art "harness-ui-pet")
(declare-function harness-ui-pet--figure-width "harness-ui-pet")
(declare-function harness-ui-pet--eye "harness-ui-pet")
(declare-function harness-ui-pet--box "harness-ui-pet")
(declare-function harness-ui-pet--sprite "harness-ui-pet")
(declare-function harness-ui-pet--rows "harness-ui-pet")
(declare-function harness-ui-pet--draw "harness-ui-pet")
(declare-function harness-ui-pet--quip "harness-ui-pet")
(declare-function harness-ui-pet--chat-buffer-p "harness-ui-pet")
(declare-function harness-ui-pet--fit "harness-ui-pet")
(declare-function harness-ui-pet--wrap "harness-ui-pet")
(declare-function harness-ui-pet--spec "harness-ui-pet")
(declare-function harness-ui-pet--speech "harness-ui-pet")
(declare-function harness-ui-pet--rarity-face "harness-ui-pet")
(declare-function harness-ui-pet--panel "harness-ui-pet")
(declare-function harness-ui-pet--board-corner "harness-ui-pet")
(declare-function harness-ui-pet--sessions-spec "harness-ui-pet")
(declare-function harness-ui-pet--sessions-footer "harness-ui-pet")
(declare-function harness-ui-pet--latest-saying "harness-ui-pet")
(declare-function harness-ui-pet--where-it-speaks "harness-ui-pet")
(declare-function harness-ui-pet--list-buffers "harness-ui-pet")
(declare-function harness-ui-pet--pixels "harness-ui-pet")
(declare-function harness-ui-pet--wire "harness-ui-pet")
(declare-function harness-sessions "harness-ui-sessions")
(declare-function harness-ui-sessions-redraw "harness-ui-sessions")
(declare-function harness-ui-sessions--redraw "harness-ui-sessions")
(declare-function harness-chat--session "harness-ui-chat")
(declare-function harness-chat--apply-update "harness-ui-chat")
(declare-function harness-chat--render-tail "harness-ui-chat")
(declare-function harness-ui-cache-session "harness-ui-cache")
(declare-function harness-ui-tasks--refit-tail "harness-ui-tasks")
(declare-function harness-ui-tasks-redraw-tail-lines "harness-ui-tasks")
(declare-function harness-ui-pet--sync-panels "harness-ui-pet")
(declare-function harness-ui-pet--init "harness-ui-pet")
(declare-function harness-ui-pet-toggle-enabled "harness-ui-pet")
(declare-function harness-ui-pet-turn-on "harness-ui-pet")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat--header "harness-ui-chat")
(declare-function harness-ui-tasks--header "harness-ui-tasks")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-pet-art "harness-ui-pet")
(declare-function harness-ui-pet--cell "harness-ui-pet")
(declare-function harness-ui-pet--text-size "harness-ui-pet")
(declare-function harness-ui-pet--figure-char "harness-ui-pet")
(declare-function harness-ui-pet--slice "harness-ui-pet")
(declare-function harness-ui-pet--pace "harness-ui-pet")
(declare-function harness-ui-pet--graphic-p "harness-ui-pet")
(declare-function harness-ui-pet--spin-block "harness-ui-pet")
(declare-function harness-ui-pet--spin-refused "harness-ui-pet")
(declare-function harness-ui-pet--spinner-p "harness-ui-pet")
(declare-function harness-ui-pet--show-here "harness-ui-pet")
(declare-function harness-ui-pet--turn-picture "harness-ui-pet")
(declare-function harness-ui-pet--figure-box "harness-ui-pet")
(declare-function harness-ui-pet-3d-frame "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d-model "harness-ui-pet-3d")
(declare-function harness-ui-pet--header "harness-ui-pet")
(declare-function harness-ui-pet--render "harness-ui-pet")
(declare-function harness-ui-pet--animate "harness-ui-pet")
(declare-function harness-ui-pet--step "harness-ui-pet")
(declare-function harness-ui-pet--next "harness-ui-pet")
(declare-function harness-ui-pet-mode "harness-ui-pet")
(declare-function harness-ui-pet-spin "harness-ui-pet")
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
(declare-function harness-ui-pet--play "harness-ui-pet")
(declare-function harness-ui-pet--arm "harness-ui-pet")
(declare-function harness-ui-pet--still "harness-ui-pet")
(declare-function harness-ui-pet--beat-step "harness-ui-pet")
(declare-function harness-ui-pet--idle-beat "harness-ui-pet")
(declare-function harness-ui-pet--beat-frames "harness-ui-pet")
(declare-function harness-ui-pet--pick-beat "harness-ui-pet")
(declare-function harness-ui-pet--gap "harness-ui-pet")
(declare-function harness-ui-pet--show-frame "harness-ui-pet")
(declare-function harness-ui-pet--figure-buffers "harness-ui-pet")
(declare-function harness-ui-pet--animating-p "harness-ui-pet")
(declare-function harness-ui-pet--runs "harness-ui-pet")
(declare-function harness-ui-pet--redraw-tail "harness-ui-pet")
(declare-function harness-ui-pet--receive "harness-ui-pet")
(declare-function harness-ui-pet--when "harness-ui-pet")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function harness-pet--stop-waiting "harness-pet")
(declare-function harness-tasks--put "harness-tasks")
(declare-function harness-tasks--project "harness-tasks")
(declare-function harness-ui-pet--scope "harness-ui-pet")
(declare-function harness-ui-pet--last-in "harness-ui-pet")
(declare-function harness-ui-pet--lifetime-text "harness-ui-pet")
(declare-function harness-ui-pet--overview-sessions "harness-ui-pet")
(declare-function harness-ui-pet--on-focus "harness-ui-pet")

(defconst harness-ui-pet-test--buffer "*harness pet*")

(defun harness-ui-pet-test-reset ()
  "Forget the pet the harness knows of, as a fresh harness would."
  (when (timerp harness-pet--save-timer) (cancel-timer harness-pet--save-timer))
  (when (fboundp 'harness-pet--stop-waiting) (harness-pet--stop-waiting))
  (setq harness-pet--pet nil harness-pet--loaded nil harness-pet--dirty nil
        harness-pet--hatching nil harness-pet--speaking nil harness-pet--save-timer nil
        harness-pet--last-unasked 0 harness-pet--last-spoke 0 harness-pet--last-pet 0
        harness-pet--recap-asked 0)
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
           (harness-pet-overrides nil)
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

(defconst harness-ui-pet-test--cell '(10 . 20)
  "The pixels a column and a row of the pet's figure take, where the tests spin.")

(defconst harness-ui-pet-test--art-cell '(12 . 24)
  "The pixels a column and a row of the creature on the card take, as above.")

(defmacro harness-ui-pet-test-with-3d (&rest body)
  "Run BODY as if its buffers were in a graphical frame that shows SVG images.
A batch Emacs is no such frame, so `harness-ui-pet--graphic-p' says it is
one, and the cells the pictures are cut into are known: a column of the
figure is 10 pixels wide and a row 20 high, on the card 12 by 24.  The
3D frames themselves are the renderer's own."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'harness-ui-pet--graphic-p) (lambda () t))
             ((symbol-function 'harness-ui-pet--cell)
              (lambda (&optional _window faces)
                (if (eq faces 'harness-pet-art-face)
                    harness-ui-pet-test--art-cell
                  harness-ui-pet-test--cell))))
     ,@body))

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

(ert-deftest harness-ui-pet-capybara-faces-front ()
  "The capybara is drawn from the front, two eyes over a blunt snout.
Its three frames are those it had before it got a 3D model to spin, and
so is the column its hat goes on.  Awake it keeps its eyes in the same
places in its first two frames, chewing in the second; asleep in the
third it shuts them, under a \"z  z\"."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (should (equal '(("" "  n______n" " ( {E}    {E} )" " (   oo   )" "  `------'")
                   ("" "  n______n" " ( {E}    {E} )" " (   oO   )" "  `------'")
                   ("    z  z" "  n______n" " ( -    - )" " (   oo   )" "  `------'"))
                 (alist-get 'capybara harness-ui-pet--sprites)))
  (should (= 5.5 (alist-get 'capybara harness-ui-pet--heads)))
  (dolist (eye '("·" "o" "@"))
    (let* ((frames (mapcar (lambda (frame) (harness-ui-pet-art 'capybara eye 'none frame)) '(0 1 2)))
           (eyes (lambda (art) (length (split-string (nth 2 art) (regexp-quote eye))))))
      (dolist (art frames)
        (should (= 5 (length art)))
        (dolist (line art)
          (should (<= (string-width line) 17))
          ;; Plain ASCII but for the eye, whatever its font draws.
          (should (string-match-p "\\`[[:ascii:]]*\\'" (string-replace eye "" line)))))
      ;; Awake: two eyes, in the same places, and nothing above its head.
      (dolist (art (take 2 frames))
        (should (string-blank-p (car art)))
        (should (= 3 (funcall eyes art)))
        (should (equal (nth 2 (car frames)) (nth 2 art))))
      ;; Asleep: a shut pair in their places, and the z z.
      (let ((asleep (nth 2 frames)))
        (should (string-search "z  z" (car asleep)))
        (should (= 1 (funcall eyes asleep)))
        (should (equal (string-replace eye "-" (nth 2 (car frames))) (nth 2 asleep))))
      ;; The body stays where it is, from frame to frame; and it moves.
      (dolist (line '(1 3 4))
        (should (equal (nth line (car frames)) (nth line (nth 2 frames)))))
      (should-not (equal (car frames) (nth 1 frames)))
      (should-not (equal (car frames) (nth 2 frames)))))
  ;; The hat sits on the middle of its head.
  (let ((line (car (harness-ui-pet-art 'capybara "o" 'crown 0))))
    (should (string-suffix-p "\\^^^/" line))
    (should (<= (abs (- 5.5 (+ (- (length line) 5) 2.0))) 1.0))))

(ert-deftest harness-ui-pet-spin-is-not-drawn-in-text ()
  "The spin is a 3D turn shown as images: no text slab of it is left."
  (require 'harness-ui-pet)
  (dolist (symbol '(harness-ui-pet--spin-count harness-ui-pet--spin-depth harness-ui-pet--mirrors
                    harness-ui-pet--spin-shades harness-ui-pet--spins harness-ui-pet--spin-hit
                    harness-ui-pet--spin-line harness-ui-pet--spin-frames harness-ui-pet--spin-art))
    (should-not (boundp symbol))
    (should-not (fboundp symbol)))
  ;; A step of the turn is no frame of the art: asked for as one, it is an error.
  (let ((view (list :species "cat" :eye "o" :hat "none" :rarity "rare")))
    (should-error (harness-ui-pet--figure-art view '(spin . 1)))
    (should-error (harness-ui-pet--sprite view '(spin . 1)))))

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
      ;; q buries the pet rather than quitting its window.
      (should (eq #'harness-ui-quit-view (with-current-buffer buf (key-binding (kbd "q")))))
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
        (should (string-match-p "now and then has a word to say, through .*m mutes it, s spins it (a 3D turn, in graphical frames only), O turns it off\\." text))
        ;; Where, and of what: here, and in each place it sits where it speaks;
        ;; only while someone is at this Emacs; and for how long.
        (should (string-search (concat "while you are at this Emacs and it is on screen: here, about itself; "
                                       "beside a chat, about that chat's session; on the task board and the "
                                       "session list, about itself and in recaps of the sessions they list. "
                                       "What it says leaves its bubble after a minute.")
                               (harness-ui-pet-test--flat-text))))
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
      (harness-ui-pet-test--wait-text "Acknowledged\\. Do that again")
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

(ert-deftest harness-ui-pet-footer-names-what-is-set-by-hand ()
  "The footer says which attributes `harness-pet-overrides' sets, as soon as it changes,
and the card shows the pet they make."
  (harness-ui-pet-test-with
    (harness-ui-pet-test--open)
    (harness-ui-pet-test--hatch)
    (let ((hatched (plist-get harness-pet--pet :name)))
      (should-not (string-match-p "Set by hand" (harness-ui-pet-test--text)))
      ;; Set as the settings page sets it; the harness, in this process, sees it.  The
      ;; name is one that no hatched pet's is part of, so the card cannot show that one by chance.
      (setq harness-pet-overrides '(:name "Xyzzy" :species octopus))
      (harness-emit 'config/changed 'harness-pet-overrides harness-pet-overrides 'global nil)
      (harness-ui-pet-test--wait-text "Set by hand in harness-pet-overrides: name and species\\.")
      (let ((text (harness-ui-pet-test--flat-text)))
        (should (string-match-p "Xyzzy" text))
        (should (string-match-p "OCTOPUS" text))
        (should-not (string-match-p (regexp-quote hatched) text)))
      (should (string-match-p "Set by hand in harness-pet-overrides: snark\\."
                              (harness-ui-pet--by-hand (list :overrides (vector "snark")))))
      (should (string-match-p ": name, species and snark\\."
                              (harness-ui-pet--by-hand (list :overrides '("name" "species" "snark")))))
      (should-not (harness-ui-pet--by-hand (list :overrides nil)))
      ;; Gone, the footer forgets them and the pet is as it hatched.
      (setq harness-pet-overrides nil)
      (harness-emit 'config/changed 'harness-pet-overrides nil 'global nil)
      (harness-test-wait (lambda () (not (string-match-p "Set by hand" (harness-ui-pet-test--text))))
                         5 "the footer to forget the overrides")
      (should (string-match-p (regexp-quote hatched) (harness-ui-pet-test--text))))))

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
  "Where this Emacs told the harness it shows the pet, or nil for nowhere.
As the harness keeps it: (:self BOOL :sessions IDS :overview IDS)."
  (gethash (harness-ui-pet--client-id) harness-pet--watchers))

(defun harness-ui-pet-test--watch (self &optional sessions overview)
  "The watch the harness keeps for this Emacs showing SELF, SESSIONS and OVERVIEW."
  (list :self self :sessions sessions :overview overview))

(defun harness-ui-pet-test--figure-rows (buffer)
  "The rows of the pet's figure in BUFFER, top first, as plain text.
\(ROW START ALIGN LINE) each: ROW the figure's part of a line after the
space aligning it, START where that space is, ALIGN its `:align-to', and
LINE the whole line, the host's part of it included."
  (with-current-buffer buffer
    (let ((pos (point-min)) (rows nil))
      (while (setq pos (text-property-any pos (point-max) 'harness-ui-pet-figure t))
        (let* ((eol (save-excursion (goto-char pos) (line-end-position)))
               (end (min eol (or (text-property-not-all pos (point-max) 'harness-ui-pet-figure t) (point-max)))))
          (push (list (buffer-substring-no-properties (1+ pos) end)
                      pos
                      (plist-get (cdr (get-text-property pos 'display)) :align-to)
                      (buffer-substring-no-properties (save-excursion (goto-char pos) (line-beginning-position))
                                                      eol))
                rows)
          (setq pos (min (point-max) (1+ eol)))))
      (nreverse rows))))

(defun harness-ui-pet-test--figure (buffer)
  "The pet's figure by BUFFER's compose box: (TEXT . START), or nil.
TEXT is its rows as plain text, a line each, START where it begins."
  (when-let* ((rows (harness-ui-pet-test--figure-rows buffer)))
    (cons (mapconcat (lambda (row) (concat (car row) "\n")) rows "")
          (nth 1 (car rows)))))

(defun harness-ui-pet-test--figure-text (buffer)
  "The pet's figure by BUFFER's compose box as plain text, or \"\"."
  (or (car (harness-ui-pet-test--figure buffer)) ""))

(defun harness-ui-pet-test--tail (text width)
  "The last WIDTH columns of TEXT."
  (let ((wide (string-width text)))
    (truncate-string-to-width text wide (max 0 (- wide width)))))

(defun harness-ui-pet-test--bare (line)
  "LINE of the creature without the blanks around it, nor a line to a bubble."
  (string-trim line "[ ─-]+" " +"))

(defun harness-ui-pet-test--check-figure (buffer)
  "Check the pet's figure in BUFFER: once, whole, fitting its window, the pet's.
Its rows on lines one after another above the compose box -- or, in a
buffer without one, such as the session list, at its end -- the
creature's lines ending the last of them, in order, and nothing of it
the others; each row right-aligned by a space that ends where the row,
as drawn, ends a column short of the window's edge; in its rarity's
colour, on the window's own background in a chat or the session list;
hovering names it and a click shows it; each line of it marked with its
number."
  (pcase-let* ((view harness-ui-pet--current)
               (sprite (mapcar #'substring-no-properties (car (harness-ui-pet--sprite view))))
               (width (string-width (car sprite)))
               (rows (harness-ui-pet-test--figure-rows buffer))
               (ends (mapcar (lambda (row) (harness-ui-pet-test--tail (car row) width)) rows))
               (window (get-buffer-window buffer)))
    (should rows)
    ;; The whole creature once, ending the bottom rows -- where its bubble
    ;; joins it, a line runs up to it -- and blanks above it.
    (should (equal (mapcar #'harness-ui-pet-test--bare sprite)
                   (mapcar #'harness-ui-pet-test--bare (last ends (length sprite)))))
    (should (cl-every #'string-blank-p (butlast ends (length sprite))))
    (with-current-buffer buffer
      (let ((first (line-number-at-pos (nth 1 (car rows))))
            (box (bound-and-true-p harness-compose-start)))
        (cl-loop for row in rows
                 for line from first
                 do
                 ;; Lines one after another, above the compose box.
                 (should (= line (line-number-at-pos (nth 1 row))))
                 (when box (should (< (nth 1 row) box)))
                 ;; In batch a pixel is a column: the row, then the newline's.
                 (should (equal (list '- 'right (list (1+ (string-width (car row))))) (nth 2 row)))
                 (should (< (string-width (nth 3 row)) (window-body-width window))))
        (if box
            (should-not (text-property-any box (point-max) 'harness-ui-pet-figure t))
          ;; Nothing below it: the buffer ends with its last row's newline.
          (should (= (point-max) (save-excursion (goto-char (nth 1 (car (last rows))))
                                                 (1+ (line-end-position)))))))
      ;; Each line of the creature marked with its number, to the end of its row.
      (cl-loop for row in (last rows (length sprite))
               for j from 0
               do (should (eql j (get-text-property (+ (nth 1 row) (length (car row))) 'harness-ui-pet-row))))
      ;; Where the creature's last line starts: the pet's own colours and props.
      (let* ((row (car (last rows)))
             (last-line (car (last sprite)))
             (at (+ (nth 1 row) 1 (- (length (car row)) (length last-line))
                    (- (length last-line) (length (string-trim-left last-line)))))
             (faces (flatten-tree (get-text-property at 'face))))
        (should (eq (harness-ui-pet--rarity-face (plist-get view :rarity)) (car faces)))
        (should (memq 'harness-pet-figure-face faces))
        (when (or (harness-ui-pet--chat-buffer-p buffer)
                  (provided-mode-derived-p (buffer-local-value 'major-mode buffer) 'harness-ui-sessions-mode))
          ;; The window's own background, over any colour behind.
          (should (equal 'default (car (last (cl-remove 'harness-chat-panel-face faces))))))
        (should (eq #'harness-ui-pet--face-help (get-text-property at 'help-echo)))
        (should (keymapp (get-text-property at 'keymap)))))))

(defun harness-ui-pet-test--joined (buffer)
  "The row of the pet's figure in BUFFER where its bubble joins it, or nil.
Check it is the bubble's line of words nearest the creature's eyes."
  (pcase-let* ((view harness-ui-pet--current)
               (`(,sprite . ,eyes) (harness-ui-pet--sprite view))
               (sprite (mapcar #'substring-no-properties sprite))
               (width (string-width (car sprite)))
               (rows (mapcar #'car (harness-ui-pet-test--figure-rows buffer)))
               (top (- (length rows) (length sprite)))
               ;; The bubble's lines of words beside the creature...
               (words (cl-loop for row in rows for i from 0
                               when (and (>= i top) (> (string-width row) width)
                                         (string-match-p "\\`[│|] " row))
                               collect i))
               ;; ...and the one a line runs from to the creature: up to
               ;; the blanks it has in every frame, so short of this
               ;; one's first character by those it has fewer of.
               (joined (cl-loop for row in rows for i from 0
                                when (and (>= i top) (> (string-width row) width)
                                          (let* ((pet (string-trim-left (nth (- i top) sprite)))
                                                 (before (- (length row) (length pet) 1)))
                                            (while (and (> before 0) (eq (aref row before) ?\s))
                                              (cl-decf before))
                                            (and (>= before 0) (memq (aref row before) '(?─ ?-)))))
                                return i)))
    (when joined
      (should (eql joined (car (sort words (lambda (a b) (< (abs (- a top eyes)) (abs (- b top eyes)))))))))
    (and joined (nth joined rows))))

(ert-deftest harness-ui-pet-shows-in-a-chat ()
  "Hatched, the whole pet sits at the bottom right of a chat, first below
the transcript -- right above its compose box when nothing else is in
the tail -- its name beside its eyes.  What it says about the session
shows on its left instead, in a bubble joined to it at its eyes, until
the session's next turn.  A short window gets its face on one line.
Its face can end the chat's header line too, the first thing to go when
it is narrow, blinking while the session works."
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
            (dolist (hook '(harness-chat-header-end-functions harness-chat-top-functions
                            harness-chat-panel-functions window-size-change-functions))
              (should-not (harness-ui-pet-test--own-hooks hook)))
            (should-not (harness-ui-pet-test--watching))
            (should-not (harness-ui-pet-test--figure buf))
            (harness-ui-pet-test--hatch-elsewhere)
            ;; It goes first in the chat's tail, not among its panels.
            (should (harness-ui-pet-test--own-hooks 'harness-chat-top-functions))
            (should-not (harness-ui-pet-test--own-hooks 'harness-chat-panel-functions))
            ;; The whole creature, right above the compose box, named.
            (harness-test-wait (lambda () (harness-ui-pet-test--figure buf)) 5 "the pet above the compose box")
            (harness-ui-pet-test--check-figure buf)
            (should (string-search (plist-get harness-ui-pet--current :name) (harness-ui-pet-test--figure-text buf)))
            (with-current-buffer buf
              (should (= (line-number-at-pos harness-compose-start)
                         (1+ (line-number-at-pos (nth 1 (car (last (harness-ui-pet-test--figure-rows buf)))))))))
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
            ;; The chat on screen lets it speak about its session, and only that:
            ;; not about itself, which needs it shown itself.
            (harness-test-wait (lambda () (equal (harness-ui-pet-test--watch nil (list sid))
                                                 (harness-ui-pet-test--watching)))
                               5 "the harness told the chat is on screen")
            (let ((harness-ui-pet-places '(chat-header board)))
              (should-not (harness-ui-pet--seen)))
            (harness-call 'session/append sid (list :kind 'user :content "rewrite the tokenizer"))
            (harness-test-wait (lambda () (string-search "Tokenizer? Bold" (harness-ui-pet-test--figure-text buf)))
                               5 "its words beside it")
            (harness-ui-pet-test--check-figure buf)
            ;; In a bubble joined to it, no taller than it unless its words
            ;; need more lines than it has even at their widest: its name
            ;; makes way.
            (should (harness-ui-pet-test--joined buf))
            (pcase-let* ((`(whole . ,width) (nth 2 (buffer-local-value 'harness-ui-pet--panel-shown buf)))
                         (words (harness-ui-pet--speech (plist-get (nth 1 (buffer-local-value
                                                                           'harness-ui-pet--panel-shown buf))
                                                                   :text)))
                         (wrapped (length (harness-ui-pet--wrap words width))))
              (should (= (max (length (car (harness-ui-pet--sprite harness-ui-pet--current)))
                              (+ 2 (min wrapped 4)))
                         (length (harness-ui-pet-test--figure-rows buf)))))
            (should-not (string-search (plist-get harness-ui-pet--current :name)
                                       (harness-ui-pet-test--figure-text buf)))
            (with-current-buffer buf
              (save-excursion
                (goto-char (cdr (harness-ui-pet-test--figure buf)))
                (let ((words (search-forward "Tokenizer? Bold")))
                  (should (< words harness-compose-start))
                  ;; Hovering says it all, when, and about which session, on one line.
                  (let ((help (funcall (get-text-property (1- words) 'help-echo))))
                    (should (string-search "about Parser work" help))
                    (should (string-search "Tokenizer? Bold" help))
                    (should-not (string-search "\n" help))))))
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
              (should-not (harness-ui-pet--saying-for "s9" (+ now harness-ui-pet-saying-lifetime 1)))
              ;; With no lifetime, until it says something else.
              (let ((harness-ui-pet-saying-lifetime nil))
                (should (harness-ui-pet--saying-for "s9" (+ now 86400))))
              (let ((harness-ui-pet--current (plist-put (copy-sequence harness-ui-pet--current) :muted t)))
                (should-not (harness-ui-pet--saying-for "s9" now)))
              (let ((harness-ui-pet-places '(chat-header)))
                (should-not (harness-ui-pet--saying-for "s9" now))))
            ;; A window too short for it: its face on one line, and the
            ;; whole creature back with the room.
            (with-current-buffer buf
              (let ((harness-ui-pet--min-lines 1000))
                (harness-ui-pet--sync-panels)
                (let ((rows (harness-ui-pet-test--figure-rows buf))
                      (view harness-ui-pet--current))
                  (should (= 1 (length rows)))
                  (should (string-prefix-p (harness-ui-pet-face (plist-get view :species) (plist-get view :eye))
                                           (car (car rows))))
                  (should (string-search (plist-get view :name) (car (car rows))))))
              (harness-ui-pet--sync-panels)
              (harness-ui-pet-test--check-figure buf))
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
  "Hatched, the whole pet sits at the bottom right of the board, saying
what it said last about anything: the board on screen lets it speak.
The lines above the compose box narrow for its bottom rows, so it takes
few lines of its own, and it shows once however often they are drawn
again.  Its face and name can show in the board's header line too; a
narrower board loses its name first, then its face."
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
            (should-not (harness-ui-pet-test--own-hooks 'harness-ui-tasks-corner-functions))
            (should-not (harness-ui-pet-test--figure board))
            (harness-ui-pet-test--hatch-elsewhere)
            ;; The whole creature, its bottom rows ending the compose label
            ;; and the settings below it: two lines fewer of its own.
            (harness-test-wait (lambda () (harness-ui-pet-test--figure board)) 5 "the pet on the board")
            (harness-ui-pet-test--check-figure board)
            (let* ((rows (harness-ui-pet-test--figure-rows board))
                   (sprite (car (harness-ui-pet--sprite harness-ui-pet--current)))
                   (keys (with-current-buffer board
                           (mapcar (lambda (row) (get-text-property (nth 1 row) 'harness-task-tail)) rows))))
              ;; As tall as the creature, named beside its eyes.
              (should (= (length sprite) (length rows)))
              (should (string-search (plist-get harness-ui-pet--current :name)
                                     (harness-ui-pet-test--figure-text board)))
              (should (equal '(label settings) (last keys 2)))
              (should (cl-every (lambda (key) (eq key 'corner)) (butlast keys 2)))
              (should (string-prefix-p " New task" (nth 3 (car (last rows 2)))))
              (with-current-buffer board
                (should (= (line-number-at-pos harness-compose-start)
                           (1+ (line-number-at-pos (nth 1 (car (last rows)))))))))
            ;; Drawn again and again for a window that is not the selected
            ;; one, its point in the compose box: once still, the box left be.
            (let ((harness-ui-pet--min-lines 1)
                  (window (split-window))
                  (other (get-buffer-create " *harness-ui-pet-test other*")))
              (unwind-protect
                  (progn
                    (set-window-buffer window board)
                    (switch-to-buffer other)
                    (with-current-buffer board
                      (let ((inhibit-read-only t))
                        (goto-char harness-compose-start)
                        (insert "half a task"))
                      (set-window-point window (1+ harness-compose-start))
                      (dotimes (_ 3)
                        (setq harness-ui-pet--panel-shown nil)
                        (harness-ui-tasks-redraw-tail-lines (list board))
                        (harness-ui-tasks--refit-tail))
                      (harness-ui-pet-test--check-figure board)
                      (should (equal "half a task"
                                     (buffer-substring-no-properties harness-compose-start harness-compose-end)))
                      (let ((inhibit-read-only t))
                        (delete-region harness-compose-start harness-compose-end))))
                (delete-window window)
                (switch-to-buffer board)
                (kill-buffer other)))
            ;; The board on screen, with no tasks, lets it speak about itself, and it shows.
            (harness-test-wait (lambda () (equal (harness-ui-pet-test--watch t) (harness-ui-pet-test--watching)))
                               5 "the board's watch")
            (should-not (harness-ui-pet-test--own-hooks 'harness-ui-tasks-header-functions))
            (harness-call 'pet/pet)
            (harness-test-wait (lambda () (string-search "Acknowledged." (harness-ui-pet-test--figure-text board)))
                               5 "its words on the board")
            (harness-ui-pet-test--check-figure board)
            (should (harness-ui-pet-test--joined board))
            ;; Muted, its words leave the board; the pet stays.
            (harness-call 'pet/set-muted t)
            (harness-test-wait (lambda () (not (string-search "Acknowledged." (harness-ui-pet-test--figure-text board))))
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
                    (should-not (harness-ui-pet-test--own-hooks 'harness-ui-tasks-corner-functions)))
                (customize-set-variable 'harness-ui-pet-places places)))
            (should (harness-ui-pet-test--figure board)))
        (kill-buffer board)))))

(ert-deftest harness-ui-pet-sayings-leave-their-bubble ()
  "A saying leaves its bubble once `harness-ui-pet-saying-lifetime' is over: one
timer, armed for the oldest saying shown, draws the figure again without
it, its name back beside it.  The pet still knows what it said, and no
timer waits while no bubble shows a saying."
  (harness-ui-pet-test-with
    (harness-test-load-module 'ui-chat)
    (let* ((sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted" :name "Parser work") :id))
           (buf (harness-chat-buffer sid))
           (harness-ui-pet-saying-lifetime 1))
      (unwind-protect
          (progn
            (harness-test-wait (lambda () (with-current-buffer buf (and (not harness-chat--loading) harness-compose-end)))
                               5 "the chat to load")
            (switch-to-buffer buf)
            (harness-ui-pet-test--know-the-pet)
            (harness-ui-pet-test--hatch-elsewhere)
            (harness-test-wait (lambda () (harness-ui-pet-test--figure buf)) 5 "the pet above the compose box")
            (harness-test-wait (lambda () (equal (harness-ui-pet-test--watch nil (list sid))
                                                 (harness-ui-pet-test--watching)))
                               5 "the harness told the chat is on screen")
            ;; Nothing said here yet: nothing to wait for.
            (should-not harness-ui-pet--fade-timer)
            (harness-call 'session/append sid (list :kind 'user :content "rewrite the tokenizer"))
            (harness-test-wait (lambda () (string-search "Tokenizer? Bold" (harness-ui-pet-test--figure-text buf)))
                               5 "its words beside it")
            (should (timerp harness-ui-pet--fade-timer))
            ;; A second on, its words go, though nothing else happened.
            (harness-test-wait (lambda () (not (string-search "Tokenizer? Bold"
                                                              (harness-ui-pet-test--figure-text buf))))
                               5 "its words to leave the bubble")
            (should (string-search (plist-get harness-ui-pet--current :name) (harness-ui-pet-test--figure-text buf)))
            (harness-ui-pet-test--check-figure buf)
            (should-not harness-ui-pet--fade-timer)
            ;; Only the bubble forgot it.
            (dolist (said (list (plist-get harness-ui-pet--current :said) (plist-get harness-pet--pet :said)))
              (should (string-search "Tokenizer? Bold" (plist-get (car (last said)) :text)))))
        (kill-buffer buf)))))

(ert-deftest harness-ui-pet-board-recaps-its-tasks ()
  "The board tells the harness the sessions of its tasks, and its bubble says the
pet's recap of one of them; what the pet said about a task's work stays
in that task's chat.  A recap leaves the bubble as any saying does."
  (harness-ui-pet-test-with
    (let ((harness-acp--server-enabled nil))
      (harness-test-load-module 'tasks))
    (clrhash harness-tasks--table)
    (clrhash harness-tasks--starting)
    (setq harness-tasks--loaded t)
    (harness-test-load-module 'ui-tasks)
    (let* ((harness-tasks-worktrees nil)
           (harness-ui-pet-saying-lifetime 2)
           (sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted" :name "Parser work") :id))
           (board (harness-tasks dir)))
      (unwind-protect
          (progn
            (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board)))
                               5 "the board to load")
            (harness-ui-pet-test--know-the-pet)
            (harness-ui-pet-test--hatch-elsewhere)
            (harness-test-wait (lambda () (harness-ui-pet-test--figure board)) 5 "the pet on the board")
            ;; No task yet: the pet itself, and no session to recap.
            (harness-test-wait (lambda () (equal (harness-ui-pet-test--watch t) (harness-ui-pet-test--watching)))
                               5 "the board's watch")
            ;; A task of the board's, waiting for review, its session SID.
            (harness-tasks--put (list :id "t-recap" :project (harness-tasks--project dir) :cwd dir
                                      :state 'review :created (float-time) :prompt "Rewrite the lexer"
                                      :session sid))
            (harness-test-wait (lambda () (equal (list sid) (harness-ui-pet--overview-sessions board)))
                               5 "the task on the board")
            (harness-test-wait (lambda () (equal (harness-ui-pet-test--watch t nil (list sid))
                                                 (harness-ui-pet-test--watching)))
                               5 "the harness told the board lists the task")
            ;; Its recap: the pet's word on the board.
            (harness-emit 'recap/done sid "Rewrote the lexer; tests pass.")
            (harness-test-wait (lambda () (string-search "is still at it" (harness-ui-pet-test--figure-text board)))
                               5 "the recap on the board")
            (harness-ui-pet-test--check-figure board)
            (should (equal "overview" (plist-get (car (last (plist-get harness-ui-pet--current :said))) :scope)))
            ;; What it says about the task's work is for its chat, not the board.
            (harness-ui-pet--receive
             (plist-put (copy-sequence harness-ui-pet--current) :said
                        (append (plist-get harness-ui-pet--current :said)
                                (list (list :text "Bold move." :ts (float-time) :reason "prompt"
                                            :session sid :scope "session")))))
            (should-not (string-search "Bold move." (harness-ui-pet-test--figure-text board)))
            (should (string-search "is still at it" (harness-ui-pet-test--figure-text board)))
            ;; And the recap leaves in its time, the pet's name back.
            (harness-test-wait (lambda () (not (string-search "is still at it"
                                                              (harness-ui-pet-test--figure-text board))))
                               5 "the recap to leave")
            (should (string-search (plist-get harness-ui-pet--current :name) (harness-ui-pet-test--figure-text board))))
        (kill-buffer board)))))

(ert-deftest harness-ui-pet-asks-nothing-while-nobody-looks ()
  "While no frame of this Emacs has focus, the pet is seen nowhere: the harness
hears so, and the pet says nothing, petted or not.  Focus back, it is
seen again.  The focus is followed only while the pet may be seen."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open))
          (attended t))
      (harness-ui-pet-test--hatch)
      (harness-test-wait (lambda () (equal (harness-ui-pet-test--watch t) (harness-ui-pet-test--watching)))
                         5 "the watch")
      (should (advice-function-member-p #'harness-ui-pet--on-focus after-focus-change-function))
      (cl-letf (((symbol-function 'harness-ui-pet--frame-attended-p) (lambda (_frame) attended)))
        ;; Its frame loses focus: nobody looks.
        (setq attended nil)
        (should-not (harness-ui-pet--seen))
        (harness-ui-pet--on-focus)
        (harness-test-wait (lambda () (null (harness-ui-pet-test--watching))) 5 "the watch to end")
        (let ((said (length (plist-get harness-pet--pet :said))))
          (setq harness-pet--last-spoke 0)
          (with-current-buffer buf (harness-ui-pet-pet))
          (harness-ui-pet-test--wait-text "petted 1 time")
          (sleep-for 0.1)
          (should (= said (length (plist-get harness-pet--pet :said)))))
        ;; Focus back: seen again.
        (setq attended t)
        (harness-ui-pet--on-focus)
        (harness-test-wait (lambda () (equal (harness-ui-pet-test--watch t) (harness-ui-pet-test--watching)))
                           5 "the watch again"))
      ;; Seen nowhere it could be: the focus is not followed.
      (kill-buffer buf)
      (should (advice-function-member-p #'harness-ui-pet--on-focus after-focus-change-function))
      (let ((places harness-ui-pet-places))
        (unwind-protect
            (progn
              (customize-set-variable 'harness-ui-pet-places nil)
              (should-not (advice-function-member-p #'harness-ui-pet--on-focus after-focus-change-function)))
          (customize-set-variable 'harness-ui-pet-places places))))))

(defun harness-ui-pet-test--draw (view saying room &optional lines)
  "VIEW's figure with SAYING, fitted to ROOM columns and LINES (default 40).
Its rows, top first, as `harness-ui-pet--draw' draws them, or nil."
  (with-temp-buffer
    (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list room (or lines 40) 1))))
      (let* ((harness-ui-pet--current view)
             (spec (harness-ui-pet--spec saying)))
        (and spec (split-string (harness-ui-pet--draw spec) "\n" t))))))

(ert-deftest harness-ui-pet-figure-fits-its-room ()
  "Every species, in every hat, whole and right-aligned in the room it has,
its name beside its eyes or its bubble on its left, joined to it and no
taller than it; its face on one line, with its name or the first of its
words, in a window too narrow or too short for it, or when asked for;
no figure where not even its face fits."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (let* ((duck (list :species "duck" :eye "o" :hat "none" :rarity "rare" :name "Fennel"))
         (face (string-width (harness-ui-pet-face "duck" "o")))
         (long (string-join (make-list 40 "word") " ")))
    ;; How it fits: whole, with the columns its words take on a line...
    (should (equal '(whole . 0) (harness-ui-pet--fit duck 100 40 nil)))
    (should (equal '(whole . 5) (harness-ui-pet--fit duck 100 40 "Hello")))
    (should (equal '(whole . 30) (harness-ui-pet--fit duck 100 40 (make-string 50 ?a))))
    ;; ...more, so the bubble is no taller than the creature, up to a most...
    (should (equal (cons 'whole harness-ui-pet--bubble-max) (harness-ui-pet--fit duck 100 40 long)))
    (should (equal '(whole . 54) (harness-ui-pet--fit duck 69 40 long)))
    ;; ...or its face, with its name or its first words beside it.
    (should (equal '(face . 6) (harness-ui-pet--fit duck 39 40 nil)))
    (should (equal '(face . 6) (harness-ui-pet--fit duck 100 19 nil)))
    (should (equal (cons 'face harness-ui-pet--quip-width) (harness-ui-pet--fit duck 100 19 long)))
    (should (equal (cons 'face (- 20 2 face 1)) (harness-ui-pet--fit duck 20 40 long)))
    (let ((harness-ui-pet-figure 'face))
      (should (equal '(face . 6) (harness-ui-pet--fit duck 100 40 nil))))
    (should-not (harness-ui-pet--fit duck (+ face 1) 40 nil))
    ;; Cut short at a space, where there is one.
    (should (equal "one two…" (harness-ui-pet--quip "one two three" 10)))
    (should (equal "abcdefghi…" (harness-ui-pet--quip "abcdefghijklmnop" 10)))
    (should (equal "short" (harness-ui-pet--quip "short" 10))))
  ;; Words wrap at spaces; a word longer than a line is cut.
  (should (equal '("one two" "three") (harness-ui-pet--wrap "one two  three" 7)))
  (should (equal '("a" "veryl" "ongwo" "rdind" "eed b") (harness-ui-pet--wrap "a verylongwordindeed b" 5)))
  (should (eq 'bold (get-text-property 0 'face (car (harness-ui-pet--wrap (propertize "hi there" 'face 'bold) 20)))))
  (let ((said (list :text "*tilts head* Tokenizer? Bold. I like it, and the tests will too." :ts (float-time)))
        (rambling (list :text (string-join (make-list 60 "chatter") " ") :ts (float-time))))
    (dolist (species harness-pet-species)
      (dolist (hat harness-pet-hats)
        (pcase-let* ((view (list :species (symbol-name species) :eye "o" :hat (symbol-name hat)
                                 :rarity "rare" :name "Fennel"))
                     (`(,art . ,eyes) (harness-ui-pet--figure-art view))
                     ;; Every frame of it is as wide as the widest line of any.
                     (column (string-width (car (car (harness-ui-pet--sprite view)))))
                     (face (harness-ui-pet-face (symbol-name species) "o")))
          (dolist (room '(120 60 40 30 14))
            (dolist (saying (list nil said rambling))
              (dolist (lines '(40 10))
                (let* ((rows (harness-ui-pet-test--draw view saying room lines))
                       (text (string-join rows "\n"))
                       (whole (and (>= room 40) (>= lines 20))))
                  (should rows)
                  ;; Right-aligned, within the room.
                  (dolist (row rows)
                    (should (eq 'space (car (get-text-property 0 'display row))))
                    (should (<= (string-width (substring row 1)) (- room 2))))
                  (if whole
                      (progn
                        ;; The whole creature once, ending its bottom rows.
                        (should (equal (mapcar #'harness-ui-pet-test--bare art)
                                       (mapcar #'harness-ui-pet-test--bare
                                               (last (mapcar (lambda (row) (harness-ui-pet-test--tail row column))
                                                             rows)
                                                     (length art)))))
                        (if (null saying)
                            (progn
                              (should (= (length art) (length rows)))
                              ;; Its name beside its eyes.
                              (should (string-search "Fennel" (nth eyes rows))))
                          (should-not (string-search "Fennel" text))
                          ;; Its words beside it, joined to it; no taller than
                          ;; it, unless they would be wider than the most, and
                          ;; at most a few lines of them, the last cut short.
                          (should (string-search (if (eq saying said) "Tokenizer?" "chatter") text))
                          (should (cl-find-if (lambda (row) (string-match-p "[├|][─-]+" row)) rows))
                          (pcase-let* ((words (harness-ui-pet--speech (plist-get saying :text)))
                                       (`(whole . ,width) (harness-ui-pet--fit view room lines words))
                                       (wrapped (length (harness-ui-pet--wrap words width))))
                            (should (= (max (length art) (+ 2 (min wrapped 4))) (length rows)))
                            (when (eq saying said)
                              (should (or (= (length art) (length rows))
                                          (= width (min harness-ui-pet--bubble-max
                                                        (- room 2 column 5))))))
                            (should (eq (> wrapped 4) (and (string-search "…" text) t))))))
                    ;; Its face on one line, its name or the first of its words.
                    (should (= 1 (length rows)))
                    (should (string-search face text))
                    (when (>= room 30)
                      (should (string-search (if saying "“" "Fennel") text))))))))))
      ;; A room too narrow even for its face: no figure at all.
      (should-not (harness-ui-pet-test--draw (list :species "chonk" :eye "o" :hat "none" :name "Fennel") said 6)))))

;;;; Its frames

(defun harness-ui-pet-test--leading (text)
  "The blanks TEXT begins with."
  (- (length text) (length (string-trim-left text))))

(defun harness-ui-pet-test--frames ()
  "Every frame of the creature's art a figure has: at rest, the others, eyes shut.
A step of the spin is a picture, not a frame of the art."
  '(0 1 2 blink))

(ert-deftest harness-ui-pet-figure-frames-share-a-geometry ()
  "Every frame of a figure has the geometry of the one at rest.
For every species, with eyes that need a fallback or not, a hat or none:
as many rows, as wide, each marked with its number and the eyes on the
same one; the rest frame's lines moved left by the margin all frames
share, none of them further than that, and padded to the widest of any;
the hat's row the rest frame's, whatever a frame draws above the head."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (dolist (species harness-pet-species)
    (dolist (hat harness-pet-hats)
      (dolist (eye '("·" "o"))
        (let* ((view (list :species (symbol-name species) :eye eye :hat (symbol-name hat)
                           :rarity "rare" :name "Fennel"))
               (drawn (harness-ui-pet--eye eye))
               (art (harness-ui-pet-art species drawn hat 0))
               (first (cl-position-if-not #'string-blank-p art))
               (last (cl-position-if-not #'string-blank-p art :from-end t))
               (rest (harness-ui-pet--sprite view))
               (width (string-width (car (car rest))))
               ;; What a frame keeps of its lines: those of the rest frame, the first its own.
               (kept (lambda (frame)
                       (cl-subseq (cons (car art)
                                        (cdr (harness-ui-pet-art species (if (eq frame 'blink) "-" drawn) hat
                                                                 (if (eq frame 'blink) 0 frame))))
                                  first (1+ last))))
               (margin (apply #'min (mapcar #'harness-ui-pet-test--leading
                                            (cl-remove-if #'string-blank-p
                                                          (mapcan (lambda (frame) (copy-sequence (funcall kept frame)))
                                                                  '(0 1 2)))))))
          (should (eq rest (harness-ui-pet--sprite view 0)))
          (dolist (frame (harness-ui-pet-test--frames))
            (pcase-let ((`(,rows . ,eyes) (harness-ui-pet--sprite view frame)))
              (should (= (1+ (- last first)) (length rows)))
              (should (= (cdr rest) eyes))
              (cl-loop for row in rows for i from 0
                       do (should (= width (string-width row)))
                          (should-not (text-property-not-all 0 (length row) 'harness-ui-pet-row i row)))))
          ;; At rest, in its other frames and with its eyes shut: the species's lines, all
          ;; moved left by the same, the smallest margin any of them has.
          (dolist (frame '(0 1 2 blink))
            (cl-mapc (lambda (line row)
                       (should (equal (string-trim line) (string-trim row)))
                       (unless (string-blank-p line)
                         (should (= margin (- (harness-ui-pet-test--leading line)
                                              (harness-ui-pet-test--leading row))))))
                     (funcall kept frame) (car (harness-ui-pet--sprite view frame))))
          ;; Padded to the widest line of any of them, which reaches the left edge.
          (should (= width (apply #'max (mapcar (lambda (frame)
                                                  (apply #'max 1 (mapcar (lambda (row) (string-width (string-trim-right row)))
                                                                         (car (harness-ui-pet--sprite view frame)))))
                                                '(0 1 2)))))
          (should (= width (harness-ui-pet--figure-width view)))
          (should (= 0 (apply #'min (mapcar (lambda (row) (harness-ui-pet-test--leading row))
                                            (cl-remove-if #'string-blank-p
                                                          (mapcan (lambda (frame) (copy-sequence (car (harness-ui-pet--sprite view frame))))
                                                                  '(0 1 2)))))))
          ;; The hat's row is always the rest frame's.
          (when (= first 0)
            (dolist (frame '(1 2 blink))
              (should (equal (car (car rest)) (car (car (harness-ui-pet--sprite view frame)))))))))))
  ;; A frame that draws above the head -- a sleeper's "z  z" -- shows that in the pet's own
  ;; buffer only: not by a compose box, nor over a hat.
  (let ((view (list :species "capybara" :eye "o" :hat "none" :rarity "rare")))
    (should (string-search "z  z" (car (harness-ui-pet-art 'capybara "o" 'none 2))))
    (should-not (string-search "z  z" (string-join (car (harness-ui-pet--sprite view 2)) "\n"))))
  (let ((view (list :species "capybara" :eye "o" :hat "crown" :rarity "rare")))
    (should (string-search "\\^^^/" (car (car (harness-ui-pet--sprite view 2))))))
  ;; Frames by number wrap, as the art's do; no frame is an error.
  (let ((view (list :species "cat" :eye "o" :hat "none" :rarity "rare")))
    (should (equal (harness-ui-pet--figure-art view) (harness-ui-pet--figure-art view 0)))
    (should (equal (harness-ui-pet--figure-art view 1) (harness-ui-pet--figure-art view 4)))
    (should (eq (harness-ui-pet--sprite view 2) (harness-ui-pet--sprite view 5)))
    (should-error (harness-ui-pet--figure-art view 'bogus))))

(ert-deftest harness-ui-pet-sprite-is-kept-for-the-next-to-ask ()
  "A frame of a figure is drawn once for a look and an eye as it is drawn.
The rows are shared by whoever asks, in the colour of its rarity; another
look, or an eye the font draws otherwise, is another entry, and the table
stays small."
  (require 'harness-ui-pet)
  (let ((view (list :species "cat" :eye "·" :hat "none" :rarity "rare" :name "Fennel"))
        (harness-ui-pet--sprite-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'harness-ui-pet--has-glyph-p) (lambda (_) t)))
      (let ((kept (harness-ui-pet--sprite view 1)))
        (should (eq kept (harness-ui-pet--sprite view 1)))
        (should (eq kept (harness-ui-pet--sprite (copy-sequence view) 1)))
        (should (eq kept (harness-ui-pet--sprite view 4)))
        (should-not (eq kept (harness-ui-pet--sprite view 2)))
        ;; In the colour of its rarity, with the look of the pet.
        (should (eq (harness-ui-pet--rarity-face "rare") (get-text-property 0 'face (car (car kept)))))
        (should (eq #'harness-ui-pet--face-help (get-text-property 0 'help-echo (car (car kept)))))
        (let ((epic (harness-ui-pet--sprite (plist-put (copy-sequence view) :rarity "epic") 1)))
          (should-not (eq kept epic))
          (should (equal (mapcar #'substring-no-properties (car kept))
                         (mapcar #'substring-no-properties (car epic))))
          (should (eq (harness-ui-pet--rarity-face "epic") (get-text-property 0 'face (car (car epic))))))
        ;; An eye the creature's font lacks is drawn as a fallback: another entry.
        (should (string-search "·" (nth 1 (car kept))))
        (cl-letf (((symbol-function 'harness-ui-pet--has-glyph-p) (lambda (_) nil)))
          (let ((without (harness-ui-pet--sprite view 1)))
            (should-not (eq kept without))
            (should-not (string-search "·" (string-join (car without) "\n")))
            (should (string-search "..." (nth 1 (car without))))
            (should (eq without (harness-ui-pet--sprite view 1)))))
        (should (eq kept (harness-ui-pet--sprite view 1)))))
    ;; A table that stays small, whatever the pet looks like and however often it is asked.
    (dotimes (n 100)
      (harness-ui-pet--sprite (list :species "duck" :eye "o" :hat "none" :rarity "common"
                                    :name (format "Pet %d" n))
                              (% n 3)))
    (should (<= (hash-table-count harness-ui-pet--sprite-cache) 65))))

(ert-deftest harness-ui-pet-face-is-marked-as-the-creature ()
  "The face of the pet on one line is the figure's row `face'; its name is not."
  (require 'harness-ui-pet)
  (let* ((view (list :species "cat" :eye "o" :hat "none" :rarity "rare" :name "Fennel"))
         (face (harness-ui-pet-face "cat" "o"))
         (row (car (car (harness-ui-pet--rows view nil '(face . 6))))))
    (should (string-prefix-p face row))
    (should-not (text-property-not-all 0 (length face) 'harness-ui-pet-row 'face row))
    (should-not (text-property-any (length face) (length row) 'harness-ui-pet-row 'face row))
    (should (string-search "Fennel" row))))

(defun harness-ui-pet-test--creature (row)
  "The part of a figure ROW that is the creature: (START INDEX), or nil.
START is where it begins, INDEX the number its characters are marked with."
  (when-let* ((start (text-property-not-all 0 (length row) 'harness-ui-pet-row nil row)))
    (list start (get-text-property start 'harness-ui-pet-row row))))

(ert-deftest harness-ui-pet-figure-rows-mark-the-creature ()
  "Each row of a figure marks the creature in it with the number of its row.
The marks are the last columns of the rows it ends: all of them, but for the
blanks a line to a speech bubble takes; the bubble and the name are not marked.
That line runs over the blanks the creature has in every frame -- at rest, in
its other frames and with its eyes shut -- so it never covers a character of
those; for every species and hat, and for a creature made to show it."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (let ((said (list :text "Tokenizer? Bold." :ts (float-time)))
        (across (nth 4 (harness-ui-pet--box)))
        (checked 0))
    (cl-flet ((check (view saying)
                (let* ((width (harness-ui-pet--figure-width view))
                       (all (mapcar (lambda (frame) (car (harness-ui-pet--sprite view frame)))
                                    '(0 1 2 blink)))
                       (fewest (lambda (index)
                                 (apply #'min (mapcar (lambda (rows) (harness-ui-pet-test--leading (nth index rows)))
                                                      all))))
                       (rows (car (harness-ui-pet--rows view saying (if saying '(whole . 20) '(whole . 0)))))
                       (top (- (length rows) (length (car all))))
                       (joints nil))
                  (cl-loop
                   for row in rows for i from 0
                   do (pcase (harness-ui-pet-test--creature row)
                        ('nil (should (< i top)))
                        (`(,start ,index)
                         (should (= index (- i top)))
                         ;; Marked to the end of the row, whole or less the line to the bubble.
                         (should-not (text-property-not-all start (length row) 'harness-ui-pet-row index row))
                         (let ((lead (- width (- (length row) start))))
                           (should (>= lead 0))
                           (if (and (> start 0) (eq (aref row (1- start)) across))
                               (progn
                                 (push index joints)
                                 ;; Over blanks all frames have, and all of them but its own.
                                 (should (= lead (funcall fewest index)))
                                 (dolist (frame all)
                                   (should (string-blank-p (substring (nth index frame) 0 lead)))))
                             (should (= 0 lead))
                             (should (equal (substring-no-properties row start)
                                            (substring-no-properties (nth index (car all))))))))))
                  (should (= (if saying 1 0) (length joints)))
                  (cl-incf checked))))
      (dolist (species harness-pet-species)
        (dolist (hat '(none crown))
          (let ((view (list :species (symbol-name species) :eye "o" :hat (symbol-name hat)
                            :rarity "rare" :name "Fennel")))
            (check view nil)
            (check view said))))
      ;; A creature whose eyes sit further left in its other frames than at rest: the line
      ;; to its bubble stops short of them, a column in.
      (let ((harness-ui-pet--sprites
             (list '(blob ("" "  {E}" "(   )" "") ("" " {E}" "(   )" "") ("" "   {E}" "(   )" ""))))
            (harness-ui-pet--sprite-cache (make-hash-table :test 'equal))
            (view (list :species "blob" :eye "o" :hat "none" :rarity "rare" :name "Fennel")))
        (should (= 5 (harness-ui-pet--figure-width view)))
        (check view said)
        (let* ((row (nth 1 (car (harness-ui-pet--rows view said '(whole . 20)))))
               (start (car (harness-ui-pet-test--creature row))))
          ;; The creature's eyes row without its first column, after a line of one blank more.
          (should (equal "  o  " (substring-no-properties (nth 0 (car (harness-ui-pet--sprite view))))))
          (should (equal " o  " (substring-no-properties row start)))
          (should (eq across (aref row (1- start))))
          (should (eq across (aref row (- start 2))))))
      (should (= (1+ (* 2 2 (length harness-pet-species))) checked)))))

(ert-deftest harness-ui-pet-places-are-optional ()
  "`harness-ui-pet-places' says where the pet shows; nothing is wired for the rest.
By default it stands in chats, on the board and under the session list."
  (harness-ui-pet-test-with
    (harness-ui-pet-test--know-the-pet)
    (harness-ui-pet-test--hatch-elsewhere)
    (cl-flet ((wired (hook) (and (harness-ui-pet-test--own-hooks hook) t))
              (places (&rest places)
                (customize-set-variable 'harness-ui-pet-places places)))
      ;; By default in chats, on the board and under the session list, not in header lines.
      (should (equal '(chat board sessions) (eval (car (get 'harness-ui-pet-places 'standard-value)))))
      (dolist (hook '(harness-chat-top-functions harness-ui-tasks-corner-functions
                      harness-ui-sessions-footer-functions window-buffer-change-functions
                      window-size-change-functions text-scale-mode-hook))
        (should (wired hook)))
      (dolist (hook '(harness-chat-header-end-functions harness-ui-tasks-header-functions))
        (should-not (wired hook)))
      ;; Among the chat's top functions, not its panels.
      (should-not (wired 'harness-chat-panel-functions))
      (let ((places harness-ui-pet-places))
        (unwind-protect
            (progn
              (places 'chat-header 'board-header)
              (dolist (hook '(harness-chat-header-end-functions harness-ui-tasks-header-functions))
                (should (wired hook)))
              (dolist (hook '(harness-chat-top-functions harness-ui-tasks-corner-functions
                              harness-ui-sessions-footer-functions window-buffer-change-functions
                              window-size-change-functions text-scale-mode-hook))
                (should-not (wired hook)))
              (should (harness-ui-pet--chat-header))
              (should (harness-ui-pet--board-header))
              (should-not (harness-ui-pet--panel))
              (should-not (harness-ui-pet--sessions-footer))
              (should-not (harness-ui-pet--board-corner 80 '(20 40)))
              ;; Each place with a figure wires its own hook, and those it needs to fit:
              ;; chats and the list fit by their windows' size, the board by its own lines.
              (places 'chat)
              (should (equal '(t nil nil t t t)
                             (mapcar #'wired '(harness-chat-top-functions harness-ui-tasks-corner-functions
                                               harness-ui-sessions-footer-functions window-size-change-functions
                                               window-buffer-change-functions text-scale-mode-hook))))
              (places 'board)
              (should (equal '(nil t nil nil t t)
                             (mapcar #'wired '(harness-chat-top-functions harness-ui-tasks-corner-functions
                                               harness-ui-sessions-footer-functions window-size-change-functions
                                               window-buffer-change-functions text-scale-mode-hook))))
              (places 'sessions)
              (should (equal '(nil nil t t t t)
                             (mapcar #'wired '(harness-chat-top-functions harness-ui-tasks-corner-functions
                                               harness-ui-sessions-footer-functions window-size-change-functions
                                               window-buffer-change-functions text-scale-mode-hook))))
              (should-not (harness-ui-pet--panel))
              (should-not (harness-ui-pet--board-corner 80 '(20 40))))
          (customize-set-variable 'harness-ui-pet-places places)))
      (should (wired 'harness-chat-top-functions))
      (should (wired 'harness-ui-sessions-footer-functions))
      (should-not (harness-ui-pet--board-header))
      ;; Where an older version put it, among the chat's panels, a reload forgets it.
      (add-hook 'harness-chat-panel-functions #'harness-ui-pet--panel t)
      (should (wired 'harness-chat-panel-functions))
      (harness-ui-pet--wire)
      (should-not (wired 'harness-chat-panel-functions))
      (should (wired 'harness-chat-top-functions))
      ;; The module stopped, the pet leaves every place.
      (harness-ui-pet--shutdown)
      (dolist (hook '(harness-chat-header-end-functions harness-chat-top-functions harness-chat-panel-functions
                      harness-ui-tasks-header-functions harness-ui-tasks-corner-functions
                      harness-ui-sessions-footer-functions
                      window-buffer-change-functions window-size-change-functions text-scale-mode-hook))
        (should-not (wired hook)))
      (should-not (harness-ui-pet--sessions-footer))
      (should-not (harness-ui-pet--board-corner 80 '(20 40)))
      (should-not (harness-ui-pet--board-header)))))

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
        (should (harness-ui-pet-test--own-hooks 'harness-chat-top-functions))
        (should (harness-ui-pet-test--own-hooks 'harness-ui-tasks-corner-functions))
        (should (harness-ui-pet-test--own-hooks 'harness-ui-sessions-footer-functions))
        (with-current-buffer buf (harness-ui-pet-toggle-enabled))
        (harness-ui-pet-test--wait-text (regexp-quote (format "%s is asleep" name)))
        (should-not harness-pet-enabled)
        (should (eq :false (plist-get harness-ui-pet--current :enabled)))
        ;; Nowhere else, and nothing wired for it but the buffer's watch.
        (dolist (hook '(harness-chat-header-end-functions harness-chat-top-functions
                        harness-chat-panel-functions harness-ui-tasks-header-functions
                        harness-ui-tasks-corner-functions harness-ui-sessions-footer-functions
                        window-size-change-functions text-scale-mode-hook))
          (should-not (harness-ui-pet-test--own-hooks hook)))
        (let ((harness-ui-pet-places '(chat board sessions chat-header board-header)))
          (should-not (harness-ui-pet--chat-header))
          (should-not (harness-ui-pet--board-header))
          (should-not (harness-ui-pet--panel))
          (should-not (harness-ui-pet--sessions-footer))
          (should-not (harness-ui-pet--board-corner 80 '(20 40))))
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
        (should (harness-ui-pet-test--own-hooks 'harness-chat-top-functions))
        (should (harness-ui-pet-test--own-hooks 'harness-ui-sessions-footer-functions))
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

(ert-deftest harness-ui-pet-spin-lasts-two-turns ()
  "A spin on the card is a step of its turn a tick, for two turns; then it is over."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (should (= 2 harness-ui-pet--spin-turns))
  (should (= 24 harness-ui-pet-3d-count))
  (let ((ticks (* 2 harness-ui-pet-3d-count))
        (anim (list :kind 'spin :tick 0))
        (seen nil))
    (while anim
      (should (eq 'spin (plist-get anim :kind)))
      (push (plist-get anim :tick) seen)
      (setq anim (harness-ui-pet--next anim)))
    ;; Still a spin tick after tick, one more each time, and then nil.
    (should (equal (number-sequence 0 (1- ticks)) (nreverse seen)))
    (should (eq 'spin (plist-get (harness-ui-pet--next (list :kind 'spin :tick (- ticks 2))) :kind)))
    (should-not (harness-ui-pet--next (list :kind 'spin :tick (1- ticks))))))

(defun harness-ui-pet-test--card ()
  "The pet's card with its creature cut out of it: (CREATURE . REST).
CREATURE is the five lines of the creature as plain text, without the
two blanks before them nor the stats beside them.  REST is the rest of
the buffer's text, the space that aligns the stats left where the
creature was: cards with the same REST have all else in the same place."
  (with-current-buffer harness-ui-pet-test--buffer
    (save-excursion
      ;; The rows of the creature are those the five stats are beside.
      (goto-char (point-min))
      (search-forward "DEBUGGING")
      (forward-line 0)
      (let ((creature nil) (cuts nil))
        (dotimes (_ 5)
          (let* ((start (+ (point) 2))
                 (end (line-end-position))
                 (align start))
            (while (and (< align end)
                        (not (equal (get-text-property align 'display)
                                    `(space :align-to ,harness-ui-pet--stats-column))))
              (cl-incf align))
            (should (< align end))
            (push (buffer-substring-no-properties start align) creature)
            (push (cons start align) cuts)
            (forward-line 1)))
        ;; The last cut first, so the others stay where they were.
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (pcase-dolist (`(,start . ,end) cuts)
            (setq text (concat (substring text 0 (- start (point-min)))
                               (substring text (- end (point-min))))))
          (cons (nreverse creature) text))))))

(defun harness-ui-pet-test--card-slices ()
  "What each of the five lines of the creature on the card displays, top first.
\(POSITION DISPLAY) where a slice of a picture stands in for the text
from POSITION on, nil for a line that shows its text."
  (with-current-buffer harness-ui-pet-test--buffer
    (save-excursion
      (goto-char (point-min))
      (search-forward "DEBUGGING")
      (forward-line 0)
      (cl-loop repeat 5
               collect (let ((pos (point)) (end (line-end-position)) (found nil))
                         (while (and (< pos end) (not found))
                           (let ((display (get-text-property pos 'display)))
                             (when (eq 'slice (car-safe (car-safe display)))
                               (setq found (list pos display))))
                           (setq pos (or (next-single-property-change pos 'display nil end) end)))
                         (forward-line 1)
                         found)))))

(ert-deftest harness-ui-pet-spin-turns-the-card ()
  "s turns the creature on the pet's card: two turns, a step a tick, at rest after.
The card's text is the same all the while, the creature's lines and the
stats beside them in their places; what changes is the lines of the
creature, which show a band each of the picture of the step, as high as
a line of the creature on the card and as wide as the creature is in
any of its frames.  The timer ticks at the pace of the turn, `s' also
turns the figures, and none is left after."
  (harness-ui-pet-test-with
    (let* ((harness-pet-overrides '(:species capybara :eye "o" :hat crown :rarity rare :name "Fennel"))
           (buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (with-current-buffer buf
        (harness-ui-pet-test-with-3d
          (let* ((harness-ui-pet-animations t)
                 (view harness-ui-pet--view)
                 (sprite (car (harness-ui-pet--sprite view)))
                 (width (* (car harness-ui-pet-test--art-cell) (string-width (car sprite))))
                 (height (cdr harness-ui-pet-test--art-cell))
                 (count harness-ui-pet-3d-count)
                 ;; Drawn again as a graphical frame draws it: the stats' meters are images.
                 (at-rest (progn (harness-ui-pet--render) (harness-ui-pet-test--card))))
            ;; A crown on: five lines of creature, the first not blank.
            (should (= 5 (length sprite)))
            (should (string-search "^^^" (car (car at-rest))))
            (should (equal '(nil nil nil nil nil) (harness-ui-pet-test--card-slices)))
            (should-not harness-ui-pet--anim)
            ;; s starts it; each tick shows the next step of the turn, round and round.
            (harness-ui-pet-spin)
            (should (timerp harness-ui-pet--timer))
            (should (= harness-ui-pet-3d-tick (timer--repeat-delay harness-ui-pet--timer)))
            (dotimes (tick (* 2 count))
              (should (equal (list :kind 'spin :tick tick) harness-ui-pet--anim))
              ;; The text is as it was, the stats where they were...
              (should (equal at-rest (harness-ui-pet-test--card)))
              ;; ...and each line shows its band of the picture.
              (let ((image (harness-ui-pet-3d-frame "capybara" "crown" (mod tick count)
                                                    width (* height (length sprite)))))
                (should image)
                (cl-loop for found in (harness-ui-pet-test--card-slices)
                         for row from 0
                         do (should found)
                            (should (equal `((slice 0 ,(* row height) ,width ,height) ,image) (cadr found)))
                            (should (eq image (cadr (cadr found))))))
              (should (timerp harness-ui-pet--timer))
              (should (= harness-ui-pet-3d-tick (timer--repeat-delay harness-ui-pet--timer)))
              (harness-ui-pet--step))
            ;; After the two turns: no animation, no timer, the card as it was.
            (should-not harness-ui-pet--anim)
            (should-not harness-ui-pet--timer)
            (should (equal '(nil nil nil nil nil) (harness-ui-pet-test--card-slices)))
            (should (equal at-rest (harness-ui-pet-test--card)))
            (harness-ui-pet--still)))))))

(ert-deftest harness-ui-pet-spin-card-keeps-the-pace-of-what-plays ()
  "A frame of the spin shows every `harness-ui-pet-3d-tick', one of any other animation
every `harness-ui-pet--tick': the card's timer follows the animation that plays,
also when one follows another."
  (harness-ui-pet-test-with
    (let* ((harness-pet-overrides '(:species capybara :eye "o" :hat none :rarity rare :name "Fennel"))
           (buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (with-current-buffer buf
        (harness-ui-pet-test-with-3d
          (let ((harness-ui-pet-animations t))
            (should (< harness-ui-pet-3d-tick harness-ui-pet--tick))
            (harness-ui-pet--animate 'hearts)
            (should (= harness-ui-pet--tick (timer--repeat-delay harness-ui-pet--timer)))
            ;; A spin that replaces a fidget changes the pace, with a timer of its own.
            (let ((timer harness-ui-pet--timer))
              (harness-ui-pet--animate 'spin)
              (should-not (eq timer harness-ui-pet--timer))
              (should-not (memq timer timer-list))
              (should (= harness-ui-pet-3d-tick (timer--repeat-delay harness-ui-pet--timer))))
            ;; The same pace keeps the timer it has.
            (let ((timer harness-ui-pet--timer))
              (harness-ui-pet--animate 'spin)
              (should (eq timer harness-ui-pet--timer)))
            ;; Queued behind the sparkles, the spin starts at its own pace once they end,
            ;; and a fidget after it, at the usual one.
            (harness-ui-pet--animate 'sparkle)
            (harness-ui-pet-spin)
            (should (eq 'spin harness-ui-pet--queued))
            (should (= harness-ui-pet--tick (timer--repeat-delay harness-ui-pet--timer)))
            (while (eq 'sparkle (plist-get harness-ui-pet--anim :kind))
              (harness-ui-pet--step))
            (should (eq 'spin (plist-get harness-ui-pet--anim :kind)))
            (should (= harness-ui-pet-3d-tick (timer--repeat-delay harness-ui-pet--timer)))
            (harness-ui-pet--animate 'fidget)
            (should (= harness-ui-pet--tick (timer--repeat-delay harness-ui-pet--timer)))
            (harness-ui-pet--stop)
            (harness-ui-pet--still)))))))

(ert-deftest harness-ui-pet-spin-needs-a-pet-and-animations ()
  "s says why it cannot spin: no buffer, only an egg, the pet off, animations off."
  (harness-ui-pet-test-with
    ;; Nowhere to spin.
    (should-error (harness-ui-pet-spin) :type 'user-error)
    (let* ((harness-pet-overrides '(:species capybara :eye "o" :hat none :rarity rare :name "Fennel"))
           (buf (harness-ui-pet-test--open)))
      (with-current-buffer buf
        (let ((harness-ui-pet-animations t))
          (should-error (harness-ui-pet-spin) :type 'user-error)
          (should-not harness-ui-pet--anim)
          (should-not harness-ui-pet--timer)))
      (harness-ui-pet-test--hatch)
      (with-current-buffer buf
        ;; Hatched, but they are off: it says how to turn them on.
        (let ((harness-ui-pet-animations nil))
          (let ((err (should-error (harness-ui-pet-spin) :type 'user-error)))
            (should (string-match-p "M-x customize-variable harness-ui-pet-animations" (error-message-string err))))
          (should-not harness-ui-pet--anim)
          (should-not harness-ui-pet--timer)
          (should-not harness-ui-pet--queued))
        ;; The pet turned off sleeps.
        (let ((harness-ui-pet-animations t)
              (harness-ui-pet--view (plist-put (copy-sequence harness-ui-pet--view) :enabled :false)))
          (should-error (harness-ui-pet-spin) :type 'user-error)
          (should-not harness-ui-pet--anim))
        ;; And it spins when it may.
        (harness-ui-pet-test-with-3d
          (let ((harness-ui-pet-animations t))
            (harness-ui-pet-spin)
            (should (eq 'spin (plist-get harness-ui-pet--anim :kind)))
            (harness-ui-pet--stop)
            (should-not harness-ui-pet--anim)
            (should-not harness-ui-pet--timer)))))))

(ert-deftest harness-ui-pet-spin-says-why-it-cannot-turn ()
  "Where the pet cannot spin, s says why in the echo area and does nothing.
A batch Emacs has no graphical frame; one may have no SVG; a species may
have no model yet.  The spin queued for after the egg hatched follows the
same rule once it would start."
  (harness-ui-pet-test-with
    (let* ((harness-pet-overrides '(:species capybara :eye "o" :hat none :rarity rare :name "Fennel"))
           (buf (harness-ui-pet-test--open))
           (messages nil))
      (harness-ui-pet-test--hatch)
      (cl-flet ((nothing ()
                  (should-not harness-ui-pet--anim)
                  (should-not harness-ui-pet--timer)
                  (should-not harness-ui-pet--queued)
                  (should-not harness-ui-pet--beat)
                  (should-not harness-ui-pet--beat-timer)))
        (with-current-buffer buf
          (let ((harness-ui-pet-animations t))
            (cl-letf (((symbol-function 'message)
                       (lambda (fmt &rest args) (push (apply #'format fmt args) messages) nil)))
              ;; Not a graphical frame, as in a batch Emacs: and the pet's name says who.
              (should-not (harness-ui-pet--graphic-p))
              (should (eq 'frame (harness-ui-pet--spin-block "capybara")))
              (harness-ui-pet-spin)
              (should (equal '("Fennel spins only in a graphical frame") messages))
              (nothing)
              ;; A graphical frame, but Emacs shows no SVG images.
              (setq messages nil)
              (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                        ((symbol-function 'image-type-available-p) (lambda (&rest _) nil)))
                (should (eq 'svg (harness-ui-pet--spin-block "capybara")))
                (harness-ui-pet-spin))
              (should (equal '("Fennel spins only where Emacs shows SVG images") messages))
              (nothing)
              ;; Both, but nothing to turn: this species has no model.
              (setq messages nil)
              (harness-ui-pet-test-with-3d
                (should-not (harness-ui-pet--spin-block "capybara"))
                (should (eq 'model (harness-ui-pet--spin-block "gryphon")))
                (cl-letf (((symbol-function 'harness-ui-pet-3d-model) (lambda (_) nil)))
                  (harness-ui-pet-spin))
                (should (equal '("Fennel has no 3D model to spin yet") messages))
                (nothing)
                ;; It does when it can, and says nothing.
                (setq messages nil)
                (harness-ui-pet-spin)
                (should-not messages)
                (should (eq 'spin (plist-get harness-ui-pet--anim :kind)))
                (harness-ui-pet--stop)
                (harness-ui-pet--still)
                (nothing))
              ;; The spin queued behind the egg's sparkles, and the frame turned out
              ;; to be no graphical one by the time it would start: it says so, and does nothing.
              (setq messages nil)
              (harness-ui-pet-test-with-3d
                (harness-ui-pet--animate 'sparkle)
                (harness-ui-pet-spin)
                (should (eq 'spin harness-ui-pet--queued))
                (should-not messages))
              (while harness-ui-pet--anim
                (harness-ui-pet--step))
              (should (equal '("Fennel spins only in a graphical frame") messages))
              (nothing))))))))

(ert-deftest harness-ui-pet-spin-waits-for-the-egg ()
  "While the egg wobbles, cracks or sparkles, s queues the spin for after it.
As the pet's first words queue a fidget."
  (harness-ui-pet-test-with
    (let* ((harness-pet-overrides '(:species capybara :eye "o" :hat none :rarity rare :name "Fennel"))
           (buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (with-current-buffer buf
        (harness-ui-pet-test-with-3d
          (let ((harness-ui-pet-animations t))
            (dolist (kind '(egg crack sparkle))
              (harness-ui-pet--animate kind)
              (harness-ui-pet-spin)
              (should (eq kind (plist-get harness-ui-pet--anim :kind)))
              (should (eq 'spin harness-ui-pet--queued))
              (harness-ui-pet--stop)
              (should-not harness-ui-pet--queued))
            ;; The sparkles over, it turns.
            (harness-ui-pet--animate 'sparkle)
            (harness-ui-pet-spin)
            (let ((kinds nil))
              (while harness-ui-pet--anim
                (push (plist-get harness-ui-pet--anim :kind) kinds)
                (harness-ui-pet--step))
              (should (equal '(sparkle spin) (delete-dups (nreverse kinds)))))
            (should-not harness-ui-pet--queued)
            (should-not harness-ui-pet--timer)))))))


;;;; Its figure, moving

(defun harness-ui-pet-test--runs (buffer)
  "The lines of the creature in BUFFER's figure, top first: (START END ROW) each.
ROW is the number the characters from START to END are marked with, or
`face' for the pet's face on one line."
  (with-current-buffer buffer
    (let ((pos (point-min)) (runs nil))
      (while (setq pos (text-property-not-all pos (point-max) 'harness-ui-pet-row nil))
        (let ((end (or (next-single-property-change pos 'harness-ui-pet-row nil (point-max))
                       (point-max))))
          (push (list pos end (get-text-property pos 'harness-ui-pet-row)) runs)
          (setq pos end)))
      (nreverse runs))))

(defun harness-ui-pet-test--displays (buffer)
  "What each run of the figure in BUFFER displays instead of its text, or nil."
  (with-current-buffer buffer
    (mapcar (lambda (run) (get-text-property (car run) 'display))
            (harness-ui-pet-test--runs buffer))))

(defun harness-ui-pet-test--frame-texts (buffer frame)
  "What the runs of BUFFER's figure show in FRAME: the last columns of its rows."
  (let ((rows (mapcar #'substring-no-properties
                      (car (harness-ui-pet--sprite harness-ui-pet--current frame)))))
    (mapcar (lambda (run)
              (let ((row (nth (nth 2 run) rows)))
                (substring row (- (length row) (- (nth 1 run) (nth 0 run))))))
            (harness-ui-pet-test--runs buffer))))

(defun harness-ui-pet-test--check-display (buffer run text)
  "Check the RUN of BUFFER's figure displays TEXT, a string in its place.
One string for all of the run, as wide as it, with the properties of the
text it replaces: its colours, its hovering and its click."
  (pcase-let ((`(,start ,end ,_row) run))
    (with-current-buffer buffer
      (let ((display (get-text-property start 'display)))
        (should (stringp display))
        (should (equal text (substring-no-properties display)))
        (should (eq display (get-text-property (1- end) 'display)))
        (should (= end (or (next-single-property-change start 'display nil (point-max)) (point-max))))
        (should (= (string-width (buffer-substring-no-properties start end)) (string-width display)))
        (should (get-text-property 0 'face display))
        (cl-loop for (prop value) on (text-properties-at start) by #'cddr
                 unless (eq prop 'display)
                 do (should (equal value (get-text-property 0 prop display))))))))

(defun harness-ui-pet-test--picture (view step)
  "The picture of step STEP of VIEW's turn over its figure, where the tests spin.
\(IMAGE WIDTH): the 3D frame, and the pixels it is wide, the columns of
the creature's figure in cells of `harness-ui-pet-test--cell'.  The
picture is as high as the creature has rows."
  (let* ((sprite (car (harness-ui-pet--sprite view)))
         (width (* (car harness-ui-pet-test--cell) (string-width (car sprite)))))
    (list (harness-ui-pet-3d-frame (plist-get view :species) (plist-get view :hat) step
                                   width (* (cdr harness-ui-pet-test--cell) (length sprite)))
          width)))

(defun harness-ui-pet-test--check-slices (buffer step)
  "Check BUFFER's figure shows step STEP of the creature's 3D turn.
Each run of it displays its own band of the one picture, the whole band:
a slice as high as a row and as wide as the figure.  The row a line to
the speech bubble reaches into has a run shorter than the figure; its
band stands on the last columns of that line too (the text marked
`harness-ui-pet-joint'), so that no pixel of the picture is hidden under
the line's glyphs, and begins no earlier."
  (pcase-let* ((`(,image ,width) (harness-ui-pet-test--picture harness-ui-pet--current step))
               (`(,cw . ,ch) harness-ui-pet-test--cell))
    (should image)
    (with-current-buffer buffer
      (dolist (run (harness-ui-pet-test--runs buffer))
        (pcase-let* ((`(,start ,end ,row) run)
                     (from (- start (- (/ width cw) (- end start))))
                     (display (get-text-property from 'display)))
          (should (integerp row))
          (should (equal `((slice 0 ,(* ch row) ,width ,ch) ,image) display))
          ;; The one picture the renderer made, for every band of it.
          (should (eq image (cadr display)))
          ;; One stretch of it, from the band's first column to the run's last, and no more.
          (should (eq display (get-text-property start 'display)))
          (should (eq display (get-text-property (1- end) 'display)))
          (should (= end (or (next-single-property-change from 'display nil (point-max)) (point-max))))
          ;; (The character before it may display a space to align the line; no slice.)
          (should (or (= from (point-min))
                      (not (eq 'slice (car-safe (car-safe (get-text-property (1- from) 'display)))))))
          ;; The columns taken from the line are those it marks for it, and they are all of what
          ;; the creature's row lacks.
          (should (cl-loop for pos from from below start always (get-text-property pos 'harness-ui-pet-joint))))))))

(defun harness-ui-pet-test--check-frame (buffer frame)
  "Check BUFFER's figure shows FRAME of the creature.
At rest, 0, no line of it displays anything else than itself; in another
frame each displays the last columns of its row of that frame; in a step
of the 3D turn, (spin . K), its band of the picture."
  (let ((runs (harness-ui-pet-test--runs buffer)))
    (should runs)
    (cond ((eql frame 0)
           (should (cl-every #'null (harness-ui-pet-test--displays buffer))))
          ((eq 'spin (car-safe frame))
           (harness-ui-pet-test--check-slices buffer (cdr frame)))
          (t (cl-mapc (lambda (run text) (harness-ui-pet-test--check-display buffer run text))
                      runs (harness-ui-pet-test--frame-texts buffer frame))))))

(defun harness-ui-pet-test--state (buffer)
  "What a beat leaves be in BUFFER: its text, the tick of its characters, its
modified flag, its undo list and its point."
  (with-current-buffer buffer
    (list (buffer-substring-no-properties (point-min) (point-max))
          (buffer-chars-modified-tick) (buffer-modified-p) buffer-undo-list (point))))

(defun harness-ui-pet-test--timers ()
  "The timers of the figures' beats that are scheduled now."
  (cl-remove-if-not (lambda (timer)
                      (memq (timer--function timer) '(harness-ui-pet--beat-step harness-ui-pet--idle-beat)))
                    (append timer-list timer-idle-list)))

(defmacro harness-ui-pet-test-with-chat-figure (buffer &rest body)
  "Run BODY with BUFFER a chat on screen, with the pet's figure above its box.
The pet is a rare capybara called Fennel, hatched; the session is SID."
  (declare (indent 1))
  `(harness-ui-pet-test-with
     (harness-test-load-module 'ui-chat)
     (let* ((harness-pet-overrides '(:species capybara :eye "o" :hat none :rarity rare :name "Fennel"))
            (sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted" :name "Parser work") :id))
            (,buffer (harness-chat-buffer sid)))
       (unwind-protect
           (progn
             (harness-test-wait (lambda () (with-current-buffer ,buffer
                                             (and (not harness-chat--loading) harness-compose-end)))
                                5 "the chat to load")
             (switch-to-buffer ,buffer)
             (harness-ui-pet-test--know-the-pet)
             (harness-ui-pet-test--hatch-elsewhere)
             (harness-test-wait (lambda () (harness-ui-pet-test--figure ,buffer)) 5 "the pet above the compose box")
             ,@body)
         (harness-ui-pet--still)
         (kill-buffer ,buffer)))))

(defun harness-ui-pet-test--pick (times)
  "Pick TIMES beats for an idle moment, as an alist of how often each came."
  (let ((counts (list (cons 'blink 0) (cons 'twice 0) (cons 'wiggle 0) (cons 'spin 0))))
    (dotimes (_ times)
      (cl-incf (alist-get (harness-ui-pet--pick-beat) counts)))
    counts))

(defmacro harness-ui-pet-test-with-figure-on-screen (view &rest body)
  "Run BODY with a figure of VIEW's pet on screen in the current buffer's window.
The window is 80 columns by 40 lines, as far as the figure knows; the
buffer has the figure and a compose box, and is shown in the selected window."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((harness-ui-pet--current ,view))
       (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 40 1))))
         (insert (harness-ui-pet--draw (harness-ui-pet--spec nil)) "compose box> ")))
     (save-window-excursion
       (switch-to-buffer (current-buffer))
       (should (equal (list (current-buffer)) (harness-ui-pet--figure-buffers)))
       ,@body)))

(ert-deftest harness-ui-pet-beats-end-at-rest ()
  "Each beat is a few frames and ends at rest; an idle moment picks by weight.
A blink or two where no figure is whole, a gap of 6 to 14 seconds."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (should (equal '(blink 0) (harness-ui-pet--beat-frames 'blink)))
  (should (equal '(blink 0 0 blink 0) (harness-ui-pet--beat-frames 'twice)))
  (should (equal '(1 0 1 0) (harness-ui-pet--beat-frames 'wiggle)))
  (should (equal (append harness-ui-pet--fidget '(0)) (harness-ui-pet--beat-frames 'fidget)))
  ;; The spin is one turn of the 3D model, from its first step to its last, then at rest.
  (should (equal (append (cl-loop for k below harness-ui-pet-3d-count collect (cons 'spin k)) '(0))
                 (harness-ui-pet--beat-frames 'spin)))
  (should (equal '(spin . 0) (car (harness-ui-pet--beat-frames 'spin))))
  (should (equal `(spin . ,(1- harness-ui-pet-3d-count)) (car (last (harness-ui-pet--beat-frames 'spin) 2))))
  (should-not (harness-ui-pet--beat-frames 'bogus))
  (dolist (kind '(blink twice wiggle fidget spin))
    (let ((frames (harness-ui-pet--beat-frames kind)))
      (should (eql 0 (car (last frames))))
      (should (< (length frames) (if (eq kind 'spin) (+ 2 harness-ui-pet-3d-count) 16)))))
  ;; Each beat shows at its own pace: the turn at the 3D tick, the others at the usual one.
  (dolist (kind '(blink twice wiggle fidget))
    (should (= harness-ui-pet--tick (harness-ui-pet--pace kind))))
  (should (= harness-ui-pet-3d-tick (harness-ui-pet--pace 'spin)))
  ;; Every idle beat is one there are frames for; the weights are those asked for: the
  ;; spin is rare, about one in 47 idle moments, so about once in eight minutes.
  (should (equal '(blink twice wiggle spin) (mapcar #'car harness-ui-pet--idle-beats)))
  (should (equal '(55 12 25 2) (mapcar #'cdr harness-ui-pet--idle-beats)))
  (should (equal '(6 . 14) harness-ui-pet--idle-gap))
  (let ((mean-wait (/ (+ (car harness-ui-pet--idle-gap) (cdr harness-ui-pet--idle-gap)) 2.0))
        (share (/ 2.0 (apply #'+ (mapcar #'cdr harness-ui-pet--idle-beats)))))
    (should (<= (* 7 60) (/ mean-wait share) (* 9 60))))
  (dotimes (_ 200)
    (should (<= 6 (harness-ui-pet--gap) 14)))
  (unwind-protect
      (progn
        ;; No figure on screen: only a blink or two would show on a face, which is all there is.
        (random "idle beats")
        (let ((counts (harness-ui-pet-test--pick 200)))
          (should (zerop (alist-get 'wiggle counts)))
          (should (zerop (alist-get 'spin counts)))
          (should (> (alist-get 'blink counts) (alist-get 'twice counts) 0)))
        ;; A whole figure on screen, in a batch Emacs, which shows no images: all of them
        ;; by weight but the spin, which is a 3D turn and shows in no terminal.
        (let ((view (list :species "capybara" :eye "o" :hat "none" :rarity "rare" :name "Fennel")))
          (harness-ui-pet-test-with-figure-on-screen view
            (should-not (harness-ui-pet--graphic-p))
            (should-not (harness-ui-pet--spinner-p (current-buffer)))
            (random "idle beats")
            (let ((counts (harness-ui-pet-test--pick 1000)))
              (should (cl-every #'> (list (alist-get 'blink counts) (alist-get 'twice counts)
                                          (alist-get 'wiggle counts))
                                '(0 0 0)))
              (should (> (alist-get 'blink counts) (alist-get 'wiggle counts) (alist-get 'twice counts)))
              (should (zerop (alist-get 'spin counts))))
            ;; Where it could show them it is, rarely: far less often than any other beat.
            (harness-ui-pet-test-with-3d
              (should (harness-ui-pet--spinner-p (current-buffer)))
              (random "idle beats")
              (let ((counts (harness-ui-pet-test--pick 1880)))
                (should (cl-every #'> (mapcar #'cdr counts) '(0 0 0 0)))
                (should (> (alist-get 'blink counts) (alist-get 'wiggle counts)
                           (alist-get 'twice counts) (alist-get 'spin counts)))
                ;; About 2 in 94 of them: 40 of 1880.
                (should (<= 15 (alist-get 'spin counts) 70)))
              ;; Not for a species it has no model of, however well the frame shows images.
              (cl-letf (((symbol-function 'harness-ui-pet-3d-model) (lambda (_) nil)))
                (should-not (harness-ui-pet--spinner-p (current-buffer)))
                (random "idle beats")
                (should (zerop (alist-get 'spin (harness-ui-pet-test--pick 500)))))))))
    ;; The seed was for this test only.
    (random t)))

(ert-deftest harness-ui-pet-frames-swap-what-lines-display ()
  "A frame of the figure changes what its lines display, and nothing else.
For every species, in a hat or none, with a bubble beside it or not,
each line of the creature displays the last columns of its row of the
frame -- at rest, the 2 others and the eyes shut -- as wide as the line,
the rest frame displays nothing, and the buffer's text, its modified
state and its undo list stay as they were.  The face on one line shuts
its eyes for a blink, and does not move for another frame, nor turn.  A
buffer off screen stays as it is, until it is put back at rest."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (let ((said (list :text "Tokenizer? Bold." :ts (float-time)))
        (harness-ui-pet--moved nil)
        (shorter nil))
    (dolist (species harness-pet-species)
      (dolist (hat '(none crown))
        (let ((view (list :species (symbol-name species) :eye "o" :hat (symbol-name hat)
                          :rarity "rare" :name "Fennel")))
          (dolist (saying (list nil said))
            (with-temp-buffer
              (let ((harness-ui-pet--current view))
                (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 40 1))))
                  (insert "transcript\n" (harness-ui-pet--draw (harness-ui-pet--spec saying)) "compose box> ")))
              (save-window-excursion
                (switch-to-buffer (current-buffer))
                (let ((harness-ui-pet--current view)
                      (buffer (current-buffer))
                      (state (harness-ui-pet-test--state (current-buffer)))
                      (undo buffer-undo-list))
                  (should (= (length (car (harness-ui-pet--sprite view)))
                             (length (harness-ui-pet-test--runs buffer))))
                  ;; A line to the bubble takes the creature's first blanks: the last columns show.
                  (when (cl-some (lambda (run) (< (- (nth 1 run) (nth 0 run)) (harness-ui-pet--figure-width view)))
                                 (harness-ui-pet-test--runs buffer))
                    (setq shorter t))
                  (dolist (frame (harness-ui-pet-test--frames))
                    (harness-ui-pet--show-frame frame)
                    (harness-ui-pet-test--check-frame buffer frame)
                    (should (equal state (harness-ui-pet-test--state buffer)))
                    (should (eq undo buffer-undo-list))
                    (should (equal (unless (eql frame 0) (list buffer)) harness-ui-pet--moved))))))))))
    (should shorter)
    ;; The last of them died in a frame other than the rest: the next to show one forgets it.
    (should (cl-notevery #'buffer-live-p harness-ui-pet--moved))
    (harness-ui-pet--show-frame 0)
    (should-not harness-ui-pet--moved)
    ;; The face on one line: eyes shut for a blink; the others do not move it.
    (let ((view (list :species "owl" :eye "o" :hat "none" :rarity "rare" :name "Fennel")))
      (with-temp-buffer
        (let ((harness-ui-pet--current view))
          (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 30 40 1))))
            (insert "transcript\n" (harness-ui-pet--draw (harness-ui-pet--spec nil)) "compose box> ")))
        (should (eq 'face (car (nth 2 harness-ui-pet--panel-shown))))
        (save-window-excursion
          (switch-to-buffer (current-buffer))
          (let* ((buffer (current-buffer))
                 (run (car (harness-ui-pet-test--runs buffer)))
                 (state (harness-ui-pet-test--state buffer)))
            (should (equal 1 (length (harness-ui-pet-test--runs buffer))))
            (should (eq 'face (nth 2 run)))
            ;; Not even a step of the 3D turn, where one could be shown.
            (harness-ui-pet-test-with-3d
              (dolist (frame (cons '(spin . 3) '(1 2)))
                (harness-ui-pet--show-frame frame)
                (should (cl-every #'null (harness-ui-pet-test--displays buffer)))
                (should-not harness-ui-pet--moved)))
            (harness-ui-pet--show-frame 'blink)
            (should (equal (list buffer) harness-ui-pet--moved))
            (harness-ui-pet-test--check-display buffer run (harness-ui-pet-face "owl" "o" t))
            (should-not (string-search "o" (substring-no-properties
                                            (get-text-property (nth 0 run) 'display))))
            (should (equal state (harness-ui-pet-test--state buffer)))
            ;; It only blinks: another frame opens the eyes too, and so does the rest frame.
            (harness-ui-pet--show-frame 1)
            (should (cl-every #'null (harness-ui-pet-test--displays buffer)))
            (should (equal (list buffer) harness-ui-pet--moved))
            (harness-ui-pet--show-frame 'blink)
            (harness-ui-pet--show-frame 0)
            (should (cl-every #'null (harness-ui-pet-test--displays buffer)))
            (should-not harness-ui-pet--moved)))))
    ;; Several figures at once -- one whole, one a face -- move together, each as it can.
    (let ((view (list :species "cat" :eye "o" :hat "none" :rarity "rare" :name "Fennel")))
      (with-temp-buffer
        (let ((whole (current-buffer)))
          (with-temp-buffer
            (let ((face (current-buffer)))
              (let ((harness-ui-pet--current view))
                (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 40 1))))
                  (with-current-buffer whole
                    (insert (harness-ui-pet--draw (harness-ui-pet--spec nil)) "compose box> ")))
                (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 30 40 1))))
                  (with-current-buffer face
                    (insert (harness-ui-pet--draw (harness-ui-pet--spec nil)) "compose box> "))))
              (save-window-excursion
                (delete-other-windows)
                (switch-to-buffer whole)
                (set-window-buffer (split-window) face)
                (let ((harness-ui-pet--current view))
                  (should (equal (list whole face) (sort (harness-ui-pet--figure-buffers)
                                                         (lambda (a _) (eq a whole)))))
                  (harness-ui-pet--show-frame 'blink)
                  (harness-ui-pet-test--check-frame whole 'blink)
                  (harness-ui-pet-test--check-display face (car (harness-ui-pet-test--runs face))
                                                      (harness-ui-pet-face "cat" "o" t))
                  (should (= 2 (length harness-ui-pet--moved)))
                  (harness-ui-pet--show-frame 1)
                  (harness-ui-pet-test--check-frame whole 1)
                  (should (cl-every #'null (harness-ui-pet-test--displays face)))
                  (harness-ui-pet--show-frame 0)
                  (harness-ui-pet-test--check-frame whole 0)
                  (should (cl-every #'null (harness-ui-pet-test--displays face)))
                  (should-not harness-ui-pet--moved))))))))
    ;; Off screen it is not touched, until the rest frame puts it back, on screen or not.
    (let ((view (list :species "duck" :eye "o" :hat "none" :rarity "rare" :name "Fennel"))
          (other (get-buffer-create " *harness-ui-pet-test other*")))
      (unwind-protect
          (with-temp-buffer
            (let ((harness-ui-pet--current view) (buffer (current-buffer)))
              (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 40 1))))
                (insert (harness-ui-pet--draw (harness-ui-pet--spec nil))))
              (save-window-excursion
                (switch-to-buffer buffer)
                (harness-ui-pet--show-frame 1)
                (harness-ui-pet-test--check-frame buffer 1)
                (switch-to-buffer other)
                (should-not (harness-ui-pet--figure-buffers))
                (harness-ui-pet--show-frame 2)
                (harness-ui-pet-test--check-frame buffer 1)
                (should (equal (list buffer) harness-ui-pet--moved))
                (harness-ui-pet--show-frame 0)
                (harness-ui-pet-test--check-frame buffer 0)
                (should-not harness-ui-pet--moved))))
        (kill-buffer other)))))

(ert-deftest harness-ui-pet-spin-slices-a-picture-over-the-figure ()
  "A step of the spin shows one picture sliced over the creature's lines.
Stood in for a graphical frame, for every species that has a model and
in a hat or none, with a bubble beside it or not: each run of the figure
displays its band of the picture of the step -- as high as a row, as wide
as the figure, which reaches onto the last columns of the line to the
bubble when that made the run shorter than the figure -- and the picture is the
renderer's frame of that species and hat, as wide as the figure and as
high as it has rows.  The rest frame removes every slice; the buffer's
text, its modified state and its undo list never change.  A species
without a model stays at rest."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (let ((said (list :text "Tokenizer? Bold." :ts (float-time)))
        (harness-ui-pet--moved nil)
        (turned 0))
    (harness-ui-pet-test-with-3d
      (dolist (species harness-pet-species)
        (dolist (hat '(none crown))
          (let ((view (list :species (symbol-name species) :eye "o" :hat (symbol-name hat)
                            :rarity "rare" :name "Fennel")))
            (dolist (saying (list nil said))
              (with-temp-buffer
                (let ((harness-ui-pet--current view))
                  (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 40 1))))
                    (insert "transcript\n" (harness-ui-pet--draw (harness-ui-pet--spec saying)) "compose box> ")))
                (save-window-excursion
                  (switch-to-buffer (current-buffer))
                  (let ((harness-ui-pet--current view)
                        (buffer (current-buffer))
                        (state (harness-ui-pet-test--state (current-buffer)))
                        (undo buffer-undo-list))
                    (ert-info ((format "%s in a %s hat, saying %S" species hat (plist-get saying :text)))
                      (dolist (step '(0 12))
                        (harness-ui-pet--show-frame (cons 'spin step))
                        (if (harness-ui-pet-3d-model species)
                            (progn
                              (harness-ui-pet-test--check-frame buffer (cons 'spin step))
                              (should (equal (list buffer) harness-ui-pet--moved))
                              (cl-incf turned))
                          ;; No model: nothing to show, the creature as it is.
                          (should (cl-every #'null (harness-ui-pet-test--displays buffer)))
                          (should-not harness-ui-pet--moved))
                        (should (equal state (harness-ui-pet-test--state buffer)))
                        (should (eq undo buffer-undo-list))
                        ;; Back at rest, nothing is left over.
                        (harness-ui-pet--show-frame 0)
                        (should (cl-every #'null (harness-ui-pet-test--displays buffer)))
                        (should-not harness-ui-pet--moved)
                        (should (equal state (harness-ui-pet-test--state buffer)))))))))))))
    ;; Models for some at least, or this checked nothing.
    (should (> turned 0))))

(ert-deftest harness-ui-pet-spin-slice-cuts-a-band ()
  "A slice is a row's band of the picture, the right-most part of it when shorter.
The picture is the pixels of the creature's whole area; row N is the band
N rows down, as high as a row; a run of fewer columns than the figure
shows the last pixels of its band."
  (require 'harness-ui-pet)
  (let ((picture (list 'image 100 10 20)))
    (should (equal '((slice 0 0 100 20) image) (harness-ui-pet--slice picture 0)))
    (should (equal '((slice 0 40 100 20) image) (harness-ui-pet--slice picture 2)))
    (should (equal '((slice 0 40 100 20) image) (harness-ui-pet--slice picture 2 10)))
    (should (equal '((slice 60 40 40 20) image) (harness-ui-pet--slice picture 2 4)))
    (should (equal '((slice 90 60 10 20) image) (harness-ui-pet--slice picture 3 1)))
    ;; Never more than the figure is wide.
    (should (equal '((slice 0 20 100 20) image) (harness-ui-pet--slice picture 1 25)))))

(ert-deftest harness-ui-pet-cell-is-a-column-and-a-row-of-the-font ()
  "The cell the spin's picture is cut into is a column and a row of the figure's font.
Measured as a window draws the faces: the width of a character and the
height of a line of it, at least a pixel each; the string it is
measured by has no size when it is empty.  In a batch Emacs a pixel is a
column and a line."
  (require 'harness-ui-pet)
  (with-temp-buffer
    (should (equal '(0 . 0) (harness-ui-pet--text-size "")))
    (let ((size (harness-ui-pet--text-size "abc")))
      (should (= 3 (car size)))
      (should (= (car size) (harness-ui-pet--pixels "abc"))))
    (let ((cell (harness-ui-pet--cell)))
      (should (and (integerp (car cell)) (>= (car cell) 1)))
      (should (and (integerp (cdr cell)) (>= (cdr cell) 1)))
      (should (= (car cell) (harness-ui-pet--figure-char)))
      (should (equal cell (harness-ui-pet--cell nil harness-ui-pet--figure-faces))))
    ;; The card's creature is drawn in the art face: its own cell.
    (should (consp (harness-ui-pet--cell nil 'harness-pet-art-face)))))

(ert-deftest harness-ui-pet-spin-slice-of-a-shorter-run ()
  "The picture takes the columns of the line to the bubble that reach into a row.
A creature whose eyes sit further left in its other frames than at rest,
so the line to its bubble takes a column of the row of its eyes: that
run is a column shorter than the others.  A picture shows the whole band
of its row all the same, from the line's last column on, so that no
pixel of the model is hidden under the line's glyphs; any other frame of
the art, or rest, gives the column back to the line."
  (require 'harness-ui-pet)
  (let ((harness-ui-pet--sprites
         (list '(capybara ("" "  {E}" "(   )" "") ("" " {E}" "(   )" "") ("" "   {E}" "(   )" ""))))
        (harness-ui-pet--sprite-cache (make-hash-table :test 'equal))
        (view (list :species "capybara" :eye "o" :hat "none" :rarity "rare" :name "Fennel"))
        (said (list :text "Tokenizer? Bold." :ts (float-time))))
    (harness-ui-pet-test-with-3d
      (with-temp-buffer
        (let ((harness-ui-pet--current view))
          (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 40 1))))
            (insert (harness-ui-pet--draw (harness-ui-pet--spec said)) "compose box> ")))
        (save-window-excursion
          (switch-to-buffer (current-buffer))
          (let ((harness-ui-pet--current view)
                (buffer (current-buffer)))
            (should (= 5 (harness-ui-pet--figure-width view)))
            ;; Two rows: the eyes', a column short, and the body's, all of it.
            (should (equal '(4 5) (mapcar (lambda (run) (- (nth 1 run) (nth 0 run)))
                                          (harness-ui-pet-test--runs buffer))))
            (let ((eyes (car (nth 0 (harness-ui-pet-test--runs buffer)))))
              ;; The column before the run is the line's, marked as such, with nothing displayed.
              (should (get-text-property (1- eyes) 'harness-ui-pet-joint))
              (should-not (get-text-property eyes 'harness-ui-pet-joint))
              (harness-ui-pet--show-frame '(spin . 5))
              (let ((image (car (harness-ui-pet-test--picture view 5))))
                (should image)
                ;; Both bands whole, 50 pixels of 10, the first one beginning on the line's column.
                (should (equal `(((slice 0 0 50 20) ,image) ((slice 0 20 50 20) ,image))
                               (harness-ui-pet-test--displays buffer)))
                (should (equal `((slice 0 0 50 20) ,image) (get-text-property (1- eyes) 'display)))
                (should-not (eq 'slice (car-safe (car-safe (get-text-property (- eyes 2) 'display))))))
              (harness-ui-pet-test--check-frame buffer '(spin . 5))
              ;; Another frame of the art leaves the line's column to the line.
              (harness-ui-pet--show-frame 1)
              (should-not (get-text-property (1- eyes) 'display))
              (should (stringp (get-text-property eyes 'display)))
              (harness-ui-pet-test--check-frame buffer 1)
              ;; Back to the picture, and the column is its again; then at rest nothing is left.
              (harness-ui-pet--show-frame '(spin . 6))
              (should (get-text-property (1- eyes) 'display))
              (harness-ui-pet--show-frame 0)
              (should-not (get-text-property (1- eyes) 'display))
              (should (cl-every #'null (harness-ui-pet-test--displays buffer))))))))))

(ert-deftest harness-ui-pet-spin-reach-takes-only-the-lines-columns ()
  "A picture reaches to the left only over the columns the line to the bubble marked.
All of what a run lacks to be as wide as the figure, or none of it: a
column that is not the line's, or the start of the buffer, stops it."
  (require 'harness-ui-pet)
  (with-temp-buffer
    ;; Positions 1 2 are text, 3 4 the line's two columns, 5 to 8 the run.
    (insert "ab" (propertize "--" 'harness-ui-pet-joint t) "cdef")
    ;; A run as wide as the figure, or wider: where it starts.
    (should (= 5 (harness-ui-pet--reach 5 9 4)))
    (should (= 5 (harness-ui-pet--reach 5 9 2)))
    ;; A column or two short: those of the line.
    (should (= 4 (harness-ui-pet--reach 5 9 5)))
    (should (= 3 (harness-ui-pet--reach 5 9 6)))
    ;; Three short would take text that is not the line's: none, not part of it.
    (should (= 5 (harness-ui-pet--reach 5 9 7)))
    (should (= 5 (harness-ui-pet--reach 5 9 40)))
    ;; And a run the line does not stand before, whatever it lacks.
    (should (= 7 (harness-ui-pet--reach 7 9 3)))))

(ert-deftest harness-ui-pet-spin-needs-a-frame-that-shows-it ()
  "A buffer that cannot show the turn shows the creature at rest for its steps.
Not a graphical frame that shows SVG images, or a species with no model:
every slice goes, and nothing counts as moved; a frame that can show it
brings them back."
  (let ((view (list :species "capybara" :eye "o" :hat "none" :rarity "rare" :name "Fennel"))
        (harness-ui-pet--moved nil))
    (with-temp-buffer
      (let ((harness-ui-pet--current view))
        (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 40 1))))
          (insert (harness-ui-pet--draw (harness-ui-pet--spec nil)) "compose box> ")))
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (let ((harness-ui-pet--current view)
              (buffer (current-buffer)))
          ;; A batch Emacs is no graphical frame.
          (should-not (harness-ui-pet--graphic-p))
          (harness-ui-pet--show-frame '(spin . 4))
          (should (cl-every #'null (harness-ui-pet-test--displays buffer)))
          (should-not harness-ui-pet--moved)
          (harness-ui-pet-test-with-3d
            (harness-ui-pet--show-frame '(spin . 4))
            (harness-ui-pet-test--check-frame buffer '(spin . 4))
            (should (equal (list buffer) harness-ui-pet--moved))
            ;; The frame goes away, or the model: the next step finds nothing to show, and
            ;; the slices of the one before are not left behind.
            (cl-letf (((symbol-function 'harness-ui-pet--graphic-p) (lambda () nil)))
              (harness-ui-pet--show-frame '(spin . 5))
              (should (cl-every #'null (harness-ui-pet-test--displays buffer))))
            (harness-ui-pet--show-frame '(spin . 6))
            (harness-ui-pet-test--check-frame buffer '(spin . 6))
            (cl-letf (((symbol-function 'harness-ui-pet-3d-model) (lambda (_) nil)))
              (harness-ui-pet--show-frame '(spin . 7))
              (should (cl-every #'null (harness-ui-pet-test--displays buffer))))
            ;; Another frame of the art replaces a slice, which a string does not take for its own.
            (harness-ui-pet--show-frame '(spin . 8))
            (harness-ui-pet--show-frame 1)
            (harness-ui-pet-test--check-frame buffer 1)
            (harness-ui-pet--show-frame 0)
            (should (cl-every #'null (harness-ui-pet-test--displays buffer)))
            (should-not harness-ui-pet--moved)))))))

(ert-deftest harness-ui-pet-figure-beats-in-a-chat ()
  "The figure by a chat's compose box moves in beats, one frame a tick.
Each frame swaps what the creature's lines display and edits nothing:
the text of the chat, its modified state and its point are as they
were.  The beat ends at rest, and the next awaits a timer.  Nothing is
set while no chat is on screen or animations are off, in a window too
short for the whole creature a blink shuts the eyes of its face, and a
spin turns through every frame of it."
  (harness-ui-pet-test-with-chat-figure buf
    (let ((other (get-buffer-create "*harness-ui-pet-test other*")))
      (unwind-protect
          (let ((harness-ui-pet-animations t))
            ;; Nothing waits for a beat until the figure may move.
            (should (equal (list buf) (harness-ui-pet--figure-buffers)))
            (should (harness-ui-pet--animating-p))
            (let ((harness-ui-pet--live nil)) (should-not (harness-ui-pet--animating-p)))
            (let ((harness-ui-pet-animations nil)) (should-not (harness-ui-pet--animating-p)))
            (should-not harness-ui-pet--idle-timer)
            (harness-ui-pet--arm)
            (should (timerp harness-ui-pet--idle-timer))
            (should-not harness-ui-pet--beat-timer)
            (let ((wait (float-time (time-subtract (timer--time harness-ui-pet--idle-timer) nil))))
              (should (<= 5.9 wait 14.1)))
            (let ((timer harness-ui-pet--idle-timer))
              (harness-ui-pet--arm)
              (should (eq timer harness-ui-pet--idle-timer)))
            ;; A wiggle: the idle wait gives way, and the first frame shows on the first tick.
            (should (eq 'wiggle (harness-ui-pet--play 'wiggle)))
            (should-not harness-ui-pet--idle-timer)
            (should (timerp harness-ui-pet--beat-timer))
            (should (= harness-ui-pet--tick (timer--repeat-delay harness-ui-pet--beat-timer)))
            (should (equal '(1 0 1 0) (plist-get harness-ui-pet--beat :frames)))
            (harness-ui-pet-test--check-frame buf 0)
            (let ((state (harness-ui-pet-test--state buf)))
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame buf 1)
              (should (equal (list buf) harness-ui-pet--moved))
              (should (equal state (harness-ui-pet-test--state buf)))
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame buf 0)
              (should harness-ui-pet--beat-timer)
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame buf 1)
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame buf 0)
              (should (equal state (harness-ui-pet-test--state buf))))
            ;; Over: nothing ticks, the figure is at rest, and the next beat awaits.
            (should-not harness-ui-pet--beat-timer)
            (should-not harness-ui-pet--beat)
            (should-not harness-ui-pet--moved)
            (should (timerp harness-ui-pet--idle-timer))
            (should (= 1 (length (harness-ui-pet-test--timers))))
            ;; Its idle time over, it plays one of the idle beats.
            (harness-ui-pet--idle-beat)
            (should-not harness-ui-pet--idle-timer)
            (should (memq (plist-get harness-ui-pet--beat :kind) (mapcar #'car harness-ui-pet--idle-beats)))
            (should (timerp harness-ui-pet--beat-timer))
            (harness-ui-pet--still)
            (should-not (harness-ui-pet-test--timers))
            ;; Text inserted before the figure moves it: its lines are found again.
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (save-excursion (goto-char (point-min)) (insert "x"))))
            (harness-ui-pet--show-frame 2)
            (harness-ui-pet-test--check-frame buf 2)
            (should (= (with-current-buffer buf (buffer-chars-modified-tick)) (car (buffer-local-value 'harness-ui-pet--runs buf))))
            (harness-ui-pet--show-frame 0)
            (harness-ui-pet-test--check-frame buf 0)
            ;; The spin is a 3D turn, shown as images: where the frame shows none, as a
            ;; batch Emacs does not, nothing plays.
            (should-not (harness-ui-pet--play 'spin))
            (should-not harness-ui-pet--beat)
            (should-not harness-ui-pet--beat-timer)
            ;; Where it does, it turns through every step of the model, one turn, and ends at rest.
            (harness-ui-pet-test-with-3d
              (should (eq 'spin (harness-ui-pet--play 'spin)))
              (should-not harness-ui-pet--idle-timer)
              (should (timerp harness-ui-pet--beat-timer))
              (should (= harness-ui-pet-3d-tick (timer--repeat-delay harness-ui-pet--beat-timer)))
              (harness-ui-pet-test--check-frame buf 0)
              (let ((state (harness-ui-pet-test--state buf)))
                (dotimes (k harness-ui-pet-3d-count)
                  (harness-ui-pet--beat-step)
                  (harness-ui-pet-test--check-frame buf (cons 'spin k))
                  (should (equal (list buf) harness-ui-pet--moved))
                  (should harness-ui-pet--beat-timer))
                (harness-ui-pet--beat-step)
                (harness-ui-pet-test--check-frame buf 0)
                (should (equal state (harness-ui-pet-test--state buf))))
              (should-not harness-ui-pet--beat-timer)
              (should-not harness-ui-pet--moved)
              (should (timerp harness-ui-pet--idle-timer))
              ;; A figure drawn anew is at rest; the beat goes on with its next frame.
              (harness-ui-pet--play 'spin)
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame buf '(spin . 0))
              (with-current-buffer buf (harness-ui-pet--redraw-tail))
              (harness-ui-pet-test--check-frame buf 0)
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame buf '(spin . 1))
              ;; Another beat takes its place at its own pace: a new timer, not the spin's.
              (let ((timer harness-ui-pet--beat-timer))
                (harness-ui-pet--play 'wiggle)
                (should-not (eq timer harness-ui-pet--beat-timer))
                (should-not (memq timer timer-list))
                (should (= harness-ui-pet--tick (timer--repeat-delay harness-ui-pet--beat-timer)))
                (harness-ui-pet--play 'spin)
                (should (= harness-ui-pet-3d-tick (timer--repeat-delay harness-ui-pet--beat-timer))))
              (harness-ui-pet--still)
              (harness-ui-pet-test--check-frame buf 0)
              (should-not harness-ui-pet--moved))
            ;; In a window too short for the whole creature: its face, the eyes of which shut.
            (let ((harness-ui-pet--min-lines 1000))
              (harness-ui-pet--sync-panels)
              (harness-ui-pet--still)
              (let* ((view harness-ui-pet--current)
                     (run (car (harness-ui-pet-test--runs buf)))
                     (face (harness-ui-pet-face (plist-get view :species) (plist-get view :eye) t)))
                (should (eq 'face (nth 2 run)))
                (should (= 1 (length (harness-ui-pet-test--runs buf))))
                (harness-ui-pet--play 'blink)
                (let ((state (harness-ui-pet-test--state buf)))
                  (harness-ui-pet--beat-step)
                  (harness-ui-pet-test--check-display buf run face)
                  (should (equal state (harness-ui-pet-test--state buf))))
                (harness-ui-pet--beat-step)
                (should (cl-every #'null (harness-ui-pet-test--displays buf)))
                (should-not harness-ui-pet--beat-timer)
                ;; The others move the creature, which a face does not show.
                (harness-ui-pet--play 'wiggle)
                (harness-ui-pet--beat-step)
                (should (cl-every #'null (harness-ui-pet-test--displays buf)))
                (harness-ui-pet--still)))
            (harness-ui-pet--sync-panels)
            (harness-ui-pet--still)
            (should (> (length (harness-ui-pet-test--runs buf)) 1))
            ;; The pet turned off, the figure goes and nothing moves; turned on, it awaits a beat.
            (harness-ui-pet--play 'wiggle)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame buf 1)
            (let ((view harness-ui-pet--current))
              (harness-ui-pet--receive (plist-put (copy-sequence view) :enabled :false))
              (should-not (harness-ui-pet-test--timers))
              (should-not harness-ui-pet--moved)
              (should-not (harness-ui-pet-test--runs buf))
              (harness-ui-pet--receive view)
              (should (harness-ui-pet-test--runs buf))
              (harness-ui-pet-test--check-frame buf 0)
              (should (timerp harness-ui-pet--idle-timer)))
            (harness-ui-pet--still)
            ;; Off screen it stands still: no timer, the lines at rest.
            (harness-ui-pet--play 'wiggle)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame buf 1)
            (switch-to-buffer other)
            (should-not (harness-ui-pet--figure-buffers))
            (harness-ui-pet--on-window-buffer (selected-frame))
            (should-not harness-ui-pet--beat-timer)
            (should-not harness-ui-pet--idle-timer)
            (should-not harness-ui-pet--timer)
            (should-not harness-ui-pet--beat)
            (should-not harness-ui-pet--moved)
            (should (cl-every #'null (harness-ui-pet-test--displays buf)))
            (should-not (harness-ui-pet-test--timers))
            ;; Nothing plays, and nothing is awaited.
            (should-not (harness-ui-pet--play 'blink))
            (harness-ui-pet--arm)
            (harness-ui-pet--idle-beat)
            (harness-ui-pet--beat-step)
            (should-not (harness-ui-pet-test--timers))
            ;; Shown again, it awaits its next beat.
            (switch-to-buffer buf)
            (harness-ui-pet--on-window-buffer (selected-frame))
            (should (timerp harness-ui-pet--idle-timer))
            ;; A tick that finds the chat gone stands still, and stops the timers.
            (harness-ui-pet--play 'wiggle)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame buf 1)
            (switch-to-buffer other)
            (harness-ui-pet--beat-step)
            (should-not (harness-ui-pet-test--timers))
            (should (cl-every #'null (harness-ui-pet-test--displays buf)))
            (switch-to-buffer buf)
            ;; Animations off: nothing is set, and a beat playing ends at once, at rest.
            (harness-ui-pet--arm)
            (harness-ui-pet--play 'wiggle)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame buf 1)
            (let ((harness-ui-pet-animations nil))
              (harness-ui-pet--beat-step))
            (should-not (harness-ui-pet-test--timers))
            (should (cl-every #'null (harness-ui-pet-test--displays buf)))
            (let ((harness-ui-pet-animations nil))
              (harness-ui-pet--arm)
              (should-not (harness-ui-pet--play 'blink))
              (should-not (harness-ui-pet-test--timers)))
            ;; The setting itself: on arms the figures, off stops them at once, at rest.
            (customize-set-variable 'harness-ui-pet-animations nil)
            (should-not (harness-ui-pet-test--timers))
            (customize-set-variable 'harness-ui-pet-animations t)
            (should (timerp harness-ui-pet--idle-timer))
            (harness-ui-pet--play 'wiggle)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame buf 1)
            (customize-set-variable 'harness-ui-pet-animations nil)
            (should-not (harness-ui-pet-test--timers))
            (should-not harness-ui-pet--beat)
            (should (cl-every #'null (harness-ui-pet-test--displays buf)))
            ;; The module stopping takes everything away with it.
            (customize-set-variable 'harness-ui-pet-animations t)
            (harness-ui-pet--play 'wiggle)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame buf 1)
            (harness-ui-pet--shutdown)
            (should-not (harness-ui-pet-test--timers))
            (should-not harness-ui-pet--moved)
            (should-not (harness-ui-pet-test--runs buf)))
        (harness-ui-pet--still)
        (kill-buffer other)))))

(ert-deftest harness-ui-pet-beat-errors-stop-the-timers ()
  "A beat that signals does not signal again with every tick."
  (harness-ui-pet-test-with-chat-figure buf
    (let ((harness-ui-pet-animations t))
      (harness-ui-pet--play 'wiggle)
      (should (timerp harness-ui-pet--beat-timer))
      (cl-letf (((symbol-function 'harness-ui-pet--show-frame) (lambda (&rest _) (error "Boom"))))
        (should-error (harness-ui-pet--beat-step) :type 'error))
      (should-not harness-ui-pet--beat)
      (should-not (harness-ui-pet-test--timers))
      ;; An idle moment that signals leaves no timer behind either.
      (harness-ui-pet--arm)
      (cl-letf (((symbol-function 'harness-ui-pet--pick-beat) (lambda () (error "Boom"))))
        (should-error (harness-ui-pet--idle-beat) :type 'error))
      (should-not (harness-ui-pet-test--timers)))))

(ert-deftest harness-ui-pet-figure-beats-on-the-board ()
  "The same frames show on the board, on the lines of the creature beside the
compose label and the settings as well as those above them."
  (harness-ui-pet-test-with
    (let ((harness-acp--server-enabled nil))
      (harness-test-load-module 'tasks))
    (clrhash harness-tasks--table)
    (clrhash harness-tasks--starting)
    (setq harness-tasks--loaded t)
    (harness-test-load-module 'ui-tasks)
    (let* ((harness-pet-overrides '(:species capybara :eye "o" :hat none :rarity rare :name "Fennel"))
           (harness-tasks-worktrees nil)
           (board (harness-tasks dir)))
      (unwind-protect
          (progn
            (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board)))
                               5 "the board to load")
            (harness-ui-pet-test--know-the-pet)
            (harness-ui-pet-test--hatch-elsewhere)
            (harness-test-wait (lambda () (harness-ui-pet-test--figure board)) 5 "the pet on the board")
            (let ((harness-ui-pet-animations t))
              (should (equal (list board) (harness-ui-pet--figure-buffers)))
              (let* ((runs (harness-ui-pet-test--runs board))
                     (keys (with-current-buffer board
                             (mapcar (lambda (run) (get-text-property (car run) 'harness-task-tail)) runs))))
                ;; All of it, from the creature's top row to its bottom row, beside the label
                ;; and the settings and above them.
                (should (equal (number-sequence 0 (1- (length runs))) (mapcar (lambda (run) (nth 2 run)) runs)))
                (should (equal '(label settings) (last keys 2)))
                (should (cl-every (lambda (key) (eq key 'corner)) (butlast keys 2)))
                (should (cl-find 'corner keys)))
              (harness-ui-pet--arm)
              (should (timerp harness-ui-pet--idle-timer))
              (harness-ui-pet--play 'wiggle)
              (let ((state (harness-ui-pet-test--state board)))
                (harness-ui-pet--beat-step)
                (harness-ui-pet-test--check-frame board 1)
                (should (equal state (harness-ui-pet-test--state board)))
                (harness-ui-pet--beat-step)
                (harness-ui-pet-test--check-frame board 0)
                (harness-ui-pet--beat-step)
                (harness-ui-pet-test--check-frame board 1)
                (harness-ui-pet--beat-step)
                (harness-ui-pet-test--check-frame board 0)
                (should (equal state (harness-ui-pet-test--state board))))
              (should-not harness-ui-pet--beat-timer)
              (should-not harness-ui-pet--moved)
              ;; A spin too, all the way round: slices of the picture on the lines of the
              ;; creature beside the label and the settings as well as those above them.
              (harness-ui-pet-test-with-3d
                (harness-ui-pet--play 'spin)
                (dotimes (k harness-ui-pet-3d-count)
                  (harness-ui-pet--beat-step)
                  (harness-ui-pet-test--check-frame board (cons 'spin k)))
                (harness-ui-pet--beat-step)
                (harness-ui-pet-test--check-frame board 0)
                (should-not harness-ui-pet--beat-timer))
              ;; The board gone from the screen: still.
              (harness-ui-pet--play 'wiggle)
              (harness-ui-pet--beat-step)
              (let ((other (get-buffer-create " *harness-ui-pet-test other*")))
                (unwind-protect
                    (progn
                      (switch-to-buffer other)
                      (harness-ui-pet--on-window-buffer (selected-frame))
                      (should-not (harness-ui-pet-test--timers))
                      (should (cl-every #'null (harness-ui-pet-test--displays board))))
                  (switch-to-buffer board)
                  (kill-buffer other)))))
        (harness-ui-pet--still)
        (kill-buffer board)))))

(ert-deftest harness-ui-pet-said-starts-a-fidget ()
  "As the pet speaks, its figures fidget: the frames of its fidget, then at rest.
Only where they may move: on screen, and with animations on."
  (harness-ui-pet-test-with-chat-figure buf
    (let ((harness-ui-pet-animations t)
          (other (get-buffer-create "*harness-ui-pet-test other*")))
      (unwind-protect
          (progn
            (harness-ui-pet--still)
            (harness-ui-pet--on-event "pet/said" (list (list :text "hi")))
            (should (eq 'fidget (plist-get harness-ui-pet--beat :kind)))
            (should (timerp harness-ui-pet--beat-timer))
            (should-not harness-ui-pet--idle-timer)
            (dolist (frame (append harness-ui-pet--fidget '(0)))
              (should harness-ui-pet--beat-timer)
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame buf frame))
            (should-not harness-ui-pet--beat-timer)
            (should (timerp harness-ui-pet--idle-timer))
            ;; Animations off, or no figure on screen: it does not stir.
            (harness-ui-pet--still)
            (let ((harness-ui-pet-animations nil))
              (harness-ui-pet--on-event "pet/said" (list (list :text "hi")))
              (should-not harness-ui-pet--beat))
            (switch-to-buffer other)
            (harness-ui-pet--on-event "pet/said" (list (list :text "hi")))
            (should-not harness-ui-pet--beat)
            (should-not (harness-ui-pet-test--timers))
            (switch-to-buffer buf))
        (harness-ui-pet--still)
        (kill-buffer other)))))

(ert-deftest harness-ui-pet-spin-turns-the-figures-too ()
  "s spins the figure by a chat's compose box along with the card.
Here the pet's own buffer is open but not on screen, so only the figure
moves: it plays a spin, a step of the 3D turn a tick, and ends at rest.
Where it cannot, s says why and nothing plays."
  (harness-ui-pet-test-with-chat-figure buf
    (let ((harness-ui-pet-animations t)
          (pet (get-buffer-create harness-ui-pet-test--buffer)))
      (with-current-buffer pet
        (harness-ui-pet-mode)
        (setq harness-ui-pet--view harness-ui-pet--current))
      (should (equal (list buf) (harness-ui-pet--figure-buffers)))
      (should-not (harness-ui-pet--shown-p))
      ;; A batch Emacs shows no images: it says so, and the figure stays as it is.
      (let ((said nil))
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
          (with-current-buffer pet (harness-ui-pet-spin)))
        (should (equal "Fennel spins only in a graphical frame" said))
        (should-not harness-ui-pet--beat)
        (should-not (harness-ui-pet-test--timers)))
      (harness-ui-pet-test-with-3d
        (with-current-buffer pet (harness-ui-pet-spin))
        (should (eq 'spin (plist-get harness-ui-pet--beat :kind)))
        (should (timerp harness-ui-pet--beat-timer))
        (should (= harness-ui-pet-3d-tick (timer--repeat-delay harness-ui-pet--beat-timer)))
        ;; The card is not on screen: it does not move, and has no timer.
        (should-not (buffer-local-value 'harness-ui-pet--anim pet))
        (should-not harness-ui-pet--timer)
        (harness-ui-pet--beat-step)
        (harness-ui-pet-test--check-frame buf '(spin . 0))
        (harness-ui-pet--beat-step)
        (harness-ui-pet-test--check-frame buf '(spin . 1))
        (harness-ui-pet--still)
        (harness-ui-pet-test--check-frame buf 0)
        (should-not (harness-ui-pet-test--timers))))))

;;;; Where it stands

(defun harness-ui-pet-test--set-status (buffer status)
  "Make the session of the chat BUFFER STATUS, as a `_harness/session' push would."
  (with-current-buffer buffer
    (let ((session (plist-put (copy-sequence (harness-chat--session)) :status status)))
      (harness-ui-cache-session session)
      (harness-chat--apply-update (list :sessionUpdate "_harness/session" :session session)))))

(defun harness-ui-pet-test--find (buffer text)
  "The end of the first TEXT in BUFFER, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil))
        (search-forward text nil t)))))

(defun harness-ui-pet-test--below (buffer)
  "Where the line under the last row of the pet's figure in BUFFER starts."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (nth 1 (car (last (harness-ui-pet-test--figure-rows buffer)))))
      (1+ (line-end-position)))))

(ert-deftest harness-ui-pet-stands-on-whatever-comes-first-in-a-chat ()
  "The figure of a chat is first below its transcript, so it stands on what comes next.
The compose box when nothing else is in the tail, then the request
waiting for you, the todo list and, while the turn runs, the activity
line: it is whole through each, and plays its beats on each."
  (harness-ui-pet-test-with-chat-figure buf
    (let ((harness-ui-pet-animations t))
      (cl-flet ((top () (nth 1 (car (harness-ui-pet-test--figure-rows buf))))
                (below () (harness-ui-pet-test--below buf))
                (find (text) (harness-ui-pet-test--find buf text))
                (box () (marker-position (buffer-local-value 'harness-compose-start buf)))
                (line (pos) (with-current-buffer buf (line-number-at-pos pos)))
                (line-at (pos) (with-current-buffer buf
                                 (save-excursion (goto-char pos)
                                                 (buffer-substring-no-properties (point) (line-end-position)))))
                (transcript-end () (marker-position (buffer-local-value 'harness-chat--transcript-end buf)))
                (activity () (let ((ov (buffer-local-value 'harness-chat--activity-overlay buf)))
                               (and ov (overlay-buffer ov) (overlay-get ov 'before-string) ov))))
        ;; In the tail's top functions, none of the panels; nothing else there:
        ;; first below the transcript, right above the compose box.
        (should (memq #'harness-ui-pet--panel (default-value 'harness-chat-top-functions)))
        (should-not (memq #'harness-ui-pet--panel (default-value 'harness-chat-panel-functions)))
        (should (= (top) (transcript-end)))
        (should (= (line (below)) (line (box))))
        (should (get-text-property (top) 'harness-chat-top buf))
        (harness-ui-pet-test--check-figure buf)
        ;; The todo list: the figure's rows come right after the transcript,
        ;; above the list's title, which is the line under them.
        (harness-call 'session/set-todos sid '((:id "1" :text "Survey the project" :status "in-progress")))
        (harness-test-wait (lambda () (buffer-local-value 'harness-chat--todos buf)) 5 "the todo list to show")
        (should (= (top) (transcript-end)))
        (should (= (below) (with-current-buffer buf (text-property-any (point-min) (point-max) 'harness-chat-todos t))))
        (should (< (below) (find "Todo list") (box)))
        (harness-ui-pet-test--check-figure buf)
        ;; A request waiting for you comes under it, ahead of the list.
        (harness-call 'session/pending-add sid
                      (list :id "pre" :kind 'permission
                            :payload (list :tool "bash" :title "Bash: echo" :kind 'exec :input '(:command "echo"))))
        (harness-test-wait (lambda () (buffer-local-value 'harness-chat--pending buf)) 5 "the request to show")
        (should (= (top) (transcript-end)))
        (should (string-search "Permission" (line-at (below))))
        (should (< (find "Permission") (find "Todo list") (box)))
        (harness-ui-pet-test--check-figure buf)
        ;; While the turn runs the activity line stands on the request, right under the figure.
        (should-not (activity))
        (harness-ui-pet-test--set-status buf "running")
        (should (activity))
        (should (= (below) (overlay-start (activity)) (overlay-end (activity))))
        (should (= (top) (transcript-end)))
        (should (= 1 (length (cl-remove-if-not (lambda (ov) (overlay-get ov 'harness-chat-activity))
                                                (with-current-buffer buf (overlays-in (point-min) (point-max)))))))
        (harness-ui-pet-test--check-figure buf)
        ;; A beat plays there as ever: a wiggle swaps what the creature's lines display
        ;; and edits nothing, with the request, the list and the activity line below.
        (harness-ui-pet--arm)
        (harness-ui-pet--play 'wiggle)
        (let ((state (harness-ui-pet-test--state buf)))
          (harness-ui-pet--beat-step)
          (harness-ui-pet-test--check-frame buf 1)
          (should (equal (list buf) harness-ui-pet--moved))
          (should (equal state (harness-ui-pet-test--state buf)))
          (harness-ui-pet--beat-step)
          (harness-ui-pet-test--check-frame buf 0)
          (should (equal state (harness-ui-pet-test--state buf))))
        (harness-ui-pet--still)
        ;; Drawn again, with the tail, it stands where it did and the line follows it.
        (with-current-buffer buf (harness-chat--render-tail))
        (should (= (top) (transcript-end)))
        (should (= (below) (overlay-start (activity))))
        (harness-ui-pet-test--check-figure buf)
        ;; The turn over, no line is under it; the request and the list still are.
        (harness-ui-pet-test--set-status buf "idle")
        (should-not (activity))
        (should (string-search "Permission" (line-at (below))))))))


(defmacro harness-ui-pet-test-with-list (buffer &rest body)
  "Run BODY with BUFFER the session list on screen, the pet under its rows.
The pet is a rare capybara called Fennel, hatched; two sessions are
listed, \"Parser work\" and \"Tokenizer\"."
  (declare (indent 1))
  `(harness-ui-pet-test-with
     (harness-test-load-module 'ui-sessions)
     (let* ((harness-pet-overrides '(:species capybara :eye "o" :hat none :rarity rare :name "Fennel")))
       (harness-call 'session/create :cwd dir :model "demo:scripted" :name "Parser work")
       (harness-call 'session/create :cwd dir :model "demo:scripted" :name "Tokenizer")
       (harness-sessions t)
       (let ((,buffer (get-buffer harness-ui-sessions--buffer-name)))
         (unwind-protect
             (progn
               (harness-test-wait (lambda () (with-current-buffer ,buffer (= 2 (length tabulated-list-entries))))
                                  5 "the list to show the sessions")
               (switch-to-buffer ,buffer)
               (harness-ui-pet-test--know-the-pet)
               (harness-ui-pet-test--hatch-elsewhere)
               (harness-test-wait (lambda () (harness-ui-pet-test--figure ,buffer)) 5 "the pet under the list")
               ,@body)
           (harness-ui-pet--still)
           (kill-buffer ,buffer))))))

(defun harness-ui-pet-test--after-rows (buffer)
  "Where the text of BUFFER, a session list, after its last row starts."
  (with-current-buffer buffer
    (let ((end (point-max)))
      (while (and (> end (point-min)) (not (get-text-property (1- end) 'tabulated-list-id)))
        (setq end (1- end)))
      end)))

(ert-deftest harness-ui-pet-stands-under-the-session-list ()
  "Hatched, the whole pet stands once under the last row of the session list.
Right-aligned at its bottom right, after a blank line, and no session's:
none of its lines carry a session.  It follows the last row through a
column's sort and a list printed again, and it is the last thing in the
buffer."
  (harness-ui-pet-test-with-list list
    (harness-ui-pet-test--check-figure list)
    (let ((sprite (car (harness-ui-pet--sprite harness-ui-pet--current))))
      (cl-flet ((check ()
                  ;; A blank line after the last row, then the creature once, named, to the end.
                  (harness-ui-pet-test--check-figure list)
                  (let ((after (harness-ui-pet-test--after-rows list))
                        (rows (harness-ui-pet-test--figure-rows list)))
                    (with-current-buffer list
                      (should (= (length sprite) (length rows)))
                      (should (string-search "Fennel" (harness-ui-pet-test--figure-text list)))
                      (should (equal "\n" (buffer-substring-no-properties after (1+ after))))
                      (should (= (1+ after) (nth 1 (car rows))))
                      (should-not (get-text-property after 'harness-ui-pet-figure))
                      ;; No session's: nothing of it, nor its blank line, names one.
                      (should-not (text-property-not-all after (point-max) 'tabulated-list-id nil))
                      (should-not (text-property-not-all after (point-max) 'tabulated-list-entry nil))
                      (should-not (tabulated-list-get-id (nth 1 (car (last rows)))))
                      ;; The last row of the list is just above the blank line.
                      (should (tabulated-list-get-id (1- after)))
                      (should (= 1 (how-many "Fennel" (point-min) (point-max)))))
                    after)))
        (let ((after (check)))
          ;; The list printed again, as it is as sessions change: once, in the same place.
          (harness-ui-sessions-redraw)
          (should (= after (check)))
          ;; A column's sort prints it as well -- not through the list's own print --
          ;; and the figure follows the last row of the order it sorts into: by name,
          ;; then back to front, so the last row changes hands.
          (let ((last-rows nil))
            (dotimes (_ 2)
              (with-current-buffer list (tabulated-list-sort 1))
              (let ((end (check)))
                (push (with-current-buffer list (tabulated-list-get-id (1- end))) last-rows)))
            (should (= 2 (length (delete-dups last-rows))))))))))

(ert-deftest harness-ui-pet-list-figure-is-kept-while-it-holds ()
  "The list prints again every half second while sessions stream: the figure
costs next to nothing then.  The lines it was drawn as are the same ones
while its spec holds, measured in pixels once; another spec is drawn anew."
  (harness-ui-pet-test-with-list list
    (let* ((measured 0)
           (lines (lambda () (cdr (buffer-local-value 'harness-ui-pet--lines-kept list))))
           (kept (funcall lines)))
      (should (stringp kept))
      (cl-letf* ((measure (symbol-function 'harness-ui-pet--pixels))
                 ((symbol-function 'harness-ui-pet--pixels)
                  (lambda (&rest args) (cl-incf measured) (apply measure args))))
        ;; A print with the spec as it was: the same lines, and the only measures
        ;; are those the spec asks for, a column of each window.
        (harness-ui-sessions-redraw)
        (should (eq kept (funcall lines)))
        (let ((cheap measured))
          (should (<= 1 cheap 2))
          (harness-ui-pet-test--check-figure list)
          ;; With nothing kept, the figure's rows are measured as well.
          (setq measured 0)
          (with-current-buffer list (setq harness-ui-pet--lines-kept nil))
          (harness-ui-sessions-redraw)
          (should (> measured cheap))
          (should (equal kept (funcall lines)))
          (should-not (eq kept (funcall lines)))))
      ;; Another look, another figure: the pet is renamed.
      (let ((view harness-ui-pet--current))
        (harness-ui-pet--receive (plist-put (copy-sequence view) :name "Truffle"))
        (should (string-search "Truffle" (harness-ui-pet-test--figure-text list)))
        (should-not (string-search "Fennel" (harness-ui-pet-test--figure-text list)))
        (harness-ui-pet-test--check-figure list)
        (should (= (length (car (harness-ui-pet--sprite harness-ui-pet--current)))
                   (length (harness-ui-pet-test--figure-rows list))))))))


(ert-deftest harness-ui-pet-list-on-screen-lets-it-speak-about-itself-and-recap ()
  "The session list on screen, the pet under it, lets it speak about itself and
recap the sessions the list lists.  This Emacs tells the harness so, as
it does for the board; the list off screen, or left out of
`harness-ui-pet-places', does not.  Left out, the footer is not hooked,
and the figure leaves the list and comes back."
  (harness-ui-pet-test-with-list list
    (let* ((listed (with-current-buffer list (sort (mapcar #'car tabulated-list-entries) #'string<)))
           (watch (harness-ui-pet-test--watch t nil listed)))
      (should (= 2 (length listed)))
      (should (equal watch (harness-ui-pet--seen)))
      (should (equal watch (harness-ui-pet--seen t)))
      (harness-test-wait (lambda () (equal watch (harness-ui-pet-test--watching))) 5 "the list's watch")
      ;; Only where the pet sits under the list.
      (let ((harness-ui-pet-places '(chat board chat-header)))
        (should-not (harness-ui-pet--seen)))
      (let ((harness-ui-pet-places '(sessions)))
        (should (equal watch (harness-ui-pet--seen))))
      ;; Off screen it is not seen, and the harness hears so; back, and it does.
      (let ((other (get-buffer-create "*harness-ui-pet-test other*")))
        (unwind-protect
            (progn
              (switch-to-buffer other)
              (should-not (harness-ui-pet--seen))
              (harness-ui-pet--update-watch (selected-frame))
              (harness-test-wait (lambda () (null (harness-ui-pet-test--watching))) 5 "the watch to end")
              (switch-to-buffer list)
              (harness-ui-pet--update-watch (selected-frame))
              (harness-test-wait (lambda () (equal watch (harness-ui-pet-test--watching))) 5 "the watch again"))
          (kill-buffer other))))
    ;; Left out of the places: nothing wired for it, and the list is as it was without it.
    (let ((places harness-ui-pet-places))
      (unwind-protect
          (progn
            (customize-set-variable 'harness-ui-pet-places '(chat board))
            (should-not (harness-ui-pet-test--own-hooks 'harness-ui-sessions-footer-functions))
            (should-not (harness-ui-pet-test--figure list))
            (should-not (buffer-local-value 'harness-ui-pet--panel-shown list))
            (should-not (harness-ui-pet--figure-buffers))
            (should (equal "" (with-current-buffer list
                                (buffer-substring-no-properties (harness-ui-pet-test--after-rows list) (point-max)))))
            (should-not (harness-ui-pet--seen)))
        (customize-set-variable 'harness-ui-pet-places places)))
    ;; Put back, it stands under the rows again.
    (should (harness-ui-pet-test--own-hooks 'harness-ui-sessions-footer-functions))
    (harness-ui-pet-test--check-figure list)
    (should (equal (list list) (harness-ui-pet--figure-buffers)))))

(ert-deftest harness-ui-pet-list-says-what-it-said-last ()
  "The bubble beside the pet under the list says what it said last about itself,
or its recap of a session the list lists; never what it said about a
session's work.  Joined to it at its eyes; muted, the words leave and the
pet stays."
  (harness-ui-pet-test-with-list list
    (harness-test-wait (lambda () (plist-get (harness-ui-pet-test--watching) :self)) 5 "the list's watch")
    (harness-call 'pet/pet)
    (harness-test-wait (lambda () (string-search "Acknowledged." (harness-ui-pet-test--figure-text list)))
                       5 "its words under the list")
    (harness-ui-pet-test--check-figure list)
    (should (harness-ui-pet-test--joined list))
    ;; Said about nothing in particular: a chat's turn starting does not take it away.
    (harness-ui-pet--on-event "agent/turn-started" (list "no-such-session"))
    (should (string-search "Acknowledged." (harness-ui-pet-test--figure-text list)))
    (let* ((listed (with-current-buffer list (car (car tabulated-list-entries))))
           (said (lambda (saying)
                   (harness-ui-pet--receive
                    (plist-put (copy-sequence harness-ui-pet--current) :said
                               (append (plist-get harness-ui-pet--current :said) (list saying)))))))
      ;; What it said about a listed session's work is for that session's chat.
      (funcall said (list :text "Bold move." :ts (float-time) :reason "prompt" :session listed :scope "session"))
      (should (string-search "Acknowledged." (harness-ui-pet-test--figure-text list)))
      (should-not (string-search "Bold move." (harness-ui-pet-test--figure-text list)))
      ;; Its recap of a session the list does not list is for another overview.
      (funcall said (list :text "Elsewhere." :ts (float-time) :reason "recap" :session "no-such-session"
                          :scope "overview"))
      (should (string-search "Acknowledged." (harness-ui-pet-test--figure-text list)))
      ;; Its recap of a listed session shows.
      (funcall said (list :text "Still at it." :ts (float-time) :reason "recap" :session listed :scope "overview"))
      (should (string-search "Still at it." (harness-ui-pet-test--figure-text list)))
      (harness-ui-pet-test--check-figure list))
    (harness-call 'pet/set-muted t)
    (harness-test-wait (lambda () (not (string-search "Still at it." (harness-ui-pet-test--figure-text list))))
                       5 "its words to leave")
    (harness-ui-pet-test--check-figure list)
    (harness-call 'pet/set-muted :false)))

(ert-deftest harness-ui-pet-list-figure-fits-its-window-and-moves ()
  "A window too short for the whole creature gets its face on one line.
After the blank line under the rows, the whole creature back with the
room.  Its beats play under the list: a wiggle shows frame 1 on the
creature's lines, a blink shuts the eyes of the face, a list printed
again meanwhile puts it back at rest, and nothing runs off screen."
  (harness-ui-pet-test-with-list list
    (let ((harness-ui-pet-animations t)
          (other (get-buffer-create "*harness-ui-pet-test other*")))
      (unwind-protect
          (progn
            ;; A short window: its face and name on the line after the blank one.
            (let ((harness-ui-pet--min-lines 1000))
              (harness-ui-pet--sync-panels)
              (harness-ui-pet--still)
              (let* ((rows (harness-ui-pet-test--figure-rows list))
                     (view harness-ui-pet--current)
                     (after (harness-ui-pet-test--after-rows list))
                     (face (harness-ui-pet-face (plist-get view :species) (plist-get view :eye))))
                (should (= 1 (length rows)))
                (should (string-prefix-p face (car (car rows))))
                (should (string-search (plist-get view :name) (car (car rows))))
                (with-current-buffer list
                  (should (equal "\\n" (replace-regexp-in-string "\n" "\\\\n" (buffer-substring-no-properties after (1+ after)))))
                  (should (= (1+ after) (nth 1 (car rows))))
                  (should-not (text-property-not-all after (point-max) 'tabulated-list-id nil)))
                ;; Its eyes shut for a blink; the other beats move what the face does not show.
                (let ((run (car (harness-ui-pet-test--runs list))))
                  (should (eq 'face (nth 2 run)))
                  (harness-ui-pet--play 'blink)
                  (harness-ui-pet--beat-step)
                  (harness-ui-pet-test--check-display
                   list run (harness-ui-pet-face (plist-get view :species) (plist-get view :eye) t))
                  (harness-ui-pet--beat-step)
                  (should (cl-every #'null (harness-ui-pet-test--displays list)))
                  (harness-ui-pet--play 'wiggle)
                  (harness-ui-pet--beat-step)
                  (should (cl-every #'null (harness-ui-pet-test--displays list)))
                  (harness-ui-pet--still))))
            ;; The room back: the whole creature.
            (harness-ui-pet--sync-panels)
            (harness-ui-pet--still)
            (harness-ui-pet-test--check-figure list)
            ;; A wiggle: frame 1 on the creature's lines, then rest, the text left be.
            (should (equal (list list) (harness-ui-pet--figure-buffers)))
            (should (harness-ui-pet--animating-p))
            (harness-ui-pet--arm)
            (should (timerp harness-ui-pet--idle-timer))
            (should (eq 'wiggle (harness-ui-pet--play 'wiggle)))
            (let ((state (harness-ui-pet-test--state list)))
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame list 1)
              (should (equal (list list) harness-ui-pet--moved))
              (should (equal state (harness-ui-pet-test--state list)))
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame list 0)
              (should (equal state (harness-ui-pet-test--state list))))
            ;; Printed again mid-beat: the figure is drawn at rest, the beat goes on.
            (harness-ui-pet--still)
            (harness-ui-pet--play 'wiggle)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame list 1)
            (harness-ui-sessions-redraw)
            (harness-ui-pet-test--check-frame list 0)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame list 0)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame list 1)
            (harness-ui-pet--still)
            (harness-ui-pet-test--check-frame list 0)
            (should-not (harness-ui-pet-test--timers))
            ;; A spin turns through the steps of the model too.
            (harness-ui-pet-test-with-3d
              (harness-ui-pet--play 'spin)
              (dotimes (k harness-ui-pet-3d-count)
                (harness-ui-pet--beat-step)
                (harness-ui-pet-test--check-frame list (cons 'spin k)))
              (harness-ui-pet--beat-step)
              (harness-ui-pet-test--check-frame list 0))
            ;; The list off screen: nothing runs, and what moved is back at rest.
            (harness-ui-pet--play 'wiggle)
            (harness-ui-pet--beat-step)
            (harness-ui-pet-test--check-frame list 1)
            (switch-to-buffer other)
            (should-not (harness-ui-pet--figure-buffers))
            (harness-ui-pet--on-window-buffer (selected-frame))
            (should-not (harness-ui-pet-test--timers))
            (should-not harness-ui-pet--moved)
            (should (cl-every #'null (harness-ui-pet-test--displays list)))
            ;; Shown again, it awaits its next beat.
            (switch-to-buffer list)
            (harness-ui-pet--on-window-buffer (selected-frame))
            (should (timerp harness-ui-pet--idle-timer)))
        (harness-ui-pet--still)
        (kill-buffer other)))))

(ert-deftest harness-ui-pet-sessions-footer-is-a-blank-line-and-the-figure ()
  "The footer under the session list is one blank line, then the figure's lines.
The lines the buffer's figure is drawn as, the same ones for as long as
it holds; nothing while the pet does not sit there, or not even its face
fits."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (let ((view (list :species "duck" :eye "o" :hat "none" :rarity "rare" :name "Fennel" :hatched t))
        (harness-ui-pet--live t))
    (with-temp-buffer
      (let ((harness-ui-pet--current view)
            (harness-ui-pet-places '(sessions)))
        (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 40 1))))
          (let ((footer (harness-ui-pet--sessions-footer)))
            (should (stringp footer))
            (should (string-prefix-p "\n" footer))
            (should-not (string-prefix-p "\n\n" footer))
            (should (string-suffix-p "\n" footer))
            ;; Whole lines of the figure: as many as the creature is tall.
            (should (= (length (car (harness-ui-pet--sprite view)))
                       (length (split-string footer "\n" t))))
            (should (eq (cdr harness-ui-pet--lines-kept) (harness-ui-pet--draw (harness-ui-pet--sessions-spec))))
            (should (equal (substring footer 1) (cdr harness-ui-pet--lines-kept)))
            (should harness-ui-pet--panel-shown)
            ;; Not where the pet does not sit.
            (let ((harness-ui-pet-places '(chat board)))
              (should-not (harness-ui-pet--sessions-footer))
              (should-not harness-ui-pet--panel-shown)
              (should-not harness-ui-pet--lines-kept))))
        ;; Not even its face fits: a column free on either side of it, and it is three wide.
        (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 4 40 1))))
          (should-not (harness-ui-pet--sessions-footer))
          (should-not harness-ui-pet--panel-shown))
        ;; Its face, in a short window: still after a blank line.
        (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 10 1))))
          (let ((footer (harness-ui-pet--sessions-footer)))
            (should (string-prefix-p "\n" footer))
            (should (= 1 (length (split-string footer "\n" t))))
            (should (string-search (harness-ui-pet-face "duck" "o") footer))))))))

(ert-deftest harness-ui-pet-draw-keeps-its-lines-while-the-spec-holds ()
  "A figure is drawn once for a spec and the faces under it.
The lines are the same ones while both hold; another spec or other faces
draw them anew, and no spec draws nothing and keeps nothing."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (let ((view (list :species "duck" :eye "o" :hat "none" :rarity "rare" :name "Fennel")))
    (with-temp-buffer
      (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 80 40 1))))
        (let* ((harness-ui-pet--current view)
               (spec (harness-ui-pet--spec nil))
               (lines (harness-ui-pet--draw spec)))
          (should (stringp lines))
          (should (equal spec harness-ui-pet--panel-shown))
          ;; The same spec, whether the same object or an equal one: the very lines.
          (should (eq lines (harness-ui-pet--draw spec)))
          (should (eq lines (harness-ui-pet--draw (harness-ui-pet--spec nil))))
          (should (eq lines (harness-ui-pet--draw spec harness-ui-pet--figure-faces)))
          ;; Another saying, other faces or another look: drawn anew.
          (let ((said (harness-ui-pet--draw (harness-ui-pet--spec (list :text "Hm." :ts (float-time))))))
            (should-not (eq lines said))
            (should (string-search "Hm." said))
            (should-not (string-search "Hm." lines)))
          (let ((faced (harness-ui-pet--draw spec '(bold default))))
            (should-not (eq lines faced))
            (should (equal (substring-no-properties lines) (substring-no-properties faced)))
            (should (memq 'bold (flatten-tree (get-text-property 2 'face faced)))))
          (let ((harness-ui-pet--current (plist-put (copy-sequence view) :name "Truffle")))
            (should (string-search "Truffle" (harness-ui-pet--draw (harness-ui-pet--spec nil)))))
          ;; The fit is part of the spec: a narrower window draws it again.
          (cl-letf (((symbol-function 'harness-ui-pet--room) (lambda () (list 30 40 1))))
            (should-not (eq lines (harness-ui-pet--draw (harness-ui-pet--spec nil)))))
          ;; Nothing to draw, nothing kept.
          (should-not (harness-ui-pet--draw nil))
          (should-not harness-ui-pet--panel-shown)
          (should-not harness-ui-pet--lines-kept)
          (should-not (eq lines (harness-ui-pet--draw spec))))))))

(ert-deftest harness-ui-pet-latest-saying-follows-its-place ()
  "The bubble on the board and under the session list says what the pet last said
about itself, or in its recap of a session listed there -- never what it
said about a session's work, which is for that chat.  Each only where the
pet sits, while it is fresh and the pet is not muted."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (let* ((now (float-time))
         (harness-ui-pet--live t)
         (view (list :species "cat" :eye "o" :hat "none" :rarity "rare" :name "Fennel" :hatched t
                     :said (list (list :text "Old." :ts (- now 9) :scope "pet")
                                 (list :text "Mine." :ts (- now 5) :scope "pet")
                                 (list :text "Recap." :ts (- now 3) :session "s1" :scope "overview")
                                 (list :text "Hm." :ts now :session "s2" :scope "session")))))
    (let ((harness-ui-pet--current view))
      (let ((harness-ui-pet-places '(board)))
        ;; Its own last word, not a session's work; a recap only where its session is listed.
        (should (equal "Mine." (plist-get (harness-ui-pet--latest-saying now) :text)))
        (should (equal "Mine." (plist-get (harness-ui-pet--latest-saying now 'board '("s2")) :text)))
        (should (equal "Recap." (plist-get (harness-ui-pet--latest-saying now 'board '("s1" "s2")) :text)))
        (should-not (harness-ui-pet--latest-saying now 'sessions '("s1"))))
      (let ((harness-ui-pet-places '(sessions)))
        (should-not (harness-ui-pet--latest-saying now))
        (should (equal "Recap." (plist-get (harness-ui-pet--latest-saying now 'sessions '("s1")) :text))))
      (let ((harness-ui-pet-places '(chat chat-header)))
        (should-not (harness-ui-pet--latest-saying now))
        (should-not (harness-ui-pet--latest-saying now 'sessions)))
      ;; A saying from before scopes is its session's when it is about one, else its own.
      (let ((harness-ui-pet-places '(board))
            (harness-ui-pet--current (plist-put (copy-sequence view) :said
                                                (list (list :text "Old." :ts now)
                                                      (list :text "Hm." :ts now :session "s2")))))
        (should (equal "Old." (plist-get (harness-ui-pet--latest-saying now 'board '("s2")) :text))))
      ;; Stale, muted or turned off: nothing, where it sits.  No lifetime: no stale.
      (let ((harness-ui-pet-places '(chat board sessions)))
        (should (harness-ui-pet--latest-saying now 'sessions))
        (should-not (harness-ui-pet--latest-saying (+ now harness-ui-pet-saying-lifetime 1) 'sessions '("s1")))
        (let ((harness-ui-pet-saying-lifetime nil))
          (should (equal "Recap." (plist-get (harness-ui-pet--latest-saying (+ now 86400) 'sessions '("s1"))
                                             :text))))
        (let ((harness-ui-pet--current (plist-put (copy-sequence view) :muted t)))
          (should-not (harness-ui-pet--latest-saying now 'sessions))
          (should-not (harness-ui-pet--latest-saying now 'board)))
        (let ((harness-ui-pet--current (plist-put (copy-sequence view) :enabled :false)))
          (should-not (harness-ui-pet--latest-saying now 'sessions)))))))

(ert-deftest harness-ui-pet-saying-shows-where-it-belongs ()
  "A saying shows in the buffer its scope names: about a session's work in that
session's chat only; about the pet itself on its overviews; a recap of a
session on an overview that lists it, never in the session's own chat.
The tooltip of a chat's face follows its bubble."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (let* ((now (float-time))
         (harness-ui-pet--live t)
         (harness-ui-pet-places '(chat board sessions))
         (work (list :text "Bold." :ts now :session "s1" :scope "session"))
         (recap (list :text "Busy." :ts (+ now 1) :session "s1" :scope "overview"))
         (own (list :text "Noted." :ts (+ now 2) :scope "pet"))
         (harness-ui-pet--current (list :species "cat" :eye "o" :hat "none" :rarity "rare" :name "Fennel"
                                        :hatched t :said (list work recap own))))
    (should (eq 'session (harness-ui-pet--scope work)))
    (should (eq 'overview (harness-ui-pet--scope recap)))
    (should (eq 'pet (harness-ui-pet--scope own)))
    (should (eq 'session (harness-ui-pet--scope (list :text "Old." :session "s1"))))
    (should (eq 'pet (harness-ui-pet--scope (list :text "Old."))))
    ;; In s1's chat, its work, however much the pet said since elsewhere.
    (should (eq work (harness-ui-pet--saying-for "s1" (+ now 3))))
    (should-not (harness-ui-pet--saying-for "s2" (+ now 3)))
    ;; On an overview, its own word, or the recap where s1 is listed.
    (should (eq own (harness-ui-pet--latest-saying (+ now 3) 'board '("s1"))))
    (let ((harness-ui-pet--current (plist-put (copy-sequence harness-ui-pet--current) :said (list work recap))))
      (should (eq recap (harness-ui-pet--latest-saying (+ now 3) 'board '("s1"))))
      (should-not (harness-ui-pet--latest-saying (+ now 3) 'board '("s2")))
      (should (eq work (harness-ui-pet--saying-for "s1" (+ now 3)))))
    ;; Hovering a face: what its bubble there would say.
    (with-temp-buffer
      (should (eq own (harness-ui-pet--last-in nil)))
      (should (eq own (harness-ui-pet--last-in (current-buffer)))))))

(ert-deftest harness-ui-pet-places-say-where-it-sits ()
  "The places option offers the session list, on by default, and says where
the pet stands in chats; its buffer says where it speaks."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (let* ((type (get 'harness-ui-pet-places 'custom-type))
         (consts (cdr type)))
    (should (eq 'set (car type)))
    (should (equal '(chat board sessions chat-header board-header) (mapcar (lambda (c) (car (last c))) consts)))
    (should (equal "The creature under the session list" (plist-get (cdr (nth 2 consts)) :tag)))
    ;; Chat: on whatever comes first below the transcript, no longer just by its box.
    (should (string-search "whatever is first below" (plist-get (cdr (nth 0 consts)) :tag)))
    (should (equal '(chat board sessions) (eval (car (get 'harness-ui-pet-places 'standard-value))))))
  (dolist (case '(((chat board sessions)
                   . "here, about itself; beside a chat, about that chat's session; on the task board and the session list, about itself and in recaps of the sessions they list")
                  ((chat board)
                   . "here, about itself; beside a chat, about that chat's session; on the task board, about itself and in recaps of the sessions it lists")
                  ((chat sessions)
                   . "here, about itself; beside a chat, about that chat's session; on the session list, about itself and in recaps of the sessions it lists")
                  ((board sessions)
                   . "here, about itself; on the task board and the session list, about itself and in recaps of the sessions they list")
                  ((sessions) . "here, about itself; on the session list, about itself and in recaps of the sessions it lists")
                  ((board) . "here, about itself; on the task board, about itself and in recaps of the sessions it lists")
                  ((chat) . "here, about itself; beside a chat, about that chat's session")
                  ((chat-header board-header) . "here, about itself")
                  (nil . "here, about itself")))
    (let ((harness-ui-pet-places (car case)))
      (should (equal (cdr case) (harness-ui-pet--where-it-speaks)))))
  ;; How long a saying stays in its bubble, when it goes at all.
  (dolist (case '((60 . "What it says leaves its bubble after a minute.")
                  (120 . "What it says leaves its bubble after 2 minutes.")
                  (30 . "What it says leaves its bubble after 30 seconds.")
                  (1 . "What it says leaves its bubble after a second.")
                  (2.5 . "What it says leaves its bubble after 2.5 seconds.")
                  (nil . nil)
                  (0 . nil)))
    (let ((harness-ui-pet-saying-lifetime (car case)))
      (should (equal (cdr case) (harness-ui-pet--lifetime-text))))))

(provide 'harness-ui-pet-test)
;;; harness-ui-pet-test.el ends here
