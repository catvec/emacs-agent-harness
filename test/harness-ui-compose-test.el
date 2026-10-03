;;; harness-ui-compose-test.el --- Tests for pasting into the compose box  -*- lexical-binding: t; -*-

;;; Commentary:

;; The compose box in a stand-in host, pasting from a stand-in
;; clipboard (`gui-get-selection' answers from an alist, as X would):
;; C-y attaches the image a clipboard holds without text and yanks
;; otherwise, `yank-media' attaches images and the files a file manager
;; copied, and C-c C-v is no longer the box's, so a chat's [Verify]
;; keeps it.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-compose-map)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-compose-attachments)
(declare-function harness-compose-setup "harness-ui-compose")
(declare-function harness-compose-insert "harness-ui-compose")
(declare-function harness-compose-insert-attachments "harness-ui-compose")
(declare-function harness-compose-capture "harness-ui-compose")
(declare-function harness-compose-text "harness-ui-compose")
(declare-function harness-compose-set "harness-ui-compose")
(declare-function harness-compose-in-p "harness-ui-compose")
(declare-function harness-compose-remove-attachment "harness-ui-compose")
(declare-function harness-compose-attach-clipboard "harness-ui-compose")
(declare-function harness-compose--save-clip "harness-ui-compose")
(declare-function harness-compose--clips-directory "harness-ui-compose")
(declare-function harness-compose--yank-media-files "harness-ui-compose")
(declare-function harness-compose--mime-extension "harness-ui-compose")

(defconst harness-ui-compose-test--png (concat "\x89PNG\r\n\x1a\n" "a screenshot")
  "Bytes standing in for a PNG image.")

(defun harness-ui-compose-test--draw ()
  "Draw the stand-in host: a read-only line, the attachments, the box."
  (harness-compose-capture)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "A transcript line\n" 'read-only t 'rear-nonsticky t))
    (let ((start (point)))
      (harness-compose-insert-attachments)
      (put-text-property start (point) 'read-only t))
    (harness-compose-insert)
    (goto-char harness-compose-end)))

(defmacro harness-ui-compose-test-with (&rest body)
  "Run BODY in a host of the compose box, shown in the selected window.
Keys typed with `execute-kbd-macro' reach it.  The kill ring is BODY's
own, filled with no clipboard."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(acp ui ui-compose))
         (harness-test-load-module m)))
     (let ((buffer (generate-new-buffer "*compose test*"))
           (kill-ring nil)
           (kill-ring-yank-pointer nil)
           (interprogram-paste-function nil)
           (interprogram-cut-function nil)
           (select-enable-clipboard t))
       (unwind-protect
           (save-window-excursion
             (set-window-buffer nil buffer)
             (with-current-buffer buffer
               (use-local-map (make-composed-keymap nil harness-compose-map))
               (harness-compose-setup :redraw #'harness-ui-compose-test--draw)
               (harness-ui-compose-test--draw)
               ,@body))
         (kill-buffer buffer)))))

(defmacro harness-ui-compose-test-clipboard (contents &rest body)
  "Run BODY on a graphical display whose clipboard holds CONTENTS.
CONTENTS is an alist of (TYPE . DATA).  Asked for TARGETS, the
clipboard offers those types, TARGETS and TIMESTAMP, as X does."
  (declare (indent 1))
  `(let ((contents ,contents))
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
               ((symbol-function 'gui-get-selection)
                (lambda (&optional selection type)
                  (when (eq selection 'CLIPBOARD)
                    (if (eq type 'TARGETS)
                        (and contents (vconcat '(TARGETS TIMESTAMP) (mapcar #'car contents)))
                      (cdr (assq type contents)))))))
       ,@body)))

(defun harness-ui-compose-test--keys (keys)
  "Type KEYS in the selected window."
  (execute-kbd-macro (kbd keys)))

(defun harness-ui-compose-test--bytes (path)
  "Return the bytes of the file PATH."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(ert-deftest harness-ui-compose-keys ()
  "Pasting is C-y in the box; C-c C-v is not the box's."
  (harness-ui-compose-test-with
    (should (eq 'harness-compose-yank (key-binding (kbd "C-y"))))
    ;; Every key that yanks pastes into the box: S-insert too.
    (should (eq 'harness-compose-yank (key-binding (kbd "S-<insert>"))))
    (should (eq 'harness-compose-add-attachment (key-binding (kbd "C-c C-a"))))
    (should-not (lookup-key harness-compose-map (kbd "C-c C-v")))
    (should-not (key-binding (kbd "C-c C-v")))))

(ert-deftest harness-ui-compose-yank-attaches-the-clipboard-image ()
  "C-y with an image and no text in the clipboard attaches the image.
It is saved under the clips directory, the box's text stays as it was
and the kill ring is not touched."
  (harness-ui-compose-test-with
    (harness-compose-set "look at this")
    (goto-char harness-compose-end)
    (harness-ui-compose-test-clipboard `((image/png . ,harness-ui-compose-test--png)
                                         (image/bmp . "BM"))
      (harness-ui-compose-test--keys "C-y"))
    (should (= 1 (length harness-compose-attachments)))
    (let* ((att (car harness-compose-attachments))
           (path (plist-get att :path)))
      (should (equal "image/png" (plist-get att :mime)))
      (should (string-match-p "\\`clip-.*\\.png\\'" (file-name-nondirectory path)))
      (should (file-in-directory-p path (harness-compose--clips-directory)))
      (should (equal harness-ui-compose-test--png (harness-ui-compose-test--bytes path)))
      (should (equal (secure-hash 'sha1 harness-ui-compose-test--png) (plist-get att :sha1))))
    ;; The chip shows; the text is the box's own.
    (should (string-match-p "\\.png (20 B)×" (buffer-string)))
    (should (equal "look at this" (harness-compose-text)))
    (should-not kill-ring)))

(ert-deftest harness-ui-compose-yank-attaches-from-outside-the-box ()
  "C-y on the read-only text above the box attaches there too."
  (harness-ui-compose-test-with
    (goto-char (point-min))
    (should-not (harness-compose-in-p))
    (harness-ui-compose-test-clipboard `((image/jpeg . "jpeg bytes"))
      (harness-ui-compose-test--keys "C-y"))
    (should (equal "image/jpeg" (plist-get (car harness-compose-attachments) :mime)))
    (should (string-suffix-p ".jpeg" (plist-get (car harness-compose-attachments) :path)))))

(ert-deftest harness-ui-compose-yank-pastes-text-beside-an-image ()
  "Text in the clipboard yanks as ever, an image beside it or not.
A spreadsheet cell copies as text and as a picture: C-y pastes the text."
  (harness-ui-compose-test-with
    (let ((interprogram-paste-function (lambda () "A1 contents")))
      (dolist (text-type '(UTF8_STRING text/plain\;charset=utf-8 STRING))
        (harness-compose-set "")
        (goto-char harness-compose-end)
        (harness-ui-compose-test-clipboard `((image/png . ,harness-ui-compose-test--png)
                                             (,text-type . "A1 contents"))
          (harness-ui-compose-test--keys "C-y"))
        (should (equal "A1 contents" (harness-compose-text)))
        (should-not harness-compose-attachments)))))

(ert-deftest harness-ui-compose-yank-yanks-without-an-image ()
  "With no image to attach C-y is `yank': the kill ring, and M-y cycles it."
  (harness-ui-compose-test-with
    (kill-new "older kill")
    (kill-new "newest kill")
    ;; An empty clipboard, and one without a display.
    (harness-ui-compose-test-clipboard nil
      (harness-ui-compose-test--keys "C-y"))
    (should (equal "newest kill" (harness-compose-text)))
    (harness-compose-set "")
    (goto-char harness-compose-end)
    (cl-letf (((symbol-function 'gui-get-selection) (lambda (&rest _) (error "No display"))))
      (harness-ui-compose-test--keys "C-y M-y"))
    (should (equal "older kill" (harness-compose-text)))
    (should-not harness-compose-attachments)))

(ert-deftest harness-ui-compose-yank-yanks-when-told-to ()
  "A prefix argument, or a kill ring kept from the clipboard, yanks the image's
clipboard as `yank' would: the kill ring."
  (harness-ui-compose-test-with
    (kill-new "a kill")
    (harness-ui-compose-test-clipboard `((image/png . ,harness-ui-compose-test--png))
      ;; C-u C-y yanks, point before the text, as ever.
      (harness-ui-compose-test--keys "C-u C-y")
      (should (equal "a kill" (harness-compose-text)))
      (should (= (point) harness-compose-start))
      (harness-compose-set "")
      (goto-char harness-compose-end)
      (let ((select-enable-clipboard nil))
        (harness-ui-compose-test--keys "C-y"))
      (should (equal "a kill" (harness-compose-text))))
    (should-not harness-compose-attachments)))

(ert-deftest harness-ui-compose-yank-does-not-attach-twice ()
  "The image the box holds already is not attached again: C-y yanks the kill
ring then.  Removed, it attaches again."
  (harness-ui-compose-test-with
    (kill-new "a kill")
    (harness-ui-compose-test-clipboard `((image/png . ,harness-ui-compose-test--png))
      (harness-ui-compose-test--keys "C-y")
      (should (= 1 (length harness-compose-attachments)))
      (harness-ui-compose-test--keys "C-y")
      (should (= 1 (length harness-compose-attachments)))
      (should (equal "a kill" (harness-compose-text)))
      ;; Another image attaches beside it.
      (harness-ui-compose-test-clipboard `((image/png . ,(concat harness-ui-compose-test--png " cropped")))
        (harness-ui-compose-test--keys "C-y"))
      (should (= 2 (length harness-compose-attachments)))
      (harness-compose-remove-attachment (plist-get (car harness-compose-attachments) :path))
      (harness-compose-set "")
      (harness-ui-compose-test--keys "C-y")
      (should (= 2 (length harness-compose-attachments)))
      (should (equal "" (harness-compose-text))))))

(ert-deftest harness-ui-compose-yank-and-the-region ()
  "With `delete-selection-mode', yanked text replaces the region, and an
attached image leaves it be."
  (harness-ui-compose-test-with
    (let ((transient-mark-mode t)
          (was (bound-and-true-p delete-selection-mode)))
      (unwind-protect
          (progn
            (delete-selection-mode 1)
            (kill-new "replacement")
            (harness-compose-set "keep this, replace this")
            (cl-flet ((select (from)
                        (goto-char (+ harness-compose-start from))
                        (push-mark (point) t t)
                        (goto-char harness-compose-end)))
              (select 11)
              (harness-ui-compose-test-clipboard `((image/png . ,harness-ui-compose-test--png))
                (should-not (funcall (get 'harness-compose-yank 'delete-selection)))
                (harness-ui-compose-test--keys "C-y"))
              (should (equal "keep this, replace this" (harness-compose-text)))
              (should (= 1 (length harness-compose-attachments)))
              (select 11)
              (harness-ui-compose-test-clipboard `((UTF8_STRING . "replacement"))
                (should (eq 'yank (funcall (get 'harness-compose-yank 'delete-selection))))
                (harness-ui-compose-test--keys "C-y"))
              (should (equal "keep this, replacement" (harness-compose-text)))))
        (delete-selection-mode (if was 1 -1))))))

(ert-deftest harness-ui-compose-yank-media-attaches-an-image-beside-text ()
  "`yank-media', Emacs's command for pasting media, attaches the image even
when the clipboard holds text too."
  (harness-ui-compose-test-with
    (harness-ui-compose-test-clipboard `((image/png . ,harness-ui-compose-test--png)
                                         (UTF8_STRING . "A1 contents")
                                         (text/plain . "A1 contents"))
      (yank-media))
    (should (= 1 (length harness-compose-attachments)))
    (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))
    (should (equal "" (harness-compose-text)))))

(ert-deftest harness-ui-compose-yank-media-attaches-copied-files ()
  "Files copied in a file manager attach through `yank-media'."
  (harness-ui-compose-test-with
    (let* ((dir (harness-test-temp-dir))
           (a (expand-file-name "notes.txt" dir))
           (b (expand-file-name "the plan.md" dir)))
      (with-temp-file a (insert "notes\n"))
      (with-temp-file b (insert "plan\n"))
      (harness-ui-compose-test-clipboard
          `((x-special/gnome-copied-files
             . ,(format "copy\nfile://%s\nfile://%s\nfile://%s\0" a
                        (replace-regexp-in-string " " "%20" b)
                        (expand-file-name "gone.txt" dir)))
            (UTF8_STRING . ,a))
        ;; C-u picks the type: Emacs prefers copied files only under X.
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (yank-media t)))
      (should (equal (list a b) (mapcar (lambda (att) (plist-get att :path)) harness-compose-attachments)))
      (should-error (harness-compose--yank-media-files 'x-special/gnome-copied-files "copy\n")
                    :type 'user-error))))

(ert-deftest harness-ui-compose-attach-clipboard-picks-a-type ()
  "M-x harness-compose-attach-clipboard attaches the image, else the type
picked, else inserts the text."
  (harness-ui-compose-test-with
    (harness-ui-compose-test-clipboard `((image/png . ,harness-ui-compose-test--png)
                                         (UTF8_STRING . "text"))
      (harness-compose-attach-clipboard))
    (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))
    (harness-ui-compose-test-clipboard `((text/html . "<b>hi</b>")
                                         (text/plain\;charset=utf-8 . "hi"))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "text/plain;charset=utf-8")))
        (harness-compose-attach-clipboard)))
    (let ((att (cadr harness-compose-attachments)))
      (should (equal "text/plain;charset=utf-8" (plist-get att :mime)))
      ;; The extension leaves the charset out.
      (should (string-match-p "\\`clip-[-0-9]+\\.txt\\'" (file-name-nondirectory (plist-get att :path))))
      (should (equal "hi" (harness-ui-compose-test--bytes (plist-get att :path)))))
    (harness-ui-compose-test-clipboard '((UTF8_STRING . "plain words"))
      (harness-compose-attach-clipboard))
    (should (equal "plain words" (harness-compose-text)))))

(ert-deftest harness-ui-compose-clip-extensions ()
  "A capture's file is named for its type, whatever order mailcap lists them in."
  (harness-ui-compose-test-with
    (pcase-dolist (`(,mime . ,ext) '(("image/png" . "png") ("image/jpeg" . "jpeg") ("image/gif" . "gif")
                                     ("image/webp" . "webp") ("image/svg+xml" . "svg")
                                     ("text/plain" . "txt") ("text/plain; charset=UTF-8" . "txt")
                                     ("text/html" . "html") ("application/pdf" . "pdf")
                                     ("application/octet-stream" . "bin") ("nonsense" . "bin")))
      (ert-info (mime)
        (should (equal ext (harness-compose--mime-extension mime)))))))

(ert-deftest harness-ui-compose-clips-keep-a-file-each ()
  "Two captures within a second are saved to files of their own."
  (harness-ui-compose-test-with
    (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) "20261003-120000")))
      (let ((first (harness-compose--save-clip "first" "png"))
            (second (harness-compose--save-clip "second" "png")))
        (should-not (equal first second))
        (should (equal "first" (harness-ui-compose-test--bytes first)))
        (should (equal "second" (harness-ui-compose-test--bytes second)))))))

(provide 'harness-ui-compose-test)
;;; harness-ui-compose-test.el ends here
