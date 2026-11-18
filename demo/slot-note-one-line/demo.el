;;; demo.el --- Show a slot-change note that stays one line  -*- lexical-binding: t; -*-

;;; Commentary:

;; Prints the note a session gets when the machine's load moves the tool
;; slots again and again, written by the module's own code and drawn by
;; the chat's own renderer.  Three parts:
;;
;;   1. one stretch, forty changes: the note the module writes, its
;;      title, its `:total', the lines it keeps, and the plain text a
;;      client that does not fold reads;
;;   2. the chat's drawing of it, folded and then opened, with the exact
;;      text the person sees -- the one line, "(40 changes)", and under
;;      it the count of what it leaves out above the newest lines;
;;   3. a stretch the note keeps whole: nothing is said to be left out,
;;      because nothing is.
;;
;; Before this change the note was closed once it held twenty changes
;; and the next one started another, so part 1 printed a row of notes,
;; "(20 changes)", "(20 changes)": the clutter the note was meant to
;; remove.  See docs/design/slot-change-note-stays-one-line.md.
;;
;; Run it with demo/slot-note-one-line/demo.sh.  It sends no model
;; request, starts no harness, installs nothing and runs no tool: it
;; calls the module's note writer against a session record it makes, and
;; the chat's renderer with a block it makes.

;;; Code:

(add-to-list 'load-path (expand-file-name "../.."
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp/modules"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp/ui"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))

(require 'cl-lib)
(require 'harness-util)
(require 'harness-tool-slots-load)
(require 'harness-ui)
(require 'harness-ui-chat)

(defconst demo--start (float-time (encode-time (list 0 12 9 18 11 2026 nil -1 nil)))
  "When the stretch of changes starts: 09:12:00.")

(defconst demo--count 40
  "How many changes the stretch of part 1 holds.")

(defun demo--change (i)
  "Return change number I of the stretch, as the module writes one.
The machine goes busy and quiet by turns, as a build does, and the
slots follow it."
  (let* ((down (= 0 (% i 2)))
         (n (if down (- 18 (% i 13)) (+ 5 (% i 13)))))
    (format "Tool slots %s %d: system load %.1fx on this machine"
            (if down "reduced to" "raised to")
            (max 1 n)
            (+ 1.0 (/ (% i 9) 10.0)))))

(defun demo--items (count)
  "Return COUNT changes as a note's items, one every 41 seconds."
  (cl-loop for i below count
           collect (list :ts (+ demo--start (* 41 i)) :text (demo--change i))))

(defun demo--node (items total)
  "Return the hint node a note of ITEMS, standing for TOTAL, is.
The content and meta are the module's own, not this demo's."
  (list :id "note" :kind 'hint
        :content (harness-tool-slots-load--note-text items total)
        :meta (harness-tool-slots-load--note-meta nil items total)))

(defun demo--block (node)
  "Return a chat block of NODE, folded, as the chat makes one."
  (let ((block (harness-chat--make-block :id (plist-get node :id) :kind "hint" :node node
                                         :content (plist-get node :content)
                                         :collapsed t)))
    (setf (harness-chat-block-fold block) (harness-node-fold node))
    block))

(defun demo--visible (from to)
  "Return the text between FROM and TO that is not hidden."
  (let ((text nil) (i from))
    (while (< i to)
      (unless (invisible-p i) (push (char-to-string (char-after i)) text))
      (setq i (1+ i)))
    (apply #'concat (nreverse text))))

(defun demo--draw (block)
  "Return the text the chat draws for BLOCK, as plain lines.
The block is inserted as the chat inserts it, with its fold, so a
folded block draws only its title and an open one draws its lines too."
  (with-temp-buffer
    (let ((from (point)))
      (insert (harness-chat--render-block block))
      (setf (harness-chat-block-start block) (copy-marker from)
            (harness-chat-block-end block) (copy-marker (point-max)))
      (harness-chat--make-fold block)
      (let ((lines (split-string (demo--visible from (point-max)) "\n")))
        (cl-remove-if (lambda (line) (string-empty-p (string-trim line))) lines)))))

(defun demo--section (title)
  "Print TITLE as a section heading."
  (princ (format "\n%s\n%s\n" title (make-string (length title) ?-))))

(defun demo--print-lines (lines)
  "Print LINES, each as the chat shows it."
  (dolist (line lines) (princ (format "  %s\n" (string-trim-right line)))))

(defun demo-run ()
  "Run the demo, printing each part as it goes."
  (let* ((items (demo--items demo--count))
         (kept (harness-tool-slots-load--note-keep items))
         (node (demo--node kept demo--count))
         (fold (harness-node-fold node))
         (block (demo--block node)))
    (demo--section (format "1. One stretch of %d changes, as the module writes it"
                           demo--count))
    (princ (format "  title       %s\n" (plist-get fold :title)))
    (princ (format "  total       %s\n" (plist-get fold :total)))
    (princ (format "  lines kept  %d of %d\n" (length kept) (length items)))
    (princ (format "  newest      %s\n" (plist-get (car (last kept)) :text)))
    (princ "\n  The plain text a client that does not fold reads:\n")
    (demo--print-lines (split-string (plist-get node :content) "\n"))

    (demo--section "2. The chat's drawing of it")
    (princ "  folded:\n")
    (demo--print-lines (demo--draw block))
    (setf (harness-chat-block-collapsed block) nil)
    (princ "\n  opened:\n")
    (demo--print-lines (demo--draw block))

    (demo--section "3. A stretch the note keeps whole")
    (let* ((few (demo--items 3))
           (few-node (demo--node few 3))
           (few-block (demo--block few-node)))
      (setf (harness-chat-block-collapsed few-block) nil)
      (princ (format "  title       %s\n" (plist-get (harness-node-fold few-node) :title)))
      (princ (format "  total       %s\n"
                     (or (plist-get (harness-node-fold few-node) :total) "none, it keeps them all")))
      (princ "  opened:\n")
      (demo--print-lines (demo--draw few-block)))
    (princ "\nOne line however long the stretch runs; opened, it counts what it leaves out.\n")))

(provide 'demo)
;;; demo.el ends here
