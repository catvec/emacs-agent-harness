;;; harness-docs-test.el --- The pictures the README shows are there  -*- lexical-binding: t -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The README's first picture and its gallery are files in docs/media,
;; linked by paths relative to the repository, which git.sr.ht and
;; GitHub serve from it.  A picture deleted while the README still links
;; it shows there as a broken image, and nothing else notices: thirteen
;; went missing at once that way.  `scripts/media.sh NAME...' takes a
;; missing one again (docs/screenshots.md).

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defun harness-docs-test--pictures (file)
  "Return the pictures Markdown FILE links in the repository, as relative paths.
A link is read from its \"](\" on, whatever its text holds: an alt text
with brackets in it, \"[Undo]\" say, would throw off a pattern for the
whole image syntax and hide its picture.  Links to other sites are left
out."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((case-fold-search t)
          (paths nil))
      (while (re-search-forward
              (concat "](\\([^)[:space:]]+\\.\\(?:png\\|jpe?g\\|gif\\|svg\\|webp\\)\\)"
                      "\\(?:[[:space:]]+\"[^\"]*\"\\)?)")
              nil t)
        (let ((path (match-string 1)))
          (unless (string-match-p "\\`[a-z][a-z0-9+.-]*:" path)
            (push path paths))))
      (nreverse paths))))

(ert-deftest harness-docs-test-pictures-reads-every-link ()
  "Brackets in an alt text, a title or a link elsewhere hide no picture."
  (let ((file (make-temp-file "harness-docs-test-" nil ".md"
                              (concat "![A board and [Undo]](docs/media/a.png)\n"
                                      "| ![x](docs/media/b.png) | ![y](docs/media/c.png \"C\") |\n"
                                      "[the guide](docs/guide.md) ![far](https://example.com/d.png)\n"))))
    (unwind-protect
        (should (equal (harness-docs-test--pictures file)
                       '("docs/media/a.png" "docs/media/b.png" "docs/media/c.png")))
      (delete-file file))))

(ert-deftest harness-docs-test-readme-pictures-exist ()
  "Every picture README.md shows is a picture in the repository."
  (let ((pictures (harness-docs-test--pictures (expand-file-name "README.md" harness-test-root))))
    ;; None found would pass the check below without checking anything.
    (should pictures)
    (should-not (cl-remove-if (lambda (path)
                                (let ((file (expand-file-name path harness-test-root)))
                                  (and (file-regular-p file)
                                       (image-type-from-file-header file))))
                              pictures))))

(provide 'harness-docs-test)
;;; harness-docs-test.el ends here
