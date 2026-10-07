;;; harness-ui-pet.el --- The companion pet's buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer, "*harness pet*", opened with `harness-pet' (C-c h z, or
;; z in the harness menu), shows the companion pet of the pet module:
;;
;;   header line   [Pet] [Rename] [Mute] [Release], g and q; [Hatch]
;;                 while there is only an egg
;;   card          its stars, rarity and species, then the creature
;;                 itself in its rarity's colour beside its five stats,
;;                 its name (gold when it is shiny) and personality,
;;                 its level and experience, and what it said last, on
;;                 a band of its own, with when and about which session
;;   footer        the model it speaks with, and whether it may
;;
;; Before it hatches, the buffer shows the egg and a [Hatch] button.
;;
;; The pet only speaks while this buffer is on screen: the buffer tells
;; the harness (`pet/watch') whenever it comes into view or leaves it,
;; through `window-buffer-change-functions' while the buffer lives.
;;
;; Nothing here runs while nothing happens.  Three short animations
;; play when something does -- the egg wobbles and cracks as it hatches,
;; hearts rise when it is petted, and it fidgets as it speaks -- each a
;; run of a few frames on a timer that stops on its own, and stops at
;; once when the buffer leaves the screen.  `harness-ui-pet-animations'
;; turns them off.  What the buffer shows comes from `pet/changed' and
;; `pet/said' events; times are as of the last redraw.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'svg)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defgroup harness-ui-pet nil
  "The companion pet's buffer." :group 'harness-ui)

(defcustom harness-ui-pet-animations t
  "Whether the companion pet moves.
The egg wobbles and cracks as it hatches, hearts rise when it is
petted, and it fidgets as it speaks: each a few frames that stop on
their own.  nil shows it still."
  :type 'boolean :group 'harness-ui-pet)

(defconst harness-ui-pet--buffer-name "*harness pet*"
  "Name of the pet's buffer.")

(defconst harness-ui-pet--tick 0.18
  "Seconds between two frames of an animation.")

(defconst harness-ui-pet--wobble-ticks 10
  "Frames the egg wobbles at least before it cracks.")

(defconst harness-ui-pet--stats-column 24
  "Column the stats start at, beside the creature.")

;;;; Faces

(defface harness-pet-common-face
  '((((background dark)) :foreground "#a3a3a3") (t :foreground "#737373"))
  "A common pet's colour." :group 'harness-ui-pet)
(defface harness-pet-uncommon-face
  '((((background dark)) :foreground "#4ade80") (t :foreground "#16a34a"))
  "An uncommon pet's colour." :group 'harness-ui-pet)
(defface harness-pet-rare-face
  '((((background dark)) :foreground "#60a5fa") (t :foreground "#2563eb"))
  "A rare pet's colour." :group 'harness-ui-pet)
(defface harness-pet-epic-face
  '((((background dark)) :foreground "#a78bfa") (t :foreground "#7c3aed"))
  "An epic pet's colour." :group 'harness-ui-pet)
(defface harness-pet-legendary-face
  '((((background dark)) :foreground "#facc15") (t :foreground "#ca8a04"))
  "A legendary pet's colour." :group 'harness-ui-pet)

(defface harness-pet-art-face '((t :inherit fixed-pitch :height 1.25))
  "The creature itself, drawn in its rarity's colour on top." :group 'harness-ui-pet)
(defface harness-pet-name-face '((t :inherit bold :height 1.5))
  "The pet's name." :group 'harness-ui-pet)
(defface harness-pet-shiny-face
  '((((background dark)) :foreground "#fbbf24") (t :foreground "#b45309"))
  "The name and badge of a shiny pet." :group 'harness-ui-pet)
(defface harness-pet-personality-face '((t :inherit (italic shadow)))
  "The pet's personality." :group 'harness-ui-pet)
(defface harness-pet-stat-face '((t :inherit (shadow) :height 0.9))
  "The names of the stats." :group 'harness-ui-pet)
(defface harness-pet-speech-face
  '((((background dark)) :background "#262630" :extend t)
    (t :background "#f2f2f6" :extend t))
  "The band what the pet said last shows on." :group 'harness-ui-pet)
(defface harness-pet-action-face '((t :inherit (italic shadow)))
  "What the pet does as it speaks, *like this*." :group 'harness-ui-pet)
(defface harness-pet-heart-face
  '((((background dark)) :foreground "#f472b6") (t :foreground "#db2777"))
  "The hearts that rise when the pet is petted." :group 'harness-ui-pet)

(defun harness-ui-pet--rarity-face (rarity)
  "The face of RARITY, a string."
  (pcase rarity
    ("uncommon" 'harness-pet-uncommon-face)
    ("rare" 'harness-pet-rare-face)
    ("epic" 'harness-pet-epic-face)
    ("legendary" 'harness-pet-legendary-face)
    (_ 'harness-pet-common-face)))

(defun harness-ui-pet--color (face)
  "The foreground colour of FACE, as SVG takes it."
  (let ((c (face-attribute face :foreground nil t)))
    (if (and (stringp c) (not (equal c "unspecified"))) c "#888888")))

;;;; The art

(defconst harness-ui-pet--sprites
  '((duck
     ("" "    __" "  <({E} )___" "   ( ._> /" "    `---'")
     ("" "    __" "  =({E} )___" "   ( ._> /" "    `---'")
     ("" "    __" "  <({E} )___" "   ( .-> /" "    `---'"))
    (goose
     ("" "   ({E}>" "    ) \\" "  _/   \\_" " (_______)")
     ("" "   ({E}>" "    ( \\" "  _/   \\_" " (_______)")
     ("" "   ({E}>>" "    ) \\" "  _/   \\_" " (_______)"))
    (blob
     ("" "   .----." "  ( {E}  {E} )" "  (   ~  )" "   `----'")
     ("" "  .------." " (  {E}  {E}  )" " (    ~   )" "  `------'")
     ("" "    .--." "   ({E}  {E})" "   ( ~~ )" "    `--'"))
    (cat
     ("" "   /\\_/\\" "  ( {E}.{E} )" "   > ^ <" "  (\")_(\")")
     ("" "   /\\_/\\" "  ( {E}.{E} )" "   > ^ <" "  (\")_(\")~")
     ("" "   /\\_/\\" "  ( {E}.{E} )" "   > o <" "  (\")_(\")"))
    (dragon
     ("" "  /\\    /\\" " (  {E}  {E}  )" "  \\ ~~~~ /~~" "   `vvvv'")
     ("" "  /\\    /\\" " (  {E}  {E}  )" "  \\ ~~~~ /~" "   `vvvv'~")
     ("   ~   ~" "  /\\    /\\" " (  {E}  {E}  )" "  \\ ~~~~ /~~" "   `vvvv'"))
    (octopus
     ("" "   .----." "  ( {E}  {E} )" "  (  ~~  )" "  ////\\\\\\\\")
     ("" "   .----." "  ( {E}  {E} )" "  (  ~~  )" "  \\\\\\\\////")
     ("      o" "   .----." "  ( {E}  {E} )" "  (  ~~  )" "  ////\\\\\\\\"))
    (owl
     ("" "   ^    ^" "  {({E})({E})}" "  (  \\/  )" "   -m--m-")
     ("" "   ^    ^" "  {({E})({E})}" "  (  \\/  )" "   m-  -m")
     ("" "   ^    ^" "  {({E})({E})}" "  (  ()  )" "   -m--m-"))
    (penguin
     ("" "   ({E}v{E})" "  /(   )\\" "   (   )" "   ^^ ^^")
     ("" "   ({E}v{E})" "  |(   )|" "   (   )" "   ^^ ^^")
     ("" "   ({E}v{E})" "  /(   )\\" "   (   )" "  ^^   ^^"))
    (turtle
     ("" "    _____" "  _/#####\\" " ({E}_#####_)" "   ''   ''")
     ("" "    _____" "  _/#####\\" " ({E}_#####_)" "    '' ''")
     ("" "    _____" "   /#####\\" "  [_#####_]" "   ''   ''"))
    (snail
     ("" " {E}  {E}  .--." "  \\/  ( @ )" "  (____`-'_)" "  ~~~~~~~~~")
     ("" "  {E}  {E} .--." "   \\/ ( @ )" "  (____`-'_)" "   ~~~~~~~~")
     ("" " {E}  {E}  .--." "  \\/  ( @ )" "  (____`-'_)" " ~~~~~~~~~~"))
    (ghost
     ("" "   .-\"\"-." "  / {E}  {E} \\" "  |   o  |" "  `v^vv^v'")
     ("" "   .-\"\"-." "  / {E}  {E} \\" "  |   o  |" "  'v^v^v^`")
     ("  ~ boo ~" "   .-\"\"-." "  / {E}  {E} \\" "  |   O  |" "  `v^vv^v'"))
    (axolotl
     ("" " \\\\(______)//" "  =( {E}  {E} )=" " //(  ww  )\\\\" "    U    U")
     ("" " //(______)\\\\" "  =( {E}  {E} )=" " \\\\(  ww  )//" "    U    U")
     ("" " \\\\(______)//" "  =( {E}  {E} )=" " //(  oo  )\\\\" "     U  U"))
    (capybara
     ("" "  n______n" " ( {E}    {E} )" " (   oo   )" "  `------'")
     ("" "  n______n" " ( {E}    {E} )" " (   oO   )" "  `------'")
     ("    z  z" "  n______n" " ( -    - )" " (   oo   )" "  `------'"))
    (cactus
     ("" "    ____" " ,-|{E}  {E}|-," " `-|    |-'" "   |____|")
     ("" " ,  ____  ," " |-|{E}  {E}|-|" "   |    |" "   |____|")
     ("    .*." "    ____" " ,-|{E}  {E}|-," " `-|    |-'" "   |____|"))
    (robot
     ("" "      T" "  .------." "  | {E}  {E} |" "  |_[==]_|")
     ("" "      Y" "  .------." "  | {E}  {E} |" "  |_[--]_|")
     ("      *" "      T" "  .------." "  | {E}  {E} |" "  |_[==]_|"))
    (rabbit
     ("" "   (\\(\\" "   ( {E}.{E})" "   o_(\")(\")" "")
     ("" "    /)/)" "   ( {E}.{E})" "   o_(\")(\")" "")
     ("" "   (\\(\\" "   ( {E}w{E})" "   o_(\")(\")" ""))
    (mushroom
     ("" "   .-o-*-." "  (_*___o_)" "    |{E} {E}|" "    |___|")
     ("" "   .-*-o-." "  (_o___*_)" "    |{E} {E}|" "    |___|")
     ("   .  '  ." "   .-o-*-." "  (_*___o_)" "    |{E} {E}|" "    |___|"))
    (chonk
     ("" "  /\\_____/\\" " (  {E}   {E}  )" " (    w    )" "  `-------'")
     ("" "  /\\_____/|" " (  {E}   {E}  )" " (    w    )" "  `-------'")
     ("" "  /\\_____/\\" " (  {E}   {E}  )" " (    w    )" "  `-------'~")))
  "Each species's three frames: five lines each, {E} for its eyes.
The first line is where a hat goes; a frame may draw something else
there instead.")

(defconst harness-ui-pet--hats
  '((crown . "\\^^^/")
    (tophat . "_|=|_")
    (propeller . "-+-")
    (halo . "(   )")
    (wizard . "/*\\")
    (beanie . "(___)")
    (tinyduck . "<o)"))
  "What each hat looks like, on the first line of a frame.")

(defconst harness-ui-pet--heads
  '((duck . 4.5) (goose . 4) (blob . 5.5) (cat . 5) (dragon . 5.5) (octopus . 5.5)
    (owl . 5.5) (penguin . 5) (turtle . 6) (snail . 2.5) (ghost . 5.5) (axolotl . 6.5)
    (capybara . 5.5) (cactus . 5.5) (robot . 6) (rabbit . 4.5) (mushroom . 6) (chonk . 6))
  "The column each species's head is centred on, where its hat goes.")

(defconst harness-ui-pet--egg
  '("     .--." "    /    \\" "   |      |" "   |      |" "    \\    /" "     `--'")
  "The egg, before it hatches.")

(defconst harness-ui-pet--cracks
  '(("     .--." "    /    \\" "   |  .   |" "   |      |" "    \\    /" "     `--'")
    ("     .--." "    /    \\" "   | ./\\  |" "   |   '  |" "    \\    /" "     `--'")
    ("     .--." "    /\\/\\/\\" "   |  '   |" "   |      |" "    \\    /" "     `--'")
    ("  \\  .--.  /" "    /\\/\\/\\" "   |      |" "   |      |" "    \\    /" "     `--'"))
  "The egg cracking, frame by frame.")

(defconst harness-ui-pet--hearts
  '("     ♥   ♥" "   ♥   ♥    ♥" "  ♥  ♥   ♥" " ♥     ♥    ♥" "  ·   ·    ·")
  "Hearts rising above a petted pet, frame by frame.")

(defconst harness-ui-pet--sparkles
  '("   *   .   *" "  .  *   .  *" " *   .  *   ." "  .    .    .")
  "Sparkles around a pet that just hatched, frame by frame.")

(defconst harness-ui-pet--fidget '(1 2 1 0 2 0)
  "The frames a pet goes through as it speaks.")

(defconst harness-ui-pet--hatching-words
  '("warming the shell" "counting toes" "rolling for rarity" "picking a hat"
    "untangling whiskers" "consulting the stars" "practising a first word"
    "polishing the eyes" "stretching" "thinking of a name")
  "What the egg is up to while it hatches.")

(defconst harness-ui-pet--eye-fallbacks
  '(("·" . ".") ("✦" . "*") ("×" . "x") ("◉" . "o") ("°" . "o"))
  "Eyes to draw instead of those the creature's font lacks, so it stays aligned.")

(defun harness-ui-pet--has-glyph-p (char)
  "Non-nil when the creature's font draws CHAR in the selected frame."
  (if (display-graphic-p)
      (condition-case nil
          (let ((font (face-font 'harness-pet-art-face nil char)))
            (and font
                 (let ((ascii (face-font 'harness-pet-art-face)))
                   ;; Drawn by the font of the letters, so as wide as they are.
                   (or (equal font ascii)
                       (let ((entity (and ascii (find-font (font-spec :name ascii)))))
                         (and entity (font-has-char-p entity char)))))))
        (error t))
    (char-displayable-p char)))

(defun harness-ui-pet--eye (eye)
  "EYE as the creature is drawn with: a fallback when its font lacks it."
  (if (or (not (stringp eye)) (string-empty-p eye))
      "o"
    (if (harness-ui-pet--has-glyph-p (aref eye 0))
        eye
      (or (cdr (assoc eye harness-ui-pet--eye-fallbacks)) "o"))))

(defun harness-ui-pet-art (species eye hat &optional frame)
  "Return the lines of a SPECIES pet with EYE and HAT, in FRAME (default 0).
SPECIES and HAT are names, as strings or symbols; EYE a string.  Always
five lines, the first the hat's."
  (let* ((species (intern (format "%s" species)))
         (frames (or (cdr (assq species harness-ui-pet--sprites))
                     (cdr (assq 'blob harness-ui-pet--sprites))))
         (lines (nth (mod (or frame 0) (length frames)) frames))
         (hat-line (when-let* ((h (cdr (assq (intern (format "%s" (or hat "none"))) harness-ui-pet--hats))))
                     (concat (make-string (max 0 (floor (+ (alist-get species harness-ui-pet--heads 5.5)
                                                           (- (/ (1- (length h)) 2.0)) 0.5)))
                                          ?\s)
                             h))))
    (cl-loop for line in lines
             for i from 0
             collect (if (and (= i 0) hat-line (string-blank-p line))
                         hat-line
                       (string-replace "{E}" eye line)))))

;;;; State

(defvar-local harness-ui-pet--view nil "The pet as `pet/get' returned it last.")
(defvar-local harness-ui-pet--error nil "Why the pet could not be shown, or nil.")
(defvar-local harness-ui-pet--anim nil
  "The animation playing: (:kind KIND :tick N), or nil.
KIND is `egg', `crack', `sparkle', `hearts' or `fidget'.")
(defvar-local harness-ui-pet--width 80 "The columns the buffer was last drawn for.")
(defvar-local harness-ui-pet--queued nil
  "The animation to play once the egg has hatched, or nil: `fidget'.")

(defvar harness-ui-pet--timer nil "The timer of the animation playing, or nil.")
(defvar harness-ui-pet--watching nil "Whether this Emacs last told the harness it shows the pet.")
(defvar harness-ui-pet--bars (make-hash-table :test 'equal)
  "Stat bar images by (FRACTION WIDTH COLOR), so a redraw reuses them.")

(defun harness-ui-pet--buffer ()
  "The pet's buffer, or nil."
  (get-buffer harness-ui-pet--buffer-name))

(defun harness-ui-pet--true-p (value)
  "Non-nil when VALUE, from the wire, is true."
  (and value (not (eq value :false))))

(defun harness-ui-pet--hatched-p (&optional view)
  "Non-nil when VIEW (default the buffer's) is of a pet that hatched."
  (harness-ui-pet--true-p (plist-get (or view harness-ui-pet--view) :hatched)))

;;;; Visibility

(defun harness-ui-pet--client-id ()
  "The id this Emacs tells the harness it shows the pet under."
  (format "%s:%d" (system-name) (emacs-pid)))

(defun harness-ui-pet--shown-p ()
  "Non-nil when the pet's buffer is in a window on screen.
On any frame of any terminal: a timer or a process filter may run with
a frame of another terminal selected, as in a daemon."
  (when-let* ((buf (harness-ui-pet--buffer)))
    (and (cl-some (lambda (w) (eq t (frame-visible-p (window-frame w))))
                  (get-buffer-window-list buf 'nomini t))
         t)))

(defun harness-ui-pet--send-watch (shown)
  "Tell the harness this Emacs SHOWN the pet or not; draw the pet it answers with."
  (setq harness-ui-pet--watching shown)
  (harness-ui-call "_harness/pet/watch"
                   (list :client (harness-ui-pet--client-id) :on (if shown t :false))
                   (lambda (view) (when shown (harness-ui-pet--receive view)) nil)
                   #'harness-ui-pet--failed))

(defun harness-ui-pet--update-watch (&rest _)
  "Tell the harness whether the pet is on screen, when that changed.
In `window-buffer-change-functions' while the pet's buffer lives."
  (let ((shown (harness-ui-pet--shown-p)))
    (unless (eq shown harness-ui-pet--watching)
      (harness-ui-pet--send-watch shown))
    (unless shown (harness-ui-pet--stop))))

(defun harness-ui-pet--on-resize (window)
  "Draw the pet's buffer again when WINDOW, which shows it, changed width.
In the buffer's `window-size-change-functions', which redisplay runs
only when a window showing it changed size."
  (with-current-buffer (window-buffer window)
    (unless (eql (harness-ui-pet--window-width) harness-ui-pet--width)
      (harness-ui-pet--render))))

(defun harness-ui-pet--on-kill ()
  "The pet's buffer goes: the pet is not on screen any more."
  (remove-hook 'window-buffer-change-functions #'harness-ui-pet--update-watch)
  (harness-ui-pet--stop)
  (when harness-ui-pet--watching
    (harness-ui-pet--send-watch nil)))

;;;; Talking to the harness

(defun harness-ui-pet--failed (err)
  "Show ERR, from a request about the pet, in its buffer."
  (unless (harness-ui-connection-replaced-p err)
    (let ((text (harness-error-message err)))
      (when-let* ((buf (harness-ui-pet--buffer)))
        (with-current-buffer buf
          (setq harness-ui-pet--error
                (if (string-match-p "pet/\\|[Mm]ethod not found\\|No such harness method" text)
                    "The harness has no pet: its pet module is off or missing."
                  text))
          (harness-ui-pet--stop)
          (harness-ui-pet--render)))
      (message "Harness: the pet: %s" text)))
  nil)

(defun harness-ui-pet--receive (view)
  "Show VIEW, the pet as `pet/get' returns it."
  (when-let* ((buf (harness-ui-pet--buffer)))
    (with-current-buffer buf
      (let ((was harness-ui-pet--view))
        (setq harness-ui-pet--view view harness-ui-pet--error nil)
        (cond
         ;; Hatching, here or in another Emacs: the egg wobbles.
         ((and (harness-ui-pet--true-p (plist-get view :hatching))
               (not (memq (plist-get harness-ui-pet--anim :kind) '(egg crack))))
          (harness-ui-pet--animate 'egg))
         ;; Hatched with nobody watching the egg: sparkles all the same.
         ((and was (not (harness-ui-pet--hatched-p was)) (harness-ui-pet--hatched-p view)
               (not harness-ui-pet--anim))
          (harness-ui-pet--animate 'sparkle)))
        (harness-ui-pet--render))))
  nil)

(defun harness-ui-pet--request (method &optional params)
  "Send METHOD with PARAMS about the pet; show the pet it answers with."
  (harness-ui-call method params #'harness-ui-pet--receive #'harness-ui-pet--failed))

(defun harness-ui-pet--on-event (event args)
  "Follow the pet through EVENT with ARGS."
  (when (harness-ui-pet--buffer)
    (pcase event
      ("pet/changed" (harness-ui-pet--receive (car args)))
      ("pet/said" (with-current-buffer (harness-ui-pet--buffer)
                    ;; Its first words come as it hatches: it fidgets after.
                    (if (memq (plist-get harness-ui-pet--anim :kind) '(egg crack sparkle))
                        (setq harness-ui-pet--queued 'fidget)
                      (harness-ui-pet--animate 'fidget))))
      ("config/changed"
       (when (string-prefix-p "harness-pet-" (format "%s" (car args)))
         (harness-ui-pet--request "_harness/pet/get"))))))

(defun harness-ui-pet--on-connected ()
  "The harness may have restarted: tell it again whether the pet is on screen."
  (when (harness-ui-pet--buffer)
    (setq harness-ui-pet--watching nil)
    (if (harness-ui-pet--shown-p)
        (harness-ui-pet--send-watch t)
      (harness-ui-pet--request "_harness/pet/get"))))

(defun harness-ui-pet--redraw ()
  "Redraw the pet's buffer, as every view redraws after a reload."
  (when-let* ((buf (harness-ui-pet--buffer)))
    (with-current-buffer buf (harness-ui-pet--render))))

;;;; Animation

(defun harness-ui-pet--animate (kind)
  "Play animation KIND in the pet's buffer, the current buffer."
  (when (and harness-ui-pet-animations (harness-ui-pet--shown-p))
    (setq harness-ui-pet--anim (list :kind kind :tick 0))
    (unless (timerp harness-ui-pet--timer)
      (setq harness-ui-pet--timer
            (run-at-time harness-ui-pet--tick harness-ui-pet--tick #'harness-ui-pet--step)))))

(defun harness-ui-pet--stop ()
  "Stop the animation playing, if any."
  (when (timerp harness-ui-pet--timer) (cancel-timer harness-ui-pet--timer))
  (setq harness-ui-pet--timer nil)
  (when-let* ((buf (harness-ui-pet--buffer)))
    (with-current-buffer buf
      (setq harness-ui-pet--queued nil)
      (when harness-ui-pet--anim
        (setq harness-ui-pet--anim nil)
        (harness-ui-pet--render)))))

(defun harness-ui-pet--next (anim)
  "The animation after a frame of ANIM: ANIM a tick on, another, or nil."
  (let ((kind (plist-get anim :kind))
        (tick (1+ (plist-get anim :tick))))
    (pcase kind
      ('egg (if (and (>= tick harness-ui-pet--wobble-ticks)
                     (not (harness-ui-pet--true-p (plist-get harness-ui-pet--view :hatching))))
                (if (harness-ui-pet--hatched-p) (list :kind 'crack :tick 0) nil)
              (list :kind 'egg :tick tick)))
      ('crack (if (< tick (length harness-ui-pet--cracks)) (list :kind 'crack :tick tick)
                (list :kind 'sparkle :tick 0)))
      ('sparkle (and (< tick (length harness-ui-pet--sparkles)) (list :kind 'sparkle :tick tick)))
      ('hearts (and (< tick (length harness-ui-pet--hearts)) (list :kind 'hearts :tick tick)))
      ('fidget (and (< tick (length harness-ui-pet--fidget)) (list :kind 'fidget :tick tick))))))

(defun harness-ui-pet--step ()
  "Show the next frame of the animation playing; stop at its end."
  (let ((buf (harness-ui-pet--buffer)))
    (if (not (and buf (buffer-local-value 'harness-ui-pet--anim buf) (harness-ui-pet--shown-p)))
        (harness-ui-pet--stop)
      (with-current-buffer buf
        (setq harness-ui-pet--anim
              (or (harness-ui-pet--next harness-ui-pet--anim)
                  (when harness-ui-pet--queued
                    (prog1 (list :kind harness-ui-pet--queued :tick 0)
                      (setq harness-ui-pet--queued nil)))))
        (unless harness-ui-pet--anim
          (when (timerp harness-ui-pet--timer) (cancel-timer harness-ui-pet--timer))
          (setq harness-ui-pet--timer nil))
        (harness-ui-pet--render)))))

;;;; Drawing

(defun harness-ui-pet--graphic-p ()
  "Non-nil when SVG can be shown in the buffer's frame."
  (let ((win (get-buffer-window (current-buffer) t)))
    (and (display-graphic-p (if win (window-frame win) (selected-frame)))
         (image-type-available-p 'svg))))

(defun harness-ui-pet--bar (fraction width color)
  "A bar image showing FRACTION of WIDTH pixels filled with COLOR."
  (let ((key (list (/ (round (* 1000 fraction)) 1000.0) width color)))
    (or (gethash key harness-ui-pet--bars)
        (puthash key
                 (let* ((h 8)
                        (svg (svg-create width h))
                        (fill (max 0 (min width (* width (max 0.0 (min 1.0 fraction)))))))
                   (svg-rectangle svg 0 0 width h :rx 3 :fill color :fill-opacity 0.18)
                   (when (> fill 0) (svg-rectangle svg 0 0 (max fill 3) h :rx 3 :fill color))
                   (svg-image svg :ascent 'center :scale 1))
                 harness-ui-pet--bars))))

(defun harness-ui-pet--meter (fraction face cols help)
  "A meter for FRACTION in FACE's colour, COLS wide, with tooltip HELP."
  (if (harness-ui-pet--graphic-p)
      (propertize (make-string cols ?\s)
                  'display (harness-ui-pet--bar fraction (* cols (frame-char-width)) (harness-ui-pet--color face))
                  'help-echo help)
    (let ((filled (round (* cols (max 0.0 (min 1.0 fraction))))))
      (concat (propertize (make-string filled ?█) 'face face 'help-echo help)
              (propertize (make-string (- cols filled) ?░) 'face 'harness-dim-face 'help-echo help)))))

(defun harness-ui-pet--align (column)
  "A space reaching COLUMN."
  (propertize " " 'display `(space :align-to ,column)))

(defun harness-ui-pet--art-line (text face)
  "TEXT, a line of the creature, in FACE at the creature's size.
A face TEXT has already, such as the hearts', stays on top."
  (let ((text (copy-sequence text)))
    (add-face-text-property 0 (length text) (list face 'harness-pet-art-face) t text)
    text))

(defun harness-ui-pet--speech (text)
  "TEXT, something the pet said, with what it does *like this* set apart."
  (let ((out "") (start 0))
    (while (string-match "\\*\\([^*\n]+\\)\\*" text start)
      (setq out (concat out (substring text start (match-beginning 0))
                        (propertize (match-string 1 text) 'face 'harness-pet-action-face))
            start (match-end 0)))
    (string-trim (concat out (substring text start)))))

(defun harness-ui-pet--when (saying)
  "When SAYING was said, and about which session.
The session goes by the name it has now when it had none yet then."
  (let* ((ts (plist-get saying :ts))
         (sid (plist-get saying :session))
         (name (or (harness-ui-pet--name (plist-get saying :session-name))
                   (and (stringp sid) (harness-ui-pet--name (plist-get (harness-ui-session sid) :name))))))
    (string-join (delq nil (list (and (numberp ts) (harness-relative-time ts))
                                 (and name (format "about %s" name))))
                 ", ")))

(defun harness-ui-pet--name (name)
  "NAME, a session's name from the wire, or nil when it has none."
  (and (stringp name) (not (string-blank-p name)) name))

(defun harness-ui-pet--window-width ()
  "Columns the pet's buffer, the current buffer, is drawn in: its window's."
  (let ((win (get-buffer-window (current-buffer) t)))
    (if win (window-body-width win) 80)))

(defun harness-ui-pet--insert-filled (text &optional face)
  "Insert TEXT, filled to the window and indented by two columns, in FACE.
FACE goes under the faces TEXT has, and covers the indentation too."
  (let ((start (point)))
    (insert "  " text "\n")
    (let ((fill-column (max 30 (min 72 (- harness-ui-pet--width 2))))
          (fill-prefix "  "))
      (fill-region start (point)))
    (when face (add-face-text-property start (point) face t))))

(defun harness-ui-pet--insert-egg ()
  "Insert the egg, wobbling or cracking as the animation says."
  (let* ((view harness-ui-pet--view)
         (anim harness-ui-pet--anim)
         (tick (or (plist-get anim :tick) 0))
         (hatching (or (harness-ui-pet--true-p (plist-get view :hatching))
                       (memq (plist-get anim :kind) '(egg crack))))
         (lines (if (eq (plist-get anim :kind) 'crack)
                    (nth (min tick (1- (length harness-ui-pet--cracks))) harness-ui-pet--cracks)
                  harness-ui-pet--egg))
         (shift (if (eq (plist-get anim :kind) 'egg) (nth (mod tick 4) '(0 1 0 -1)) 0))
         (model (plist-get view :model)))
    (insert "  " (propertize "An egg" 'face 'harness-pet-name-face) "\n\n")
    (dolist (line lines)
      (insert "  " (harness-ui-pet--art-line
                    (cond ((> shift 0) (concat (make-string shift ?\s) line))
                          ((< shift 0) (substring line (min (length line) (- shift))))
                          (t line))
                    'harness-pet-common-face)
              "\n"))
    (insert "\n")
    (if hatching
        (insert "  " (propertize (concat "Hatching: "
                                         (nth (mod (/ tick 4) (length harness-ui-pet--hatching-words))
                                              harness-ui-pet--hatching-words)
                                         "…")
                                 'face 'harness-dim-face)
                "\n")
      (insert "  Something inside is moving.  ")
      (harness-ui-button "Hatch it" #'harness-ui-pet-hatch :help "Hatch the egg (h)")
      (insert "\n\n")
      (harness-ui-pet--insert-filled
       (format "It hatches into one of 18 species, common to legendary, with five stats and a personality%s. Then it keeps you company: now and then, while this buffer is open, it has something to say about your work."
               (if (stringp model) (format " that %s gives it" (harness-ui-model-label model)) ""))
       'harness-dim-face))))

(defconst harness-ui-pet--stat-names '(debugging patience chaos wisdom snark)
  "The stats, in the order the card shows them.")

(defconst harness-ui-pet--stats-width 35
  "Columns a row of stats takes: its name, its meter and its value.")

(defun harness-ui-pet--insert-stats (view face row column)
  "Insert stat ROW of VIEW at COLUMN, in FACE's colour."
  (when-let* ((name (nth row harness-ui-pet--stat-names)))
    (let* ((value (or (plist-get (plist-get view :stats) (intern (format ":%s" name))) 0))
           (help (format "%s %d of 100" (upcase (symbol-name name)) value)))
      (insert (harness-ui-pet--align column)
              (propertize (format "%-10s" (upcase (symbol-name name))) 'face 'harness-pet-stat-face 'help-echo help)
              " "
              (harness-ui-pet--meter (/ value 100.0) face 20 help)
              " "
              (propertize (format "%3d" value) 'help-echo help)))))

(defun harness-ui-pet--insert-pet ()
  "Insert the pet's card."
  (let* ((view harness-ui-pet--view)
         (anim harness-ui-pet--anim)
         (kind (plist-get anim :kind))
         (tick (or (plist-get anim :tick) 0))
         (rarity (or (plist-get view :rarity) "common"))
         (face (harness-ui-pet--rarity-face rarity))
         (stars (or (plist-get view :stars) 1))
         (shiny (harness-ui-pet--true-p (plist-get view :shiny)))
         (frame (if (eq kind 'fidget) (nth tick harness-ui-pet--fidget) 0))
         (art (harness-ui-pet-art (plist-get view :species) (harness-ui-pet--eye (plist-get view :eye))
                                  (plist-get view :hat) frame))
         (above (pcase kind
                  ('hearts (propertize (nth tick harness-ui-pet--hearts) 'face 'harness-pet-heart-face))
                  ('sparkle (propertize (nth tick harness-ui-pet--sparkles) 'face face))
                  (_ "")))
         (said (plist-get view :said))
         (last (car (last said)))
         (level (or (plist-get view :level) 1))
         (xp (or (plist-get view :xp) 0))
         (from (or (plist-get view :level-xp) 0))
         (to (or (plist-get view :next-xp) 10))
         (pets (or (plist-get view :pets) 0)))
    ;; Stars, rarity, species.
    (insert "  " (propertize (make-string stars ?★) 'face face)
            (propertize (make-string (- 5 stars) ?☆) 'face 'harness-dim-face)
            "  " (propertize (upcase rarity) 'face (list 'bold face))
            "  " (propertize (upcase (format "%s" (plist-get view :species))) 'face 'harness-dim-face)
            "\n")
    ;; The creature, its stats beside it, or below it in a narrow window.
    (let ((beside (>= harness-ui-pet--width (+ harness-ui-pet--stats-column harness-ui-pet--stats-width 1))))
      (insert "  " (harness-ui-pet--art-line above face) "\n")
      (cl-loop for line in art
               for row from 0
               do (insert "  " (harness-ui-pet--art-line line face))
               (when beside (harness-ui-pet--insert-stats view face row harness-ui-pet--stats-column))
               (insert "\n"))
      (unless beside
        (insert "\n")
        (dotimes (row (length harness-ui-pet--stat-names))
          (harness-ui-pet--insert-stats view face row 2)
          (insert "\n"))))
    (insert "\n")
    ;; Name and personality.
    (insert "  " (propertize (or (plist-get view :name) "?")
                             'face (if shiny '(harness-pet-shiny-face harness-pet-name-face) 'harness-pet-name-face)))
    (when shiny
      (insert "  " (propertize "SHINY" 'face '(harness-pet-shiny-face harness-label-face)
                               'help-echo "One pet in a hundred is shiny")))
    (insert "\n")
    (unless (string-blank-p (or (plist-get view :personality) ""))
      (harness-ui-pet--insert-filled (plist-get view :personality) 'harness-pet-personality-face))
    (insert "\n")
    ;; Growing.
    (insert "  " (propertize (format "Level %d" level) 'face 'bold) "  "
            (harness-ui-pet--meter (/ (float (- xp from)) (max 1 (- to from))) face 12
                                   (format "%d of the %d experience level %d takes" xp to (1+ level)))
            "  " (propertize (format "%d / %d xp" xp to) 'face 'harness-dim-face)
            (propertize (if (> pets 0) (format "   petted %d time%s" pets (if (= pets 1) "" "s")) "")
                        'face 'harness-dim-face)
            "\n\n")
    ;; What it said last, on a band of its own, and before.
    (let ((thinking (harness-ui-pet--true-p (plist-get view :thinking))))
      (harness-ui-pet--insert-filled
       (cond (thinking (propertize "…" 'face 'harness-dim-face))
             (last (harness-ui-pet--speech (plist-get last :text)))
             (t (propertize "It has not said anything yet." 'face 'harness-dim-face)))
       'harness-pet-speech-face)
      (when (and last (not thinking))
        (insert "  " (propertize (harness-ui-pet--when last) 'face 'harness-dim-face) "\n"))
      (when-let* ((earlier (and (not thinking) (seq-take (reverse (butlast said)) 2))))
        (insert "\n")
        (dolist (saying earlier)
          (let* ((ago (harness-ui-pet--when saying))
                 (text (harness-ui-pet--speech (harness-ui-one-line (plist-get saying :text))))
                 (room (max 12 (- harness-ui-pet--width 6 (length ago)))))
            (insert "  " (harness-truncate-end text room) "  "
                    (propertize ago 'face 'italic) "\n")
            (add-face-text-property (line-beginning-position 0) (point) 'harness-dim-face t)))))))

(defun harness-ui-pet--footer ()
  "Insert what the pet speaks with, and whether it may."
  (let* ((view harness-ui-pet--view)
         (model (plist-get view :model))
         (text (cond ((not (harness-ui-pet--hatched-p)) nil)
                     ((not (harness-ui-pet--true-p (plist-get view :reactions)))
                      "Quiet: harness-pet-reactions is off, so it asks no model anything.")
                     ((harness-ui-pet--true-p (plist-get view :muted))
                      "Muted: it asks no model anything until you unmute it (m).")
                     (t (format "While this buffer is on screen it now and then has a word to say%s. m mutes it."
                                (if (stringp model) (format ", through %s" (harness-ui-model-label model)) ""))))))
    (when text
      (insert "\n")
      (harness-ui-pet--insert-filled text 'harness-dim-face))))

(defun harness-ui-pet--render ()
  "Draw the pet's buffer, the current buffer, from what it knows."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (column (current-column)))
    (setq harness-ui-pet--width (harness-ui-pet--window-width))
    (erase-buffer)
    (insert "\n")
    (cond
     (harness-ui-pet--error
      (insert "  " (propertize harness-ui-pet--error 'face 'harness-failure-face) "\n"))
     ((null harness-ui-pet--view)
      (insert "  " (propertize "Looking for your pet…" 'face 'harness-dim-face) "\n"))
     ((and (harness-ui-pet--hatched-p) (not (memq (plist-get harness-ui-pet--anim :kind) '(egg crack))))
      (harness-ui-pet--insert-pet)
      (harness-ui-pet--footer))
     (t (harness-ui-pet--insert-egg)))
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    (force-mode-line-update)))

;;;; Header line

(defun harness-ui-pet--segment (label command help)
  "A header-line segment LABEL running COMMAND, with tooltip HELP."
  (propertize (format " %s " label)
              'face 'harness-label-face
              'mouse-face 'mode-line-highlight
              'help-echo help
              'local-map (harness-ui-mouse-keymap command)))

(defun harness-ui-pet--header ()
  "The header line: what can be done with the pet."
  (let* ((view harness-ui-pet--view)
         ;; As drawn: the egg until it has finished cracking.
         (egg (memq (plist-get harness-ui-pet--anim :kind) '(egg crack)))
         (hatched (and (harness-ui-pet--hatched-p) (not egg)))
         (muted (harness-ui-pet--true-p (plist-get view :muted))))
    (harness-ui-fit-header
     (append
      (list (propertize " Companion " 'face '(bold harness-label-face)))
      (if hatched
          (list (list (harness-ui-pet--segment "Pet" #'harness-ui-pet-pet "Pet it (p)") 90)
                (list (harness-ui-pet--segment "Rename" #'harness-ui-pet-rename "Give it another name (r)") 60)
                (list (harness-ui-pet--segment (if muted "Unmute" "Mute") #'harness-ui-pet-toggle-mute
                                               (if muted "Let it speak again (m)" "Keep it quiet: no more model calls (m)"))
                      70)
                (list (harness-ui-pet--segment "Release" #'harness-ui-pet-release "Let it go for good (R)") 40))
        (when (and view (not egg) (not (harness-ui-pet--hatched-p))
                   (not (harness-ui-pet--true-p (plist-get view :hatching))))
          (list (list (harness-ui-pet--segment "Hatch" #'harness-ui-pet-hatch "Hatch the egg (h)") 90))))
      (list (list (concat "  " (harness-ui-pet--segment "g" #'harness-ui-pet-refresh "Refresh")) 50)
            (list (harness-ui-pet--segment "q" #'quit-window "Quit") 55))))))

;;;; Mode and commands

(defvar harness-ui-pet-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "p") #'harness-ui-pet-pet)
    (define-key map (kbd "SPC") #'harness-ui-pet-pet)
    (define-key map (kbd "h") #'harness-ui-pet-hatch)
    (define-key map (kbd "r") #'harness-ui-pet-rename)
    (define-key map (kbd "m") #'harness-ui-pet-toggle-mute)
    (define-key map (kbd "R") #'harness-ui-pet-release)
    (define-key map (kbd "g") #'harness-ui-pet-refresh)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-pet-mode'.")

(define-derived-mode harness-ui-pet-mode special-mode "Pet"
  "Major mode of the companion pet's buffer."
  (setq truncate-lines t
        buffer-read-only t
        header-line-format '(:eval (harness-ui-pet--header)))
  (add-hook 'window-size-change-functions #'harness-ui-pet--on-resize nil t)
  (add-hook 'kill-buffer-hook #'harness-ui-pet--on-kill nil t))

;; The buffer's keys in the harness menu, behind `.'.
(put 'harness-ui-pet-mode 'harness-menu-group
     '("Companion pet"
       ["Pet"
        (". p" "Pet it" harness-ui-pet-pet)
        (". h" "Hatch the egg" harness-ui-pet-hatch)
        (". r" "Rename" harness-ui-pet-rename)
        (". m" "Mute or unmute" harness-ui-pet-toggle-mute)
        (". R" "Release" harness-ui-pet-release)
        (". g" "Refresh" harness-ui-pet-refresh)]))

(defun harness-ui-pet--in-buffer ()
  "Make the pet's buffer current, or complain that it is not open."
  (let ((buf (harness-ui-pet--buffer)))
    (unless buf (user-error "The pet's buffer is not open: M-x harness-pet"))
    (set-buffer buf)))

;;;###autoload
(defun harness-pet ()
  "Show the companion pet, or the egg it hatches from."
  (interactive)
  (let ((buf (get-buffer-create harness-ui-pet--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-pet-mode)
        (harness-ui-pet-mode)))
    (add-hook 'window-buffer-change-functions #'harness-ui-pet--update-watch)
    (harness-ui-display-view buf)
    ;; Drawn once it has its window, to the window's width.
    (with-current-buffer buf (harness-ui-pet--render))
    ;; On screen now, so this asks for the pet as well.
    (setq harness-ui-pet--watching nil)
    (harness-ui-pet--send-watch (harness-ui-pet--shown-p))
    (unless harness-ui-pet--watching
      (harness-ui-pet--request "_harness/pet/get"))))

(defun harness-ui-pet-pet ()
  "Pet the companion."
  (interactive)
  (harness-ui-pet--in-buffer)
  (unless (harness-ui-pet--hatched-p) (user-error "There is only an egg: hatch it first (h)"))
  (harness-ui-pet--animate 'hearts)
  (harness-ui-pet--render)
  (harness-ui-pet--request "_harness/pet/pet"))

(defun harness-ui-pet-hatch ()
  "Hatch the egg."
  (interactive)
  (harness-ui-pet--in-buffer)
  (when (harness-ui-pet--hatched-p) (user-error "It hatched already"))
  (setq harness-ui-pet--view (plist-put (copy-sequence harness-ui-pet--view) :hatching t))
  (harness-ui-pet--animate 'egg)
  (harness-ui-pet--render)
  (harness-ui-pet--request "_harness/pet/hatch"))

(defun harness-ui-pet-rename (name)
  "Give the companion another NAME."
  (interactive
   (progn
     (harness-ui-pet--in-buffer)
     (unless (harness-ui-pet--hatched-p) (user-error "There is only an egg: hatch it first (h)"))
     (list (read-string "Name: " (plist-get harness-ui-pet--view :name)))))
  (harness-ui-pet--request "_harness/pet/rename" (list :name name)))

(defun harness-ui-pet-toggle-mute ()
  "Mute the companion, or let it speak again."
  (interactive)
  (harness-ui-pet--in-buffer)
  (unless (harness-ui-pet--hatched-p) (user-error "There is only an egg: hatch it first (h)"))
  (let ((muted (harness-ui-pet--true-p (plist-get harness-ui-pet--view :muted))))
    (harness-ui-pet--request "_harness/pet/set-muted" (list :muted (if muted :false t)))
    (message "%s" (if muted "It may speak again" "Muted: it asks no model anything"))))

(defun harness-ui-pet-release (&optional force)
  "Let the companion go for good; the next egg hatches another.
Asks first, unless FORCE."
  (interactive)
  (harness-ui-pet--in-buffer)
  (unless (harness-ui-pet--hatched-p) (user-error "There is nothing to release"))
  (when (or force (yes-or-no-p (format "Let %s go for good? " (plist-get harness-ui-pet--view :name))))
    (harness-ui-pet--stop)
    (harness-ui-pet--request "_harness/pet/release")))

(defun harness-ui-pet-refresh ()
  "Ask the harness for the pet again."
  (interactive)
  (harness-ui-pet--in-buffer)
  (harness-ui-pet--request "_harness/pet/get"))

;;;; Module

(defun harness-ui-pet--init ()
  "Wire the pet's buffer into the UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-pet--on-event)
  (add-hook 'harness-ui-connected-hook #'harness-ui-pet--on-connected)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-pet--redraw)
  (define-key harness-ui-map (kbd "z") #'harness-pet))

(defun harness-ui-pet--shutdown ()
  "Unwire the pet's buffer."
  (remove-hook 'harness-ui-event-functions #'harness-ui-pet--on-event)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-pet--on-connected)
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-pet--redraw)
  (remove-hook 'window-buffer-change-functions #'harness-ui-pet--update-watch)
  (harness-ui-pet--stop))

(harness-define-module 'ui-pet
  :doc "The companion pet's buffer: its card, its sayings, petting it."
  :requires '(ui)
  :init #'harness-ui-pet--init
  :shutdown #'harness-ui-pet--shutdown)

(provide 'harness-ui-pet)
;;; harness-ui-pet.el ends here
