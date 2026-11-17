;;; show.el --- Deferred media in the isolated development frame -*- lexical-binding: t; -*-

;; Load only in the checkout's development Emacs, never Noah's active UI.
;; All text/images are mock content.  No model, audio, input or permission changes.
(unless (bound-and-true-p harness-dev-root)
  (error "Isolated development Emacs required"))
(require 'harness-ui-markdown)
(require 'harness-ui-media)

(with-selected-frame (harness-dev-frame)
  (let* ((fixtures (make-temp-file (expand-file-name "relative-media-" harness-state-directory) t))
	 (relative "docs/media/voice-ribbon-review/mock-review.svg")
	 (file (expand-file-name relative fixtures))
	 (buffer (get-buffer-create "*Harness freeze regression*"))
	 picture rendered)
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert "<svg xmlns='http://www.w3.org/2000/svg' width='600' height='110' viewBox='0 0 600 110'>"
              "<rect width='600' height='110' rx='12' fill='#00624e'/>"
              "<text x='24' y='48' font-family='sans-serif' font-size='24' fill='white'>Relative review image</text>"
              "<text x='24' y='82' font-family='sans-serif' font-size='16' fill='white'>Mock fixture · deferred display</text></svg>"))
    ;; Construct in the file's directory, display elsewhere: the original failure.
    (let ((default-directory (file-name-as-directory fixtures)))
      ;; Use the image API directly: Markdown's own path resolver would
      ;; mask this relative-descriptor bug before the viewer saw it.
      (setq picture (harness-ui-image-string relative "image/svg+xml")
            rendered
            (concat (harness-ui-markdown-render
                     "# Freeze regression\n\n## Readable relative image")
                    "\n\n" picture "\n"
                    (harness-ui-markdown-render "## Missing relative image")
                    "\n\n"
                    (harness-ui-image-string "docs/media/voice-ribbon-review/absent.png" "image/png")
                    "\n"
                    (harness-ui-markdown-render
                     "## Timing evidence\n\nSynthetic handler: 350 ms · content-free completion record\n"))))
    (with-current-buffer buffer
      (special-mode)
      (setq-local default-directory harness-dev-root)
      (let ((inhibit-read-only t)) (erase-buffer) (insert rendered) (goto-char (point-min))))
    (harness-dev-show (buffer-name buffer))
    (let ((image (get-text-property 0 'display picture)))
      (unless (and (eq (car-safe image) 'image)
                   (file-name-absolute-p (plist-get (cdr image) :file)))
        (error "Relative image descriptor"))
      (image-flush image)
      (unless (> (car (image-size image t)) 100)
        (error "Deferred image size")))
    (harness-latency-call 'demo 'synthetic-handler #'sleep-for 0.35)
    (harness-latency-flush)
    (list :buffer (buffer-name buffer) :mock t :latency-file (harness-latency-file))))
