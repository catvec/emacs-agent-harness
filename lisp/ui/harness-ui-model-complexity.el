;;; harness-ui-model-complexity.el --- Plain-language model complexity guide  -*- lexical-binding: t; -*-

;;; Commentary:

;; Optional UI half of model-complexity.  The guide and the session/task
;; model picker show the same low-to-high estimated work levels.  Real
;; model names and ids stay intact; choosing a model still goes through
;; the usual handoff checks.  Nothing is selected merely by opening the
;; guide, and unknown models are explicitly Unrated, after ranked ones.
;;
;; The backend supplies the rules and their explanations over ACP, so
;; this UI also works with a remote harness.  No provider code or model
;; routing heuristic runs here.  If that harness lacks the optional
;; method, the normal model picker remains usable.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defconst harness-ui-model-complexity--buffer-name "*harness model complexity*"
  "Name of the model complexity guide buffer.")

(defface harness-model-complexity-heading-face '((t :inherit bold :height 1.15))
  "Plain task-level headings in the model complexity guide."
  :group 'harness-ui)

(defvar-local harness-ui-model-complexity--rows nil
  "Ranked model plists last received from the harness.")

(defvar-local harness-ui-model-complexity--state 'loading
  "State of the guide: loading, ready or error.")

(defvar-local harness-ui-model-complexity--generation 0
  "Request counter used to ignore superseded catalogue answers.")

(defun harness-ui-model-complexity--label (model)
  "Return MODEL's real display name, qualified by its provider."
  (let ((label (or (plist-get model :label) (plist-get model :name) (plist-get model :id)))
        (provider (or (plist-get model :provider-label) (plist-get model :provider))))
    (if provider (format "%s (%s)" label provider) label)))

(defun harness-ui-model-complexity--read (models callback)
  "Browse ranked MODELS and call CALLBACK with the chosen real (ID LABEL).
Open on the flat low-to-high list, headed as an estimate, and offer the
shared provider/category navigation from there: Back goes to providers
and their families.  Model rows keep the backend's ordering."
  (harness-ui-read-model models callback t
                         "Model · estimated work complexity, low to high: "))

(defun harness-ui-model-complexity--pick (callback)
  "Handle a model picker for CALLBACK using the optional complexity guide.
Return non-nil immediately; the catalogue is fetched asynchronously.
Fall back to the normal picker when the connected harness cannot rank."
  (let ((frame (selected-frame)))
    (message "Model catalogue loading…")
    (harness-ui-call
     "_harness/model-complexity/list" (list :refresh t)
     (lambda (models)
       (when (frame-live-p frame)
         (harness-ui--in-frame frame
                               (lambda () (harness-ui-model-complexity--read models callback)))))
     (lambda (_err)
       (when (frame-live-p frame)
         (harness-ui--in-frame
          frame (lambda ()
                  (message "Complexity guide unavailable")
                  (harness-ui--choose-model callback)))))))
  t)

(defun harness-ui-model-complexity--insert-model (model)
  "Insert a MODEL with its real name, provider, id and ranking basis."
  (let ((start (point))
        (basis (or (plist-get model :complexity-basis) "No matching rule")))
    (insert "    " (harness-ui-model-complexity--label model)
            (if (string-prefix-p "User rule" basis) "  [user estimate]" "") "\n"
            "      " (propertize (plist-get model :id) 'face 'harness-dim-face) "\n")
    (add-text-properties start (point)
                         (list 'harness-model-id (plist-get model :id)
                               'help-echo basis))))

(defun harness-ui-model-complexity--render ()
  "Draw the guide from this buffer's current rows and request state."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (insert " Model complexity    ")
    (harness-ui-button "[Refresh]" #'harness-ui-model-complexity-refresh)
    (insert "\n\n Low to high work complexity. Estimates, not benchmarks.\n"
            " Models at the same level are not ranked against each other.\n"
            " No rank is inferred from price, context size or thinking settings.\n\n")
    (pcase harness-ui-model-complexity--state
      ('loading (insert " Loading the model catalogue…\n"))
      ('error (insert (propertize " The complexity guide could not be loaded.\n" 'face 'warning)
                      " Check the connection and enable model-complexity on the harness.\n"
                      " Press g to retry. The normal model picker is still available.\n"))
      ('ready
       (if (null harness-ui-model-complexity--rows)
           (insert " No models are listed. Configure a provider or sign in, then press g.\n")
         (let ((previous :none))
           (dolist (model harness-ui-model-complexity--rows)
             (let ((level (plist-get model :complexity-label)))
               (unless (equal previous level)
                 (unless (eq previous :none) (insert "\n"))
                 (insert " " (propertize level 'face 'harness-model-complexity-heading-face) "\n"
                         "   " (or (plist-get model :complexity-description)
                                   "No matching rule; task suitability is unknown.") "\n")
                 (setq previous level))
               (harness-ui-model-complexity--insert-model model)))))))
    (insert "\n Rankings are an editable guide, not a guarantee of success.\n"
            " Change harness-model-complexity-rules in the harness settings.\n"
            " g refreshes; w copies the model ID at point; q goes back.\n")
    (goto-char (point-min))
    (forward-line (1- line))))

(defun harness-ui-model-complexity--load (buffer &optional refresh)
  "Load ranked models into BUFFER; REFRESH asks providers to list again."
  (with-current-buffer buffer
    (let ((generation (cl-incf harness-ui-model-complexity--generation)))
      (setq harness-ui-model-complexity--state 'loading)
      (harness-ui-model-complexity--render)
      (harness-ui-call
       "_harness/model-complexity/list" (and refresh (list :refresh t))
       (lambda (rows)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= generation harness-ui-model-complexity--generation)
               (setq harness-ui-model-complexity--rows rows
                     harness-ui-model-complexity--state 'ready)
               (harness-ui-model-complexity--render)))))
       (lambda (_err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= generation harness-ui-model-complexity--generation)
               (setq harness-ui-model-complexity--state 'error)
               (harness-ui-model-complexity--render)))))))))

(defun harness-ui-model-complexity-refresh ()
  "Refresh the model complexity guide from the connected harness."
  (interactive)
  (harness-ui-model-complexity--load (current-buffer) t))

(defun harness-ui-model-complexity-copy-id ()
  "Copy the real model id at point, without changing any session."
  (interactive)
  (let ((id (get-text-property (point) 'harness-model-id)))
    (unless id (user-error "Put point on a model name or id first"))
    (kill-new id)
    (message "Copied %s" id)))

(defvar harness-ui-model-complexity-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "g") #'harness-ui-model-complexity-refresh)
    (define-key map (kbd "w") #'harness-ui-model-complexity-copy-id)
    map)
  "Keymap of the model complexity guide.")

(define-derived-mode harness-ui-model-complexity-mode special-mode "Model complexity"
  "Browse estimated work levels without changing a model or its settings."
  (setq truncate-lines nil
        word-wrap t))

(put 'harness-ui-model-complexity-mode 'harness-menu-group
     '("Model complexity"
       ["Guide"
        (". g" "Refresh model catalogue" harness-ui-model-complexity-refresh)
        (". w" "Copy model ID" harness-ui-model-complexity-copy-id)]))

;;;###autoload
(defun harness-model-complexity ()
  "Show available model names from low to high estimated work complexity.
The levels are Simple tasks, Routine tasks, Complex tasks and Very
complex tasks.  Unknown models are Unrated, after the ranked models.
Real model names and ids remain visible.  Nothing is selected or run."
  (interactive)
  (let ((buffer (get-buffer-create harness-ui-model-complexity--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-model-complexity-mode)
        (harness-ui-model-complexity-mode)))
    (harness-ui-display-view buffer)
    (harness-ui-model-complexity--load buffer)))

(defun harness-ui-model-complexity--init ()
  "Offer the ranked picker and bind the guide under the harness prefix."
  (add-hook 'harness-ui-model-picker-functions #'harness-ui-model-complexity--pick)
  (unless (lookup-key harness-ui-map (kbd "="))
    (define-key harness-ui-map (kbd "=") #'harness-model-complexity)))

(defun harness-ui-model-complexity--shutdown ()
  "Remove the ranked picker and its guide binding."
  (remove-hook 'harness-ui-model-picker-functions #'harness-ui-model-complexity--pick)
  (when (eq (lookup-key harness-ui-map (kbd "=")) #'harness-model-complexity)
    (define-key harness-ui-map (kbd "=") nil t)))

(harness-define-module 'ui-model-complexity
		       :doc "Model names sorted by plain-language estimated work complexity."
		       :requires '(ui)
		       :init #'harness-ui-model-complexity--init
		       :shutdown #'harness-ui-model-complexity--shutdown)

(provide 'harness-ui-model-complexity)
;;; harness-ui-model-complexity.el ends here
