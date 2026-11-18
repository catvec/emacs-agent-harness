;;; readdir-order.el --- same skill on ext4 and tmpfs, pre-fix vs fixed  -*- lexical-binding: t; -*-
;; Builds one skill, same names, same sizes, same SKILL.md, made in the same
;; creation order on two filesystems, and scans it with the count bound at 3:
;; with the walk in this tree, then with the walk as it was at 3cba0da.

(require 'harness-util)
(load (expand-file-name "lisp/harness-skills-scan.el") nil t)

(defconst demo-creation '("file-3.txt" "file-5.txt" "file-1.txt" "file-4.txt" "file-0.txt" "file-2.txt"))

(defun demo-skill (root)
  (make-directory root t)
  (dolist (name demo-creation)
    (with-temp-file (expand-file-name name root) (insert "xxxxxxxx")))
  (with-temp-file (expand-file-name "SKILL.md" root)
    (insert "---\nname: demo\ndescription: a demo skill\n---\n\nBody.\n"))
  root)

(defun demo-scan (root)
  (let* ((files (harness-skills-scan-files root))
         (text (harness-read-file (expand-file-name "SKILL.md" root))))
    (list (car files)
          (harness-skills-scan--fingerprint text (car files) root))))

;; The pre-fix walk, verbatim from 3cba0da, under another name.
(defun demo-scan-prefix (dir)
  (let* ((dir (harness-skills-scan--directory dir))
         (seen nil) (out nil) (total 0) (truncated nil)
         (stack (list (cons dir 0))))
    (while (and stack (not truncated))
      (let* ((pair (pop stack)) (current (car pair)) (depth (cdr pair)))
        (dolist (entry (ignore-errors (directory-files current t "\\`[^.]" t)))
          (unless truncated
            (cond
             ((member entry seen) nil)
             ((and (file-directory-p entry) (not (file-symlink-p entry)))
              (push entry seen)
              (if (< depth harness-skills-scan-max-depth)
                  (push (cons (harness-skills-scan--directory entry) (1+ depth)) stack)
                (setq truncated t)))
             ((file-regular-p entry)
              (push entry seen)
              (let* ((rel (file-relative-name entry dir))
                     (size (or (harness-skills-scan--size entry) 0)))
                (unless (or (equal entry (expand-file-name harness-skills-scan-file-name dir))
                            (string= rel harness-skills-scan-file-name))
                  (cond
                   ((>= (length out) harness-skills-scan-max-files) (setq truncated t))
                   ((> (+ total size) harness-skills-scan-max-files-bytes) (setq truncated t))
                   (t (setq total (+ total size)) (push rel out)))))))))))
    (let* ((files (sort out #'string<))
           (text (harness-read-file (expand-file-name "SKILL.md" dir))))
      (list files (harness-skills-scan--fingerprint text files dir)))))

(defun demo-rel (names)
  (mapconcat #'identity names " "))

(setq harness-skills-scan-max-files 3)

(let ((bases '(("/tmp" . "ext4") ("/dev/shm" . "tmpfs"))) (seen nil))
  (princ (format "creation order:  %s\ncount bound:     3\n\n"
                 (demo-rel demo-creation)))
  (dolist (pair bases)
    (let* ((base (car pair)) (label (cdr pair))
           (root (expand-file-name (format "harness-readdir-evidence-%d/flat" (emacs-pid)) base)))
      (unwind-protect
          (progn
            (demo-skill root)
            (let ((order (mapcar #'file-name-nondirectory (directory-files root t "\\`[^.]" t)))
                  (after (demo-scan root))
                  (before (demo-scan-prefix root)))
              (push (list label after before) seen)
              (princ (format "== %s  (%s)\n" label root))
              (princ (format "   filesystem:     %s\n" label))
              (princ (format "   readdir order:  %s\n" (demo-rel order)))
              (princ (format "   before the fix: %S\n" (nth 0 before)))
              (princ (format "   after  the fix: %S\n" (nth 0 after)))
              (princ (format "   fingerprint before: %s\n" (nth 1 before)))
              (princ (format "   fingerprint after : %s\n\n" (nth 1 after)))))
        (ignore-errors (delete-directory (file-name-directory root) t)))))

  (let* ((ext4 (seq-find (lambda (row) (equal (car row) "ext4")) seen))
         (tmpfs (seq-find (lambda (row) (equal (car row) "tmpfs")) seen))
         (e-after (nth 1 ext4)) (s-after (nth 1 tmpfs))
         (e-before (nth 2 ext4)) (s-before (nth 2 tmpfs)))
    (princ "== the two machines compared\n")
    (princ "   before the fix: the same skill on ext4 and on tmpfs\n")
    (princ (format "     files:        %s -- %S vs\n                            %S\n"
                   (if (equal (car e-before) (car s-before)) "the same" "different")
                   (car e-before) (car s-before)))
    (princ (format "     fingerprint:  %s -- %s vs %s\n"
                   (if (equal (nth 1 e-before) (nth 1 s-before)) "the same" "different")
                   (nth 1 e-before) (nth 1 s-before)))
    (princ "   after the fix:\n")
    (princ (format "     files:        %s -- %S\n"
                   (if (equal (car e-after) (car s-after)) "the same" "different")
                   (car e-after)))
    (princ (format "     fingerprint:  %s -- %s\n"
                   (if (equal (nth 1 e-after) (nth 1 s-after)) "the same" "different")
                   (nth 1 e-after)))))
