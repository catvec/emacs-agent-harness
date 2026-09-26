;;; harness-core.el --- Kernel: modules, services, events, deferreds -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; The kernel knows nothing about agents, sessions, ACP or the UI.  It gives
;; the other modules three things and gets out of the way:
;;
;;   - modules: how a feature file declares itself, loads its dependencies
;;     and can be torn down or reloaded,
;;   - services: named APIs other modules call (the D-Bus analogue),
;;   - events: typed notifications modules publish without knowing who
;;     listens.
;;
;; Plus `harness-deferred', the single async primitive every module uses so
;; that callers can compose non-blocking work.
;;
;; Nothing here starts timers, processes or buffers at load time.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'time-date)

(define-error 'harness-error "Harness error")
(define-error 'harness-service-missing "Harness service missing" 'harness-error)
(define-error 'harness-module-error "Harness module error" 'harness-error)
(define-error 'harness-cancelled "Cancelled" 'harness-error)

(defgroup harness nil
  "Emacs Agent Harness."
  :group 'tools
  :prefix "harness-")

(defcustom harness-debug nil
  "When non-nil, log harness internals to the *harness-log* buffer."
  :type 'boolean)

(defcustom harness-debug-log-limit 20000
  "Maximum number of characters kept in the *harness-log* buffer."
  :type 'natnum)

(defconst harness-version "0.1.0"
  "Version of the harness kernel.")

(defun harness-uuid ()
  "Return a fresh UUID string, e.g. 2f9a...-..."
  (let ((hex (secure-hash 'md5 (format "%s-%s-%s" (float-time) (random) (gensym)))))
    (format "%s-%s-%s-%s-%s"
            (substring hex 0 8) (substring hex 8 12) (substring hex 12 16)
            (substring hex 16 20) (substring hex 20 32))))

(defun harness-now ()
  "Return the current time as a float."
  (float-time))

(defun harness-iso-time (&optional time)
  "Format TIME (default now) as an ISO 8601 UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" (or time (current-time)) t))

(defun harness-log (format-string &rest args)
  "Log a message when `harness-debug' is non-nil.
FORMAT-STRING and ARGS are passed to `format'."
  (when harness-debug
    (let ((line (format "%s %s\n"
                        (format-time-string "%H:%M:%S.%3N")
                        (apply #'format format-string args)))
          (buffer (get-buffer-create "*harness-log*")))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert line)
        (when (> (buffer-size) harness-debug-log-limit)
          (delete-region (point-min) (- (point-max) (/ harness-debug-log-limit 2))))))))

(defmacro harness-time (label &rest body)
  "Evaluate BODY and log how long it took under LABEL."
  (declare (indent 1) (debug t))
  `(let ((start (harness-now)))
     (prog1 (progn ,@body)
       (harness-log "%s took %.1fms" ,label (* 1000 (- (harness-now) start))))))

;;; Deferreds

(cl-defstruct (harness-deferred (:constructor harness-deferred--make))
  (state 'pending)
  value
  (callbacks nil)                        ; ((on-value . on-error) ...)
  (cancel-hooks nil))

(defun harness-deferred-new ()
  "Return a new, pending deferred."
  (harness-deferred--make))

(defun harness-deferred-p (object)
  "Return non-nil when OBJECT is a `harness-deferred'."
  (harness-deferred--p object))

(defun harness-deferred-pending-p (deferred)
  "Return non-nil when DEFERRED has not settled."
  (eq (harness-deferred-state deferred) 'pending))

(defun harness-deferred-resolved-p (deferred)
  "Return non-nil when DEFERRED has resolved successfully."
  (eq (harness-deferred-state deferred) 'resolved))

(defun harness-deferred-rejected-p (deferred)
  "Return non-nil when DEFERRED was rejected or cancelled."
  (memq (harness-deferred-state deferred) '(rejected cancelled)))

(defun harness-deferred--settle (deferred state value)
  "Settle DEFERRED as STATE with VALUE and run its callbacks."
  (when (harness-deferred-pending-p deferred)
    (setf (harness-deferred-state deferred) state
          (harness-deferred-value deferred) value
          (harness-deferred-cancel-hooks deferred) nil)
    (dolist (callback (nreverse (harness-deferred-callbacks deferred)))
      (harness-deferred--invoke deferred callback))))

(defun harness-deferred--invoke (deferred callback)
  "Run CALLBACK for DEFERRED according to its settled state."
  (let ((on-value (car callback))
        (on-error (cdr callback)))
    (pcase (harness-deferred-state deferred)
      ('resolved (when on-value (funcall on-value (harness-deferred-value deferred))))
      (_ (when on-error (funcall on-error (harness-deferred-value deferred)))))))

(defun harness-deferred-resolve (deferred &optional value)
  "Resolve DEFERRED with VALUE."
  (harness-deferred--settle deferred 'resolved value)
  deferred)

(defun harness-deferred-reject (deferred error)
  "Reject DEFERRED with ERROR.
ERROR is a cons (SYMBOL . DATA) as produced by `condition-case'."
  (harness-deferred--settle deferred
                            (if (eq (car-safe error) 'harness-cancelled)
                                'cancelled
                              'rejected)
                            error)
  deferred)

(defun harness-deferred-cancel (deferred &optional reason)
  "Cancel DEFERRED, running its cancel hooks.
REASON is passed to the rejection handlers."
  (when (harness-deferred-pending-p deferred)
    (dolist (hook (harness-deferred-cancel-hooks deferred))
      (condition-case err
          (funcall hook)
        (error (harness-log "cancel hook error: %S" err))))
    (harness-deferred--settle deferred 'cancelled
                              (cons 'harness-cancelled
                                    (or reason "cancelled"))))
  deferred)

(defun harness-deferred-on-cancel (deferred function)
  "Call FUNCTION if DEFERRED is cancelled.
If DEFERRED is already settled, FUNCTION is not called."
  (if (harness-deferred-pending-p deferred)
      (push function (harness-deferred-cancel-hooks deferred))
    (harness-log "on-cancel registered on settled deferred"))
  deferred)

(defun harness-deferred-then (deferred on-value &optional on-error)
  "Chain ON-VALUE (and ON-ERROR) onto DEFERRED, returning a new deferred.
When ON-VALUE returns a deferred, the returned deferred adopts it."
  (let ((next (harness-deferred-new)))
    (harness-deferred--observe
     deferred
     (lambda (value)
       (condition-case err
           (let ((result (funcall on-value value)))
             (if (harness-deferred-p result)
                 (harness-deferred-adopt next result)
               (harness-deferred-resolve next result)))
         (error (harness-deferred-reject next (cons (car err) (cdr err))))))
     (lambda (error)
       (if on-error
           (condition-case err
               (let ((result (funcall on-error error)))
                 (if (harness-deferred-p result)
                     (harness-deferred-adopt next result)
                   (harness-deferred-resolve next result)))
             (error (harness-deferred-reject next (cons (car err) (cdr err)))))
         (harness-deferred--settle next
                                   (harness-deferred-state deferred)
                                   error))))
    next))

(defun harness-deferred--observe (deferred on-value on-error)
  "Arrange for ON-VALUE or ON-ERROR to run when DEFERRED settles."
  (if (harness-deferred-pending-p deferred)
      (push (cons on-value on-error) (harness-deferred-callbacks deferred))
    (harness-deferred--invoke deferred (cons on-value on-error))))

(defun harness-deferred-adopt (target source)
  "Make TARGET settle the same way SOURCE does and return TARGET."
  (harness-deferred--observe
   source
   (lambda (value) (harness-deferred-resolve target value))
   (lambda (error)
     (harness-deferred--settle target (harness-deferred-state source) error)))
  target)

(defun harness-deferred-finally (deferred function)
  "Call FUNCTION with no arguments when DEFERRED settles either way.
Returns a deferred that settles like DEFERRED after FUNCTION ran."
  (harness-deferred-then
   deferred
   (lambda (value) (funcall function) value)
   (lambda (error)
     (funcall function)
     (harness-deferred-reject (harness-deferred-new) error))))

(defun harness-deferred-all (deferreds)
  "Return a deferred resolving to a list of the values of DEFERREDS."
  (let ((result (harness-deferred-new))
        (remaining (length deferreds))
        (values (make-list (length deferreds) nil))
        (failed nil))
    (if (zerop remaining)
        (harness-deferred-resolve result nil)
      (cl-loop for d in deferreds
               for index from 0
               do (let ((i index))
                    (harness-deferred-then
                     d
                     (lambda (value)
                       (unless failed
                         (setf (nth i values) value)
                         (when (zerop (cl-decf remaining))
                           (harness-deferred-resolve result values))))
                     (lambda (error)
                       (unless failed
                         (setq failed t)
                         (harness-deferred-reject result error))))))
      result)))

;;; Modules

(cl-defstruct (harness-module (:constructor harness-module--make))
  name version description requires provides file setup teardown
  (state 'defined))

(defvar harness-core--modules (make-hash-table :test #'eq)
  "Module name -> `harness-module'.")

(defvar harness-core--loading nil
  "Stack of modules currently being loaded, for cycle detection.")

(defvar harness-core--current-module nil
  "Module whose setup or teardown is running.
Registries use it to attribute registrations to a module.")

(defun harness-module--version-ok-p (required available)
  "Return non-nil when AVAILABLE satisfies REQUIRED version string."
  (or (null required) (null available) (version<= required available)))

(defun harness-module-define (name &rest properties)
  "Define the module NAME, a symbol, with PROPERTIES.
Accepted properties:

  :version     version string

  :description one-line description

  :requires    list of (FEATURE VERSION) dependencies

  :provides    list of features provided (informational)

  :setup       function called after dependencies are set up

  :teardown    function called before unloading

This should be the first form in a module file.  Defining a module does not
load it."
  (declare (indent 1))
  (let ((manifest (harness-module--make
                   :name name
                   :version (plist-get properties :version)
                   :description (plist-get properties :description)
                   :requires (plist-get properties :requires)
                   :provides (plist-get properties :provides)
                   :setup (plist-get properties :setup)
                   :teardown (plist-get properties :teardown)
                   :file (or load-file-name buffer-file-name))))
    (puthash name manifest harness-core--modules)
    manifest))

(defun harness-module-manifest (name)
  "Return the manifest for module NAME or nil."
  (gethash name harness-core--modules))

(defun harness-module-set-up-p (name)
  "Return non-nil when module NAME has run its setup."
  (let ((manifest (harness-module-manifest name)))
    (and manifest (eq (harness-module-state manifest) 'set-up))))

(defun harness-module-load (name)
  "Load module NAME, its dependencies, and run its setup.
Returns the module manifest.  Loading an already set-up module is a no-op."
  (interactive
   (list (intern (completing-read "Module: " (mapcar #'symbol-name (harness-module-list))))))
  (let ((manifest (harness-module-manifest name)))
    (cond
     ((and manifest (eq (harness-module-state manifest) 'set-up))
      manifest)
     ((memq name harness-core--loading)
      (signal 'harness-module-error
              (list (format "Circular module dependency: %s"
                            (string-join (mapcar #'symbol-name
                                                 (append harness-core--loading (list name)))
                                         " -> ")))))
     (t
      (let ((harness-core--loading (cons name harness-core--loading)))
        (harness-log "loading module %s" name)
        ;; The file must register a manifest when loaded.
        (condition-case err
            (unless (featurep name)
              (require name))
          (error
           (setf (harness-module-state
                  (or (harness-module-manifest name)
                      (harness-module-define name :description "failed to load")))
                 'error)
           (signal (car err) (cdr err))))
        (setq manifest (harness-module-manifest name))
        (unless manifest
          (signal 'harness-module-error
                  (list (format "%s was loaded but did not call `harness-module-define'"
                                name))))
        (dolist (dependency (harness-module-requires manifest))
          (let* ((dep-name (if (consp dependency) (car dependency) dependency))
                 (dep-version (and (consp dependency) (cadr dependency)))
                 (dep-manifest (harness-module-load dep-name)))
            (unless (harness-module--version-ok-p dep-version (harness-module-version dep-manifest))
              (setf (harness-module-state manifest) 'error)
              (signal 'harness-module-error
                      (list (format "%s requires %s %s but %s is installed"
                                    name dep-name dep-version
                                    (or (harness-module-version dep-manifest) "unknown")))))))
        (when (harness-module-setup manifest)
          (let ((harness-core--current-module name))
            (condition-case err
                (funcall (harness-module-setup manifest))
              (error
               (setf (harness-module-state manifest) 'error)
               (signal (car err) (cdr err))))))
        (setf (harness-module-state manifest) 'set-up)
        manifest)))))

(defun harness-module-unload (name)
  "Tear down module NAME and unload its feature.
Services and event handlers registered by the module are removed."
  (interactive (list (intern (completing-read "Module: " (mapcar #'symbol-name (harness-module-list))))))
  (let ((manifest (harness-module-manifest name)))
    (when manifest
      (when (eq (harness-module-state manifest) 'set-up)
        (let ((harness-core--current-module name))
          (when (harness-module-teardown manifest)
            (funcall (harness-module-teardown manifest)))))
      (harness-core--unregister-module name)
      (when (featurep name)
        (unload-feature name t))
      (remhash name harness-core--modules)
      (harness-log "unloaded module %s" name)))
  nil)

(defun harness-module-reload (name)
  "Reload module NAME: teardown, unload, load and set up again."
  (interactive (list (intern (completing-read "Module: " (mapcar #'symbol-name (harness-module-list))))))
  (harness-module-unload name)
  (harness-module-load name))

(defun harness-module-list ()
  "Return a list of all known module names."
  (sort (hash-table-keys harness-core--modules) #'string<))

(defun harness-core--unregister-module (name)
  "Remove every service and event handler attributed to module NAME."
  (let ((services nil))
    (maphash (lambda (service-key service)
               (when (eq (harness-service-module service) name)
                 (push service-key services)))
             harness-core--services)
    (dolist (service-key services)
      (remhash service-key harness-core--services)
      (harness-log "service %s removed with module %s" service-key name)))
  (let ((events nil))
    (maphash (lambda (event handlers)
               (when (seq-some (lambda (handler)
                                 (eq (harness-event-handler-module handler) name))
                               handlers)
                 (push event events)))
             harness-core--event-handlers)
    (dolist (event events)
      (let ((remaining (seq-remove (lambda (handler)
                                     (eq (harness-event-handler-module handler) name))
                                   (gethash event harness-core--event-handlers))))
        (if remaining
            (puthash event remaining harness-core--event-handlers)
          (remhash event harness-core--event-handlers))))))

;;; Services

(cl-defstruct (harness-service (:constructor harness-service--make))
  name module doc methods data)

(defvar harness-core--services (make-hash-table :test #'equal)
  "Service name (string) -> `harness-service'.")

(defun harness-service-register (name &rest properties)
  "Register service NAME with PROPERTIES.
NAME is a string.  PROPERTIES:

  :methods alist of (METHOD . FUNCTION)
  :doc     one-line description
  :data    arbitrary data the service exposes (introspection only)
  :module  owning module, defaults to the module currently being set up

Registering an existing name replaces it (with a warning)."
  (declare (indent 1))
  (let ((service (harness-service--make
                  :name name
                  :module (or (plist-get properties :module) harness-core--current-module)
                  :doc (plist-get properties :doc)
                  :methods (plist-get properties :methods)
                  :data (plist-get properties :data))))
    (when (gethash name harness-core--services)
      (harness-log "service %s re-registered by %s" name (harness-service-module service)))
    (puthash name service harness-core--services)
    service))

(defun harness-service-unregister (name)
  "Remove service NAME."
  (remhash name harness-core--services))

(defun harness-service-get (name)
  "Return the service named NAME, or nil."
  (gethash name harness-core--services))

(defun harness-service-available-p (name &optional method)
  "Return non-nil when service NAME exists, and METHOD when given."
  (let ((service (harness-service-get name)))
    (and service
         (or (null method)
             (assq method (harness-service-methods service))))))

(defun harness-service-call (name method &rest arguments)
  "Call METHOD of service NAME with ARGUMENTS.
Signals `harness-service-missing' if the service or method does not exist."
  (let* ((service (harness-service-get name))
         (function (and service (cdr (assq method (harness-service-methods service))))))
    (unless function
      (signal 'harness-service-missing
              (list (format "No service method %s/%s" name method))))
    (harness-log "service call %s/%s %S" name method arguments)
    (apply function arguments)))

(defun harness-service-method-names (name)
  "Return the method names of service NAME."
  (let ((service (harness-service-get name)))
    (mapcar #'car (and service (harness-service-methods service)))))

(defun harness-service-list ()
  "Return a list of registered service names."
  (sort (hash-table-keys harness-core--services) #'string<))

(defun harness-service-describe (&optional name)
  "Describe service NAME, or all services when NAME is nil."
  (if name
      (let ((service (harness-service-get name)))
        (unless service (user-error "No such service: %s" name))
        (list :name (harness-service-name service)
              :module (harness-service-module service)
              :doc (harness-service-doc service)
              :methods (harness-service-method-names name)
              :data (harness-service-data service)))
    (mapcar #'harness-service-describe (harness-service-list))))

;;; Events

(cl-defstruct (harness-event (:constructor harness-event--make))
  name module doc payload)

(cl-defstruct (harness-event-handler (:constructor harness-event-handler--make))
  function module predicate key)

(defvar harness-core--event-registry (make-hash-table :test #'eq)
  "Event name -> `harness-event'.")

(defvar harness-core--event-handlers (make-hash-table :test #'eq)
  "Event name -> list of `harness-event-handler'.")

(defvar harness-core--undeclared-events-allowed nil
  "When non-nil, `harness-emit' accepts undeclared events (tests).")

(defun harness-event-define (name &rest properties)
  "Declare event NAME, a symbol, with PROPERTIES.
PROPERTIES:

  :doc     one-line description
  :payload alist of (KEY . TYPE-DESCRIPTION) documenting the payload
  :module  publishing module, defaults to the module being set up"
  (declare (indent 1))
  (puthash name
           (harness-event--make :name name
                                :module (or (plist-get properties :module)
                                            harness-core--current-module)
                                :doc (plist-get properties :doc)
                                :payload (plist-get properties :payload))
           harness-core--event-registry)
  name)

(defun harness-event-describe (name)
  "Return the declaration of event NAME."
  (let ((event (gethash name harness-core--event-registry)))
    (unless event (user-error "No such event: %s" name))
    (list :name (harness-event-name event)
          :module (harness-event-module event)
          :doc (harness-event-doc event)
          :payload (harness-event-payload event))))

(defun harness-event-list ()
  "Return all declared event names."
  (sort (hash-table-keys harness-core--event-registry) #'string<))

(defun harness-on (event function &rest properties)
  "Call FUNCTION whenever EVENT is emitted.
PROPERTIES:

  :module    owner, defaults to the module being set up
  :predicate optional function called with the payload; handler runs when
             it returns non-nil
  :key       optional identity for the handler, so it can be replaced

Returns a handler object for `harness-off'."
  (declare (indent 1))
  (let* ((key (plist-get properties :key))
         (handler (harness-event-handler--make
                   :function function
                   :module (or (plist-get properties :module) harness-core--current-module)
                   :predicate (plist-get properties :predicate)
                   :key key))
         (handlers (gethash event harness-core--event-handlers)))
    (when key
      (setq handlers (seq-remove (lambda (existing)
                                   (eq (harness-event-handler-key existing) key))
                                 handlers)))
    (puthash event (append handlers (list handler)) harness-core--event-handlers)
    handler))

(defun harness-off (event handler)
  "Remove HANDLER from EVENT.
HANDLER may also be the function object passed to `harness-on'."
  (puthash event
           (seq-remove (lambda (existing)
                         (or (eq existing handler)
                             (eq (harness-event-handler-function existing) handler)))
                       (gethash event harness-core--event-handlers))
           harness-core--event-handlers))

(defun harness-once (event function &rest properties)
  "Call FUNCTION the next time EVENT is emitted, then remove it."
  (let (handler)
    (setq handler
          (apply #'harness-on event
                 (lambda (payload)
                   (harness-off event handler)
                   (funcall function payload))
                 properties))
    handler))

(defun harness-emit (event &rest payload)
  "Emit EVENT with PAYLOAD.
Handlers run in registration order.  Handler errors are logged and do not
prevent other handlers from running."
  (unless (or harness-core--undeclared-events-allowed
              (gethash event harness-core--event-registry))
    (signal 'harness-error (list (format "Undeclared harness event: %s" event))))
  (harness-log "event %s %S" event payload)
  (dolist (handler (reverse (gethash event harness-core--event-handlers)))
    (condition-case err
        (when (or (null (harness-event-handler-predicate handler))
                  (funcall (harness-event-handler-predicate handler) payload))
          (funcall (harness-event-handler-function handler) payload))
      (error
       (harness-log "event handler for %s failed: %S" event err)
       (display-warning 'harness
                        (format "event handler for %s failed: %S" event err)
                        :warning)))))

(defun harness-emit-later (event &rest payload)
  "Emit EVENT with PAYLOAD after the current command finishes."
  (harness-defer (lambda () (apply #'harness-emit event payload))))

;;; Scheduling

(defun harness-defer (function)
  "Call FUNCTION with no arguments after the current command finishes."
  (run-at-time 0 nil function))

(defvar harness-core--batch-timers (make-hash-table :test #'equal)
  "Batch key -> (TIMER . FUNCTION).")

(defun harness-batch (key delay function)
  "Coalesce calls sharing KEY; call FUNCTION once after DELAY seconds.
Under a continuous stream this becomes periodic flushing: FUNCTION runs
once per DELAY as long as it is being called.  FUNCTION receives no
arguments and should read the latest state for KEY."
  (unless (gethash key harness-core--batch-timers)
    (let ((entry (cons nil function)))
      (setcar entry
              (run-at-time delay nil
                           (lambda ()
                             (when (eq (gethash key harness-core--batch-timers) entry)
                               (remhash key harness-core--batch-timers)
                               (funcall function)))))
      (puthash key entry harness-core--batch-timers))))

(defun harness-batch-flush (key)
  "Run the pending batch for KEY now, if any."
  (let ((entry (gethash key harness-core--batch-timers)))
    (when entry
      (cancel-timer (car entry))
      (remhash key harness-core--batch-timers)
      (funcall (cdr entry))))
  nil)

(defun harness-budget-run (seconds function)
  "Call FUNCTION repeatedly until it returns nil or SECONDS have elapsed.
FUNCTION receives no arguments and returns non-nil while there is more work."
  (let ((end (+ (harness-now) seconds))
        (more t))
    (while (and more (< (harness-now) end))
      (setq more (funcall function)))
    more))

;;; Introspection

;;;###autoload
(defun harness-describe ()
  "Show the harness module, service and event registries."
  (interactive)
  (with-current-buffer (get-buffer-create "*harness-describe*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "Modules\n=======\n")
      (dolist (name (harness-module-list))
        (let ((manifest (harness-module-manifest name)))
          (insert (format "%-28s %-8s %s\n" name
                          (harness-module-state manifest)
                          (or (harness-module-description manifest) "")))))
      (insert "\nServices\n========\n")
      (dolist (service (harness-service-list))
        (let ((description (harness-service-describe service)))
          (insert (format "%s — %s\n" service (or (plist-get description :doc) "")))
          (dolist (method (plist-get description :methods))
            (insert (format "  %s\n" method)))))
      (insert "\nEvents\n======\n")
      (dolist (event (harness-event-list))
        (let ((description (harness-event-describe event)))
          (insert (format "%s — %s\n" event (or (plist-get description :doc) "")))
          (dolist (entry (plist-get description :payload))
            (insert (format "  %s: %s\n" (car entry) (cdr entry))))))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer)))))

;; The kernel declares itself as a module like everything else, so that
;; dependency declarations such as (:requires ((harness-core "0.1.0"))) are
;; uniform.  It has no setup of its own.
(harness-module-define 'harness-core
  :version harness-version
  :description "Kernel: modules, services, events and deferreds."
  :provides '(harness-core))

(provide 'harness-core)
;;; harness-core.el ends here
