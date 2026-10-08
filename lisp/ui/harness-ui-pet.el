;;; harness-ui-pet.el --- The companion pet's buffer, and where else it shows  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer, "*harness pet*", opened with `harness-pet' (C-c h z, or
;; z in the harness menu), shows the companion pet of the pet module:
;;
;;   header line   [Pet] [Rename] [Mute] [Release] [Turn off], g and q;
;;                 [Hatch] while there is only an egg
;;   card          its stars, rarity and species, then the creature
;;                 itself in its rarity's colour beside its five stats,
;;                 its name (gold when it is shiny) and personality,
;;                 its level and experience, and what it said last, on
;;                 a band of its own, with when and about which session
;;   footer        the model it speaks with, and whether it may
;;
;; Before it hatches, the buffer shows the egg and a [Hatch] button.
;; While it is turned off (the pet module's `harness-pet-enabled'), it
;; says so and offers [Turn it on].
;;
;; Once it hatched, the pet shows quietly in a few places besides, those
;; `harness-ui-pet-places' names:
;;
;;   chat header   its face, on one line in its rarity's colour, near
;;                 the end of a chat's header line, the first thing to
;;                 go when the window is narrow.  It blinks now and then
;;                 while the session works, drawn by the chat's own
;;                 spinner; hovering names it, a click shows its buffer.
;;   chat saying   what it last said about a session, on a line of its
;;                 own above that session's compose box, until the
;;                 session's next turn starts.
;;   board         its face and name in the task board's header line.
;;
;; None of them shows while the pet is turned off or still an egg, nor
;; one left out of `harness-ui-pet-places': their hooks are not even
;; set then (`harness-ui-pet--wire').  They draw from the pet as the
;; harness last told this Emacs (`harness-ui-pet--current'), asked for
;; when the UI connects and followed through `pet/changed'.
;;
;; The pet only speaks where it would be seen.  This Emacs tells the
;; harness (`pet/watch') whenever that changes, through
;; `window-buffer-change-functions' while it matters: the pet's buffer
;; on screen lets it speak about anything, a chat on screen about that
;; chat's session, when what it says shows above chats.
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

(defcustom harness-ui-pet-places '(chat-header chat-saying board)
  "Where the companion pet shows besides its own buffer, once it hatched.
A list of:

- `chat-header': its face, on one line in its rarity's colour, near the
  end of a chat's header line, the first thing to go in a narrow window.
  It blinks now and then while the session works; hovering names it, a
  click shows it.
- `chat-saying': what it last said about a session, on a line of its own
  above that session's compose box, until the session's next turn
  starts.  A chat on screen then lets it speak about that session, as
  its own buffer on screen lets it speak about anything.
- `board': its face and name in the task board's header line.

nil shows it in its buffer only (`harness-pet').  The pet module's
`harness-pet-enabled' turns it off everywhere, its buffer included."
  :type '(set (const :tag "Its face in chat header lines" chat-header)
              (const :tag "What it said about a session, above that chat's compose box" chat-saying)
              (const :tag "Its face and name in the task board's header line" board))
  :initialize #'custom-initialize-default
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'harness-ui-pet--sync) (harness-ui-pet--sync)))
  :group 'harness-ui-pet)

(defconst harness-ui-pet--buffer-name "*harness pet*"
  "Name of the pet's buffer.")

(defconst harness-ui-pet--saying-lifetime (* 15 60)
  "Seconds at most a saying shows above a compose box.
Its session's next turn takes it away before, as a redraw finds.")

(defconst harness-ui-pet--header-priority 2
  "Priority of the pet's face in a chat's header line: it goes first.")

(defconst harness-ui-pet--board-priority 15
  "Priority of the pet's face and name in the board's header line.
Below [Add session]'s, so it goes first.")

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
(defface harness-pet-saying-face '((t :inherit (harness-pet-speech-face shadow)))
  "What the pet said about a session, on its line above that chat's compose box.
Quieter than the band of its own buffer: dim on the same background."
  :group 'harness-ui-pet)

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

;;;; The face, on one line

(defconst harness-ui-pet--faces
  '((duck . "({E}>") (goose . "({E}>") (blob . "({E}{E})") (cat . "={E}ω{E}=")
    (dragon . "<{E}~{E}>") (octopus . "~({E}{E})~") (owl . "({E})({E})") (penguin . "({E}>)")
    (turtle . "[{E}_{E}]") (snail . "{E}(@)") (ghost . "/{E}{E}\\") (axolotl . "}{E}.{E}{")
    (capybara . "({E}oo{E})") (cactus . "|{E}  {E}|") (robot . "[{E}{E}]") (rabbit . "({E}..{E})")
    (mushroom . "|{E}  {E}|") (chonk . "({E}.{E})"))
  "Each species's face on one line, {E} for its eyes: the pet in a header line.
As Claude Code's companions showed theirs beside the prompt.")

(defconst harness-ui-pet--face-fallbacks
  '((?· . ".") (?✦ . "*") (?× . "x") (?◉ . "o") (?° . "o") (?ω . "w"))
  "Characters of a face to draw instead of those the frame cannot show.")

(defconst harness-ui-pet--blinks [0 0 0 0 0 0 0 0 1 0 0 0 0 0 0]
  "Half seconds of a pet watching a session work, 1 where it blinks.
Fifteen of them, as Claude Code's companions idled: once in a while.")

(defvar harness-ui-pet--displayable (make-hash-table :test 'equal)
  "(CHAR . GRAPHIC) -> whether CHAR shows, as `char-displayable-p' said.
GRAPHIC is whether the frame was graphic: a terminal shows fewer.")

(defun harness-ui-pet--displayable-p (char)
  "Non-nil when the selected frame shows CHAR; asked once a kind of frame."
  (let* ((key (cons char (and (display-graphic-p) t)))
         (known (gethash key harness-ui-pet--displayable 'unknown)))
    (if (eq known 'unknown)
        (puthash key (and (char-displayable-p char) t) harness-ui-pet--displayable)
      known)))

(defun harness-ui-pet-face (species eye &optional blink)
  "Return the face of a SPECIES pet with EYE, on one line; eyes shut if BLINK.
SPECIES is a name, as a string or a symbol, EYE a string.  A character
the selected frame cannot show is drawn as an ASCII one instead."
  (let ((face (string-replace
               "{E}" (cond (blink "-")
                           ((and (stringp eye) (not (string-empty-p eye))) eye)
                           (t "o"))
               (or (alist-get (intern (format "%s" species)) harness-ui-pet--faces)
                   (alist-get 'blob harness-ui-pet--faces)))))
    (mapconcat (lambda (char)
                 (if (or (< char 128) (harness-ui-pet--displayable-p char))
                     (string char)
                   (or (alist-get char harness-ui-pet--face-fallbacks) "o")))
               face "")))

(defun harness-ui-pet--blink-p (&optional time)
  "Non-nil when a pet watching a session work has its eyes shut at TIME (now)."
  (= 1 (aref harness-ui-pet--blinks
             (mod (floor (or time (float-time)) 0.5) (length harness-ui-pet--blinks)))))

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
(defvar harness-ui-pet--watching nil
  "Where this Emacs last told the harness it shows the pet.
As `harness-ui-pet--seen' returns it: t, a list of session ids, or nil.")
(defvar harness-ui-pet--bars (make-hash-table :test 'equal)
  "Stat bar images by (FRACTION WIDTH COLOR), so a redraw reuses them.")

(defvar harness-ui-pet--live nil
  "Non-nil while the module is on: the places besides the buffer may show.")
(defvar harness-ui-pet--current nil
  "The pet as the harness last told this Emacs, as `pet/get' returns it.
The places besides its buffer draw from it; nil before it is known.")
(defvar harness-ui-pet--drawn nil
  "What the header lines showed of the pet when they were last redrawn.")
(defvar harness-ui-pet--turns (make-hash-table :test 'equal)
  "Session id -> when its last turn started, as this Emacs heard.
What the pet said about a session before then shows no more.")
(defvar-local harness-ui-pet--panel-shown nil
  "The saying a chat buffer's tail shows above its compose box, or nil.")

(defun harness-ui-pet--buffer ()
  "The pet's buffer, or nil."
  (get-buffer harness-ui-pet--buffer-name))

(defun harness-ui-pet--true-p (value)
  "Non-nil when VALUE, from the wire, is true."
  (and value (not (eq value :false))))

(defun harness-ui-pet--hatched-p (&optional view)
  "Non-nil when VIEW (default the buffer's) is of a pet that hatched."
  (harness-ui-pet--true-p (plist-get (or view harness-ui-pet--view) :hatched)))

(defun harness-ui-pet--enabled-p (view)
  "Non-nil unless VIEW says the pet is turned off.
A view without `:enabled', from a harness older than the switch, is on."
  (not (eq (plist-get view :enabled) :false)))

(defun harness-ui-pet--active-p ()
  "Non-nil when the pet may show in places: it is on, and it hatched."
  (let ((view harness-ui-pet--current))
    (and harness-ui-pet--live view
         (harness-ui-pet--enabled-p view)
         (harness-ui-pet--hatched-p view))))

(defun harness-ui-pet--place-p (place)
  "Non-nil when the pet shows in PLACE now, one of `harness-ui-pet-places'."
  (and (memq place harness-ui-pet-places) (harness-ui-pet--active-p)))

(defun harness-ui-pet--chat-buffer-p (buffer)
  "Non-nil when BUFFER is a live chat buffer."
  (and (buffer-live-p buffer)
       (provided-mode-derived-p (buffer-local-value 'major-mode buffer) 'harness-chat-mode)))

(defun harness-ui-pet--chat-buffers ()
  "The live chat buffers."
  (cl-remove-if-not #'harness-ui-pet--chat-buffer-p (buffer-list)))

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

(defun harness-ui-pet--seen (&optional without-buffer)
  "Where this Emacs shows the pet now, as `pet/watch' takes it.
t while the pet's buffer is on screen, where anything it says is seen;
else, when what it says shows above chats (`chat-saying'), the sorted
ids of the sessions whose chats are on screen, or nil.  WITHOUT-BUFFER
leaves the buffer out, as it goes."
  (cond ((and (not without-buffer) (harness-ui-pet--shown-p)) t)
        ((harness-ui-pet--place-p 'chat-saying)
         (let ((ids nil))
           (dolist (frame (frame-list))
             (when (eq t (frame-visible-p frame))
               (dolist (window (window-list frame 'nomini))
                 (let ((buffer (window-buffer window)))
                   (when (harness-ui-pet--chat-buffer-p buffer)
                     (when-let* ((id (buffer-local-value 'harness-ui-session-id buffer)))
                       (cl-pushnew id ids :test #'equal)))))))
           (sort ids #'string<)))))

(defun harness-ui-pet--send-watch (seen)
  "Tell the harness where this Emacs shows the pet: SEEN.
SEEN is as `harness-ui-pet--seen' returns it.  Draw the pet the harness
answers with, unless SEEN is nil: it shows nowhere then."
  (setq harness-ui-pet--watching seen)
  (harness-ui-call "_harness/pet/watch"
                   (append (list :client (harness-ui-pet--client-id) :on (if seen t :false))
                           (and (consp seen) (list :sessions seen)))
                   (lambda (view) (when seen (harness-ui-pet--receive view)) nil)
                   ;; Only the buffer says what went wrong; the places stay quiet.
                   (if (eq seen t) #'harness-ui-pet--failed #'ignore)))

(defun harness-ui-pet--update-watch (&rest _)
  "Tell the harness where the pet is on screen, when that changed.
In `window-buffer-change-functions' while the pet's buffer lives or what
it says shows above chats.  Its animation stops once the buffer is off
screen."
  (let ((seen (harness-ui-pet--seen)))
    (unless (equal seen harness-ui-pet--watching)
      (harness-ui-pet--send-watch seen)))
  (unless (harness-ui-pet--shown-p) (harness-ui-pet--stop)))

(defun harness-ui-pet--on-resize (window)
  "Draw the pet's buffer again when WINDOW, which shows it, changed width.
In the buffer's `window-size-change-functions', which redisplay runs
only when a window showing it changed size."
  (with-current-buffer (window-buffer window)
    (unless (eql (harness-ui-pet--window-width) harness-ui-pet--width)
      (harness-ui-pet--render))))

(defun harness-ui-pet--on-kill ()
  "The pet's buffer goes: it is not on screen any more, though chats may be."
  (harness-ui-pet--stop)
  (harness-ui-pet--wire t)
  (let ((seen (harness-ui-pet--seen t)))
    (unless (equal seen harness-ui-pet--watching)
      (harness-ui-pet--send-watch seen))))

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
  "Show VIEW, the pet as `pet/get' returns it, wherever the pet shows."
  (when (keywordp (car-safe view))
    (setq harness-ui-pet--current view)
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
    (harness-ui-pet--sync))
  nil)

(defun harness-ui-pet--request (method &optional params)
  "Send METHOD with PARAMS about the pet; show the pet it answers with."
  (harness-ui-call method params #'harness-ui-pet--receive #'harness-ui-pet--failed))

(defun harness-ui-pet--fetch ()
  "Ask the harness for the pet, for wherever it shows.
A failure shows in the pet's buffer, if open; the places stay quiet."
  (harness-ui-call "_harness/pet/get" nil #'harness-ui-pet--receive
                   (lambda (err) (when (harness-ui-pet--buffer) (harness-ui-pet--failed err)) nil)))

(defun harness-ui-pet--on-event (event args)
  "Follow the pet through EVENT with ARGS."
  (pcase event
    ("pet/changed" (harness-ui-pet--receive (car args)))
    ("pet/said"
     (when-let* ((buf (harness-ui-pet--buffer)))
       (with-current-buffer buf
         ;; Its first words come as it hatches: it fidgets after.
         (if (memq (plist-get harness-ui-pet--anim :kind) '(egg crack sparkle))
             (setq harness-ui-pet--queued 'fidget)
           (harness-ui-pet--animate 'fidget)))))
    ("agent/turn-started" (harness-ui-pet--on-turn-started (car args)))
    ("config/changed"
     (when (string-prefix-p "harness-pet-" (format "%s" (car args)))
       (harness-ui-pet--fetch)))))

(defun harness-ui-pet--on-connected ()
  "The harness may have restarted: ask for the pet, say again where it shows."
  (setq harness-ui-pet--watching nil)
  (let ((seen (harness-ui-pet--seen)))
    (if seen
        (harness-ui-pet--send-watch seen)
      (harness-ui-pet--fetch))))

(defun harness-ui-pet--redraw ()
  "Redraw the pet's buffer and its places, as every view redraws after a reload."
  (when-let* ((buf (harness-ui-pet--buffer)))
    (with-current-buffer buf (harness-ui-pet--render)))
  (setq harness-ui-pet--drawn nil)
  (harness-ui-pet--sync))

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

;;;; Places besides its buffer

(defvar harness-ui-pet--face-map nil "Keymap of the pet's face: a click shows it.")

(defun harness-ui-pet--face-map ()
  "The keymap of the pet's face wherever it shows: a click opens its buffer."
  (or harness-ui-pet--face-map
      (setq harness-ui-pet--face-map (harness-ui-mouse-keymap #'harness-pet))))

(defun harness-ui-pet--about (view)
  "Who the pet of VIEW is, in a few words: \"Fennel, your rare cat, level 3\"."
  (format "%s, your %s%s %s, level %d"
          (or (plist-get view :name) "Your pet")
          (if (harness-ui-pet--true-p (plist-get view :shiny)) "shiny " "")
          (or (plist-get view :rarity) "common")
          (or (plist-get view :species) "pet")
          (or (plist-get view :level) 1)))

(defun harness-ui-pet--face-help (&rest _)
  "The tooltip of the pet's face: who it is, what it said last, what a click does.
A `help-echo' function, so it is worked out on hover only."
  (let* ((view harness-ui-pet--current)
         (last (car (last (plist-get view :said)))))
    (concat (harness-ui-pet--about view)
            (if last
                (format "\n%s\n(%s)" (harness-ui-one-line (plist-get last :text)) (harness-ui-pet--when last))
              "")
            "\nmouse-1: show it")))

(defun harness-ui-pet--face-segment (view &optional blink)
  "The face of the pet of VIEW for a header line, eyes shut when BLINK.
In its rarity's colour; hovering says who it is, a click shows it."
  (propertize (harness-ui-pet-face (plist-get view :species) (plist-get view :eye) blink)
              'face (harness-ui-pet--rarity-face (plist-get view :rarity))
              'help-echo #'harness-ui-pet--face-help
              'mouse-face 'mode-line-highlight
              'local-map (harness-ui-pet--face-map)))

(defun harness-ui-pet--chat-header ()
  "The pet's face for a chat's header line, or nil.
On `harness-chat-header-end-functions' while the pet shows there.  It
blinks now and then while the session runs: the chat's spinner redraws
the header line meanwhile, so the pet needs no timer of its own."
  (when (harness-ui-pet--place-p 'chat-header)
    (let ((running (equal (plist-get (harness-ui-session harness-ui-session-id) :status) "running")))
      (list (concat "  " (harness-ui-pet--face-segment harness-ui-pet--current
                                                       (and running (harness-ui-pet--blink-p))))
            harness-ui-pet--header-priority))))

(defun harness-ui-pet--board-header ()
  "The pet's face and name for the task board's header line, or nil.
On `harness-ui-tasks-header-functions' while the pet shows there; in a
narrow window the name goes first, then the face."
  (when (harness-ui-pet--place-p 'board)
    (let* ((view harness-ui-pet--current)
           (face (harness-ui-pet--face-segment view)))
      (list (concat face " " (propertize (or (plist-get view :name) "")
                                         'face 'harness-dim-face
                                         'help-echo #'harness-ui-pet--face-help
                                         'mouse-face 'mode-line-highlight
                                         'local-map (harness-ui-pet--face-map)))
            harness-ui-pet--board-priority
            face))))

(defun harness-ui-pet--saying-for (session-id &optional now)
  "What the pet said about SESSION-ID to show above its compose box, or nil.
Its last saying about it, while what it says shows above chats, it is
not muted, the session's turn has not started again since, and it is
not older than `harness-ui-pet--saying-lifetime' at NOW."
  (when (and session-id (harness-ui-pet--place-p 'chat-saying)
             (not (harness-ui-pet--true-p (plist-get harness-ui-pet--current :muted))))
    (let* ((now (or now (float-time)))
           (since (gethash session-id harness-ui-pet--turns 0))
           (saying (cl-find session-id (plist-get harness-ui-pet--current :said)
                            :key (lambda (s) (plist-get s :session)) :test #'equal :from-end t))
           (ts (plist-get saying :ts)))
      (and saying (numberp ts) (> ts since)
           (< (- now ts) harness-ui-pet--saying-lifetime)
           saying))))

(defun harness-ui-pet--saying-line (view saying)
  "SAYING of the pet of VIEW, as its line above a compose box.
Its face and name in its rarity's colour, a click on them shows it,
then what it said, dim, its actions set apart."
  (let* ((head (propertize (concat (harness-ui-pet-face (plist-get view :species) (plist-get view :eye))
                                   " " (or (plist-get view :name) ""))
                           'face (harness-ui-pet--rarity-face (plist-get view :rarity))
                           'mouse-face 'highlight
                           'keymap (harness-ui-pet--face-map)
                           'help-echo (format "%s, %s (mouse-1: show it)"
                                              (harness-ui-pet--about view) (harness-ui-pet--when saying))))
         (line (concat " " head "  " (harness-ui-pet--speech (plist-get saying :text)) "\n")))
    (add-text-properties 0 (length line) (list 'wrap-prefix "   " 'harness-ui-pet-saying t) line)
    (harness-ui-add-face line 'harness-pet-saying-face)))

(defun harness-ui-pet--panel ()
  "What the pet said about this chat's session, for above its compose box, or nil.
On `harness-chat-panel-functions' while it shows there."
  (let ((saying (harness-ui-pet--saying-for harness-ui-session-id)))
    (setq harness-ui-pet--panel-shown saying)
    (and saying (harness-ui-pet--saying-line harness-ui-pet--current saying))))

(defvar harness-compose-redraw-function)

(defun harness-ui-pet--redraw-tail ()
  "Draw this chat buffer's tail again, so the pet's line there follows."
  (setq harness-ui-pet--panel-shown nil)
  (when (and (boundp 'harness-compose-redraw-function) (functionp harness-compose-redraw-function))
    (funcall harness-compose-redraw-function)))

(defun harness-ui-pet--sync-panels ()
  "Draw again the tails of the chats whose line from the pet changed."
  (dolist (buffer (harness-ui-pet--chat-buffers))
    (with-current-buffer buffer
      (unless (equal (harness-ui-pet--saying-for harness-ui-session-id) harness-ui-pet--panel-shown)
        (harness-ui-pet--redraw-tail)))))

(defun harness-ui-pet--on-turn-started (session-id)
  "SESSION-ID's turn started: what the pet said about it before goes.
Noted while the module is on, even with nothing above chats, so a
saying from before does not come back when they show it again."
  (when (and (stringp session-id) harness-ui-pet--live)
    (puthash session-id (float-time) harness-ui-pet--turns)
    (when-let* ((buffer (cl-find session-id (harness-ui-pet--chat-buffers)
                                 :key (lambda (b) (buffer-local-value 'harness-ui-session-id b))
                                 :test #'equal)))
      (with-current-buffer buffer
        (when harness-ui-pet--panel-shown (harness-ui-pet--redraw-tail))))))

(defun harness-ui-pet--wire (&optional dying)
  "Set the hooks the pet's places need now, and only those.
The window hook while its buffer lives (unless DYING, as it goes) or
what it says shows above chats; each place's own while it shows there."
  (cl-flet ((set-hook (on hook fn)
              (if on (add-hook hook fn t) (remove-hook hook fn))))
    (set-hook (or (and (not dying) (harness-ui-pet--buffer)) (harness-ui-pet--place-p 'chat-saying))
              'window-buffer-change-functions #'harness-ui-pet--update-watch)
    (set-hook (harness-ui-pet--place-p 'chat-header)
              'harness-chat-header-end-functions #'harness-ui-pet--chat-header)
    (set-hook (harness-ui-pet--place-p 'chat-saying)
              'harness-chat-panel-functions #'harness-ui-pet--panel)
    (set-hook (harness-ui-pet--place-p 'board)
              'harness-ui-tasks-header-functions #'harness-ui-pet--board-header)))

(defun harness-ui-pet--places-key ()
  "What the header lines show of the pet: redrawn when it changes."
  (let ((view harness-ui-pet--current))
    (and (harness-ui-pet--active-p)
         (list harness-ui-pet-places (plist-get view :species) (plist-get view :eye)
               (plist-get view :rarity) (plist-get view :name)))))

(defun harness-ui-pet--sync ()
  "Bring every place the pet shows in up to date with it.
Set the hooks it needs, redraw the header lines and the chats' lines
that changed, and tell the harness where it is on screen."
  (harness-ui-pet--wire)
  (let ((key (harness-ui-pet--places-key)))
    (unless (equal key harness-ui-pet--drawn)
      (setq harness-ui-pet--drawn key)
      (force-mode-line-update t)))
  (harness-ui-pet--sync-panels)
  (when harness-ui-pet--live
    (harness-ui-pet--update-watch)))

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
       (format "It hatches into one of 18 species, common to legendary, with five stats and a personality%s. Then it keeps you company, quietly: its face at the end of a chat's header line, and now and then a word about your work. Not for you? O turns it off."
               (if (stringp model) (format " that %s gives it" (harness-ui-model-label model)) ""))
       'harness-dim-face))))

(defun harness-ui-pet--insert-off ()
  "Insert what the buffer shows while the pet is turned off.
A pet that hatched sleeps, eyes shut: turned on, it wakes as it was."
  (let* ((view harness-ui-pet--view)
         (hatched (harness-ui-pet--hatched-p)))
    (insert "  ")
    (when hatched
      (insert (propertize (harness-ui-pet-face (plist-get view :species) (plist-get view :eye) t)
                          'face (list (harness-ui-pet--rarity-face (plist-get view :rarity))
                                      'harness-pet-art-face))
              "  "))
    (insert (propertize (if hatched
                            (format "%s is asleep" (or (plist-get view :name) "Your pet"))
                          "The companion pet is turned off")
                        'face 'harness-pet-name-face)
            "\n\n")
    (harness-ui-pet--insert-filled
     (concat "Turned off, it shows nowhere else, grows no more and asks no model anything."
             (if hatched " Turned on again, it wakes up as it was." ""))
     'harness-dim-face)
    (insert "\n  ")
    (harness-ui-button "Turn it on" #'harness-ui-pet-turn-on :help "Turn the companion pet on again (O)")
    (insert "\n")))

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
                     (t (format "It now and then has a word to say%s, while %s. m mutes it, O turns it off."
                                (if (stringp model) (format ", through %s" (harness-ui-model-label model)) "")
                                (if (memq 'chat-saying harness-ui-pet-places)
                                    "it is on screen: here, or above the compose box of the chat it is about"
                                  "this buffer is on screen"))))))
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
     ((not (harness-ui-pet--enabled-p harness-ui-pet--view))
      (harness-ui-pet--insert-off))
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
         (off (and view (not (harness-ui-pet--enabled-p view))))
         ;; As drawn: the egg until it has finished cracking.
         (egg (memq (plist-get harness-ui-pet--anim :kind) '(egg crack)))
         (hatched (and (not off) (harness-ui-pet--hatched-p) (not egg)))
         (muted (harness-ui-pet--true-p (plist-get view :muted)))
         (turn-off (list (harness-ui-pet--segment "Turn off" #'harness-ui-pet-turn-off
                                                  "Turn it off everywhere: no more of it, no model calls (O)")
                         30)))
    (harness-ui-fit-header
     (append
      (list (propertize " Companion " 'face '(bold harness-label-face)))
      (cond
       (off (list (list (harness-ui-pet--segment "Turn on" #'harness-ui-pet-turn-on "Turn it on again (O)") 90)))
       (hatched
        (list (list (harness-ui-pet--segment "Pet" #'harness-ui-pet-pet "Pet it (p)") 90)
              (list (harness-ui-pet--segment "Rename" #'harness-ui-pet-rename "Give it another name (r)") 60)
              (list (harness-ui-pet--segment (if muted "Unmute" "Mute") #'harness-ui-pet-toggle-mute
                                             (if muted "Let it speak again (m)" "Keep it quiet: no more model calls (m)"))
                    70)
              (list (harness-ui-pet--segment "Release" #'harness-ui-pet-release "Let it go for good (R)") 40)
              turn-off))
       ((and view (not egg) (not (harness-ui-pet--hatched-p))
             (not (harness-ui-pet--true-p (plist-get view :hatching))))
        (list (list (harness-ui-pet--segment "Hatch" #'harness-ui-pet-hatch "Hatch the egg (h)") 90)
              turn-off)))
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
    (define-key map (kbd "O") #'harness-ui-pet-toggle-enabled)
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
        (". O" "Turn off or on" harness-ui-pet-toggle-enabled)
        (". g" "Refresh" harness-ui-pet-refresh)]))

(defun harness-ui-pet--in-buffer (&optional while-off)
  "Make the pet's buffer current, or complain that it is not open.
Complain too while the pet is turned off, unless WHILE-OFF."
  (let ((buf (harness-ui-pet--buffer)))
    (unless buf (user-error "The pet's buffer is not open: M-x harness-pet"))
    (set-buffer buf)
    (unless (or while-off (harness-ui-pet--enabled-p harness-ui-pet--view))
      (user-error "The companion pet is turned off: O turns it on"))))

;;;###autoload
(defun harness-pet ()
  "Show the companion pet, or the egg it hatches from."
  (interactive)
  (let ((buf (get-buffer-create harness-ui-pet--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-pet-mode)
        (harness-ui-pet-mode))
      ;; What this Emacs knows shows at once; the answer follows.
      (unless harness-ui-pet--view (setq harness-ui-pet--view harness-ui-pet--current)))
    (harness-ui-pet--wire)
    (harness-ui-display-view buf)
    ;; Drawn once it has its window, to the window's width.
    (with-current-buffer buf (harness-ui-pet--render))
    ;; On screen now, so this asks for the pet as well.
    (setq harness-ui-pet--watching nil)
    (harness-ui-pet--send-watch (harness-ui-pet--seen))
    (unless harness-ui-pet--watching
      (harness-ui-pet--request "_harness/pet/get"))))

(defun harness-ui-pet--set-enabled (on)
  "Turn the companion pet on, or off when ON is nil, and keep it so.
As the Settings page would set `harness-pet-enabled': saved in your
custom file, and every Emacs showing the harness follows, through
`config/changed'."
  (harness-ui-call "_harness/config/set"
                   (list :key "harness-pet-enabled" :value (if on "t" "nil")
                         :printed t :scope "global")
                   #'ignore #'harness-ui-pet--failed))

(defun harness-ui-pet-turn-off ()
  "Turn the companion pet off everywhere.
It shows nowhere but in its buffer, which says it is off, grows no more
and asks no model anything.  Its record stays: `harness-ui-pet-turn-on'
wakes it as it was.  Saved as `harness-pet-enabled'."
  (interactive)
  (harness-ui-pet--set-enabled nil)
  (unless (eq (current-buffer) (harness-ui-pet--buffer))
    (message "The companion pet is off; M-x harness-ui-pet-turn-on brings it back")))

(defun harness-ui-pet-turn-on ()
  "Turn the companion pet on again, as it was when turned off."
  (interactive)
  (harness-ui-pet--set-enabled t))

(defun harness-ui-pet-toggle-enabled ()
  "Turn the companion pet off, or on again."
  (interactive)
  (unless harness-ui-pet--current
    (user-error "Whether there is a pet is not known yet: g asks again"))
  (if (harness-ui-pet--enabled-p harness-ui-pet--current)
      (harness-ui-pet-turn-off)
    (harness-ui-pet-turn-on)))

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
  (harness-ui-pet--in-buffer t)
  (harness-ui-pet--request "_harness/pet/get"))

;;;; Module

(defun harness-ui-pet--init ()
  "Wire the pet's buffer into the UI; the places follow once the pet is known."
  (add-hook 'harness-ui-event-functions #'harness-ui-pet--on-event)
  (add-hook 'harness-ui-connected-hook #'harness-ui-pet--on-connected)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-pet--redraw)
  (define-key harness-ui-map (kbd "z") #'harness-pet)
  (setq harness-ui-pet--live t)
  ;; Started again while connected, as a reload does: no connection
  ;; opens to ask for the pet.
  (when (harness-ui-connected-p) (harness-ui-pet--fetch)))

(defun harness-ui-pet--shutdown ()
  "Unwire the pet's buffer, and take the pet away from every place."
  (remove-hook 'harness-ui-event-functions #'harness-ui-pet--on-event)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-pet--on-connected)
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-pet--redraw)
  (harness-ui-pet--stop)
  (setq harness-ui-pet--live nil)
  (harness-ui-pet--wire t)
  (harness-ui-pet--sync-panels)
  (setq harness-ui-pet--current nil harness-ui-pet--drawn nil)
  (clrhash harness-ui-pet--turns)
  (force-mode-line-update t)
  (when harness-ui-pet--watching
    (if (harness-ui-connected-p)
        (ignore-errors (harness-ui-pet--send-watch nil))
      (setq harness-ui-pet--watching nil))))

(harness-define-module 'ui-pet
  :doc "The companion pet: its buffer, and its face and words in chats and on the board."
  :requires '(ui)
  :init #'harness-ui-pet--init
  :shutdown #'harness-ui-pet--shutdown)

(provide 'harness-ui-pet)
;;; harness-ui-pet.el ends here
