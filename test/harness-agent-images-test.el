;;; harness-agent-images-test.el --- Tool-result images reach the model  -*- lexical-binding: t; -*-

;;; Commentary:

;; read_file on an image returns the file as the result's `:images', the
;; pictures the *model* is to see (the `:attachments' are what the chat
;; shows the user).  These tests follow them through the agent and the
;; transcript:
;;
;; - a hosted loop is handed them with the result, as base64 `:images',
;;   when its model reads images, and told in the text that only the user
;;   sees them when it does not;
;; - the result's node keeps their paths and never their bytes;
;; - `session/messages' gives them to a native provider as the `:images'
;;   of the tool_result block, and the request is made ready with them
;;   (inlined, left out with a note, or capped to the newest 16);
;; - nothing is read for a loop that has no use for the bytes.
;;
;; The two providers here list one model that reads images, "eyes", and
;; one that does not, "blind".

;;; Code:

(require 'harness-test-helpers)

(defvar harness-agent--turns)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent-history-images)
(defvar harness-tools-max-output-chars)
(defvar harness-secrets-mask)
(defvar harness-secrets-sources)
(defvar harness-naming-auto)
(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-compaction--context-reserve)
(defvar harness-compaction--running)
(defvar harness-compaction--pending)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-define-tool "harness-tools")
(declare-function harness-tool-ok "harness-tools")
(declare-function harness-tool-error "harness-tools")
(declare-function harness-agent--file-base64 "harness-agent" (path))
(declare-function harness-agent--prepare-block "harness-agent" (block session))
(declare-function harness-agent--prepare-messages "harness-agent" (session messages))
(declare-function harness-agent--request-messages "harness-agent" (session))
(declare-function harness-agent-strip-result-images "harness-agent" (messages))
(declare-function harness-naming--messages "harness-naming" (session-id))
(declare-function harness-secrets-forget "harness-secrets")
(declare-function harness-secrets--prime "harness-secrets")

;;;; Setup

(defvar harness-agent-images-test-requests nil
  "The requests the providers were sent, oldest first.")

(defvar harness-agent-images-test-responses nil
  "The results the agent answered `hosted' with, whole, oldest first.")

(defvar harness-agent-images-test-result nil
  "A function of the call's input returning what the `look' tool returns.")

(defvar harness-agent-images-test-call nil
  "The tool call the providers make: (NAME . INPUT), `look' unless a test says.")

(defun harness-agent-images-test--png (dir)
  "Write the test PNG in DIR as shot.png; return its file name."
  (let ((file (expand-file-name "shot.png" dir))
        (coding-system-for-write 'binary))
    (write-region harness-test-png nil file nil 'silent)
    file))

(defun harness-agent-images-test--look (png)
  "Return what read_file returns for the image PNG: text, attachment and image."
  (harness-tool-ok "Image shot.png attached."
                   :attachments (list (list :path png :mime "image/png" :size 70 :name "shot.png"))
                   :images (list (list :path png :mime "image/png"))))

(defun harness-agent-images-test--models ()
  "Return a promise of the models the providers list."
  (harness-resolved
   (list (list :name "eyes" :context-window 8000 :input-modalities '("text" "image"))
         (list :name "blind" :context-window 8000 :input-modalities '("text")))))

(defun harness-agent-images-test--define-providers ()
  "Define `hosted', which runs its own loop, and `native', which does not.
Each asks for the `look' tool once, then answers.  `hosted' keeps the
result the agent answers it with, `native' the requests it is sent."
  (harness-define-provider
   'hosted
   :label "Hosted" :models #'harness-agent-images-test--models :capabilities '(:hosted-loop t)
   :complete
   (lambda (request)
     (let ((on-event (plist-get request :on-event)))
       (setq harness-agent-images-test-requests (append harness-agent-images-test-requests (list request)))
       (run-at-time
        0.005 nil
        (lambda ()
          (funcall on-event '(:type start))
          (funcall on-event
                   (list :type 'tool-call :id "h1" :name (car harness-agent-images-test-call)
                         :input (cdr harness-agent-images-test-call)
                         :respond (lambda (result)
                                    (setq harness-agent-images-test-responses
                                          (append harness-agent-images-test-responses (list result)))
                                    (run-at-time 0.005 nil
                                                 (lambda ()
                                                   (funcall on-event '(:type text :delta "Seen."))
                                                   (funcall on-event '(:type done :stop-reason end-turn)))))))))
       (list :cancel #'ignore))))
  (harness-define-provider
   'native
   :label "Native" :models #'harness-agent-images-test--models
   :complete
   (lambda (request)
     (let* ((on-event (plist-get request :on-event))
            (last (car (last (plist-get request :messages))))
            (answered (and last (cl-some (lambda (b) (equal (plist-get b :type) "tool_result"))
                                         (plist-get last :content)))))
       (setq harness-agent-images-test-requests (append harness-agent-images-test-requests (list request)))
       (run-at-time
        0.005 nil
        (lambda ()
          (funcall on-event '(:type start))
          (if answered
              (progn (funcall on-event '(:type text :delta "Seen."))
                     (funcall on-event '(:type done :stop-reason end-turn)))
            (funcall on-event (list :type 'tool-call :id "n1" :name (car harness-agent-images-test-call)
                                    :input (cdr harness-agent-images-test-call)))
            (funcall on-event '(:type done :stop-reason tool-use)))))
       (list :cancel #'ignore)))))

(defmacro harness-agent-images-test-with (&rest body)
  "Load the state layer, the providers and the `look' tool, run BODY.
`png' is the file of a PNG image, and `dir' the state directory."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider tools session agent))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-agent-images-test-requests nil harness-agent-images-test-responses nil
           harness-agent-images-test-call (cons "look" '(:path "shot.png")))
     (harness-add-filter 'permission/decide
                         (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
     (let* ((default-directory dir)
            (png (harness-agent-images-test--png dir)))
       (setq harness-agent-images-test-result
             (lambda (_input) (harness-agent-images-test--look png)))
       (harness-define-tool "look" :label "Look" :description "Show an image." :kind 'read
                            :handler (lambda (input _ctx)
                                       (funcall harness-agent-images-test-result input)))
       (harness-agent-images-test--define-providers)
       ,@body)))

(defun harness-agent-images-test-session (model)
  "Create a session on MODEL and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model model) :id))

(defun harness-agent-images-test-run (id)
  "Run a turn of session ID to its end; return its stop reason."
  (plist-get (harness-test-await (harness-call 'agent/prompt id "look at it")) :stop-reason))

(defun harness-agent-images-test-result-node (id)
  "Return the first tool-result node of session ID."
  (cl-find 'tool-result (harness-call 'session/nodes id) :key (lambda (n) (plist-get n :kind))))

(defconst harness-agent-images-test-b64 (base64-encode-string harness-test-png t)
  "The test PNG in base64, on one line.")

(defconst harness-agent-images-test-blind-note
  "\n\n[This model does not read images: only the user sees this one.]"
  "What the text of a result says when its image goes to a model that cannot read it.")

(defmacro harness-agent-images-test-counting-reads (var &rest body)
  "Run BODY counting in VAR how many image files are read into base64."
  (declare (indent 1))
  `(let ((,var 0)
         (orig (symbol-function 'harness-agent--file-base64)))
     (cl-letf (((symbol-function 'harness-agent--file-base64)
                (lambda (path) (cl-incf ,var) (funcall orig path))))
       ,@body)))

;;;; A hosted loop

(ert-deftest harness-agent-images-hosted-vision-model-is-handed-the-image ()
  "A hosted loop whose model reads images gets them with the result, as base64.
The text is the tool's own; the node keeps the path and the user's
attachment, and no byte of the image."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:eyes")))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (should (= 1 (length harness-agent-images-test-responses)))
      (let ((response (car harness-agent-images-test-responses)))
        (should (equal "Image shot.png attached." (plist-get response :content)))
        (should-not (plist-get response :is-error))
        (should (equal (list (list :mime "image/png" :data harness-agent-images-test-b64 :name "shot.png"))
                       (plist-get response :images))))
      (let ((node (harness-agent-images-test-result-node id)))
        (should (equal "Image shot.png attached." (plist-get node :output)))
        (should (equal (list (list :path png :mime "image/png")) (plist-get node :images)))
        (should (equal "shot.png" (plist-get (car (plist-get node :attachments)) :name)))
        (should-not (string-search harness-agent-images-test-b64 (format "%S" node)))
        (should-not (string-search harness-agent-images-test-b64
                                   (with-temp-buffer
                                     (insert-file-contents-literally
                                      (harness-store-path (harness-session--nodes-name id)))
                                     (buffer-string))))))))

(ert-deftest harness-agent-images-hosted-blind-model-is-told-only-the-user-sees-it ()
  "A hosted loop whose model reads no image gets none, and a note in the text.
The node still keeps the image, for a model that reads them later."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:blind")))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let ((response (car harness-agent-images-test-responses)))
        (should-not (plist-member response :images))
        (should (equal (concat "Image shot.png attached." harness-agent-images-test-blind-note)
                       (plist-get response :content))))
      (let ((node (harness-agent-images-test-result-node id)))
        ;; The transcript keeps the tool's own words.
        (should (equal "Image shot.png attached." (plist-get node :output)))
        (should (equal (list (list :path png :mime "image/png")) (plist-get node :images)))))))

(ert-deftest harness-agent-images-hosted-unreadable-image-is-skipped-with-a-note ()
  "An image whose file cannot be read is left out, and the text says so."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:eyes"))
          (gone (expand-file-name "gone.png" dir)))
      ;; One of two is gone: the other goes.
      (setq harness-agent-images-test-result
            (lambda (_) (harness-tool-ok "two images"
                                         :images (list (list :path gone :mime "image/png")
                                                       (list :path png :mime "image/png")))))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let ((response (car harness-agent-images-test-responses)))
        (should (equal (list (list :mime "image/png" :data harness-agent-images-test-b64 :name "shot.png"))
                       (plist-get response :images)))
        (should (equal (format "two images\n\n[The image this call returned (%s) is gone; read the file again to see it.]"
                               gone)
                       (plist-get response :content))))
      ;; The only one is gone: none goes at all.
      (setq harness-agent-images-test-responses nil)
      (setq harness-agent-images-test-result
            (lambda (_) (harness-tool-ok "one image" :images (list (list :path gone :mime "image/png")))))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let ((response (car harness-agent-images-test-responses)))
        (should-not (plist-member response :images))
        (should (string-suffix-p "is gone; read the file again to see it.]" (plist-get response :content)))))))

(ert-deftest harness-agent-images-hosted-note-comes-before-the-steering ()
  "Steering rides at the end of the text: after the note, never before it."
  (harness-agent-images-test-with
    (let* ((id (harness-agent-images-test-session "hosted:blind")))
      (setq harness-agent-images-test-result
            (lambda (_)
              (harness-call 'agent/prompt id "and mind the margins")
              (harness-agent-images-test--look png)))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (should (equal (concat "Image shot.png attached." harness-agent-images-test-blind-note
                             "\n\n<user_message>\nand mind the margins\n</user_message>")
                     (plist-get (car harness-agent-images-test-responses) :content))))))

;;;; Images a steering message attached

(defun harness-agent-images-test--steer-once (id blocks result)
  "Have the `look' tool send BLOCKS to session ID once, then return RESULT.
BLOCKS reach the running turn as a message of the user's, which steers
it; any later call just returns RESULT."
  (let ((sent nil))
    (setq harness-agent-images-test-result
          (lambda (_)
            (unless sent
              (setq sent t)
              (harness-call 'agent/prompt id blocks))
            result))))

(defun harness-agent-images-test--steering (text &rest images)
  "Return the blocks of a message of TEXT that attached IMAGES."
  (cons (list :type "text" :text text) images))

(ert-deftest harness-agent-images-hosted-steering-image-goes-with-the-result ()
  "A message sent while a hosted loop works hands it its images with the result.
The text reaches the model inside the tool result, as <user_message>;
the image the message attached goes with that result too, labelled with
the token its text names it by, or the model reads of an [image 1] it
never sees.  An image of the message's own data goes as it is; one that
names a file is read."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:eyes")))
      (harness-agent-images-test--steer-once
       id (harness-agent-images-test--steering
           "in [image 1] the button is cut off, unlike [image 2]"
           (list :type "image" :mime "image/png" :data harness-agent-images-test-b64 :label "image 1")
           (list :type "image" :mime "image/png" :path png :label "image 2"))
       (harness-tool-ok "listed"))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (should (= 1 (length harness-agent-images-test-requests)))
      (let ((response (car harness-agent-images-test-responses)))
        (should (equal (concat "listed\n\n<user_message>\n"
                               "in [image 1] the button is cut off, unlike [image 2]"
                               "\n</user_message>")
                       (plist-get response :content)))
        (should (equal (list (list :mime "image/png" :data harness-agent-images-test-b64
                                   :name "image 1" :label "image 1")
                             (list :mime "image/png" :data harness-agent-images-test-b64
                                   :name "shot.png" :label "image 2"))
                       (plist-get response :images))))
      ;; The transcript keeps the message whole, its images on its node.
      (let ((node (car (cl-remove-if-not (lambda (n) (plist-get (plist-get n :meta) :steering))
                                         (harness-call 'session/nodes id)))))
        (should (equal '("text" "image" "image")
                       (mapcar (lambda (b) (plist-get b :type)) (plist-get node :blocks))))))))

(ert-deftest harness-agent-images-hosted-steering-image-follows-the-results-own ()
  "A result's own images go first, then those of the message it carries.
An image without a label goes without one."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:eyes")))
      (harness-agent-images-test--steer-once
       id (harness-agent-images-test--steering
           "and this one" (list :type "image" :mime "image/png" :data "QUJD"))
       (harness-agent-images-test--look png))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let ((response (car harness-agent-images-test-responses)))
        (should (equal "Image shot.png attached.\n\n<user_message>\nand this one [image]\n</user_message>"
                       (plist-get response :content)))
        (should (equal (list (list :mime "image/png" :data harness-agent-images-test-b64 :name "shot.png")
                             (list :mime "image/png" :data "QUJD" :name "image"))
                       (plist-get response :images)))))))

(ert-deftest harness-agent-images-hosted-steering-image-that-cannot-go-is-noted ()
  "A blind model is told only the user sees the message's images; none go.
For a model that reads them, one whose file is gone, or of a type no
provider takes as an image, is left out and the text says so."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:blind")))
      (harness-agent-images-test--steer-once
       id (harness-agent-images-test--steering
           "see [image 1]" (list :type "image" :mime "image/png" :path png :label "image 1"))
       (harness-tool-ok "listed"))
      (harness-agent-images-test-counting-reads reads
        (should (eq 'end-turn (harness-agent-images-test-run id)))
        (should (= 0 reads)))
      (let ((response (car harness-agent-images-test-responses)))
        (should-not (plist-member response :images))
        (should (equal (concat "listed\n\n<user_message>\nsee [image 1]\n</user_message>"
                               "\n\n[This model does not read images: only the user sees the images their message attached.]")
                       (plist-get response :content)))))
    (setq harness-agent-images-test-responses nil)
    (let ((id (harness-agent-images-test-session "hosted:eyes"))
          (gone (expand-file-name "gone.png" dir)))
      (harness-agent-images-test--steer-once
       id (harness-agent-images-test--steering
           "see [image 1], [image 2] and [image 3]"
           (list :type "image" :mime "image/png" :path gone :label "image 1")
           (list :type "image" :mime "image/svg+xml" :data "PHN2Zz4=" :label "image 2")
           (list :type "image" :mime "image/png" :path png :label "image 3"))
       (harness-tool-ok "listed"))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let ((response (car harness-agent-images-test-responses)))
        (should (equal (list (list :mime "image/png" :data harness-agent-images-test-b64
                                   :name "shot.png" :label "image 3"))
                       (plist-get response :images)))
        (should (equal (concat "listed\n\n<user_message>\nsee [image 1], [image 2] and [image 3]\n</user_message>"
                               (format "\n\n[The image [image 1] the user attached could not be sent: %s is gone.]" gone)
                               "\n\n[The image [image 2] the user attached could not be sent: the model takes no image of type image/svg+xml.]")
                       (plist-get response :content)))))))

(ert-deftest harness-agent-images-hosted-steering-images-wait-out-a-failed-call ()
  "A failed call's result is text: steering with images waits for the next boundary.
Here that is the next step, whose request ends with the message, its
image in it, as the trailing user message a hosted loop sends.  Its
text is not sent twice, nor before the image."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:eyes")))
      (harness-agent-images-test--steer-once
       id (harness-agent-images-test--steering
           "look at [image 1]"
           (list :type "image" :mime "image/png" :data harness-agent-images-test-b64 :label "image 1"))
       (harness-tool-error "could not look"))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (should (= 2 (length harness-agent-images-test-requests)))
      (let ((first (car harness-agent-images-test-responses)))
        (should (equal "could not look" (plist-get first :content)))
        (should-not (plist-member first :images)))
      (should-not (cl-some (lambda (r) (string-search "user_message" (plist-get r :content)))
                           harness-agent-images-test-responses))
      ;; The second request ends with the message, image and all.
      (let* ((request (cadr harness-agent-images-test-requests))
             (last (car (last (plist-get request :messages)))))
        (should (eq 'user (plist-get last :role)))
        (should (equal (list (list "text" "look at [image 1]") (list "text" "[image 1]")
                             (list "image" harness-agent-images-test-b64))
                       (mapcar (lambda (b) (list (plist-get b :type)
                                                 (or (plist-get b :text) (plist-get b :data))))
                               (plist-get last :content))))))))

(ert-deftest harness-agent-images-native-steering-image-is-in-the-next-request ()
  "A loop the harness runs gets a steering message's images with the message.
The next request puts the message after the result that delivered it,
each labelled image after its token, as a message sent first would be."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "native:eyes")))
      (harness-agent-images-test--steer-once
       id (harness-agent-images-test--steering
           "look at [image 1]"
           (list :type "image" :mime "image/png" :path png :label "image 1"))
       (harness-tool-ok "listed"))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let* ((request (cadr harness-agent-images-test-requests))
             (last (car (last (plist-get request :messages)))))
        (should (equal (list (list "tool_result" "listed") (list "text" "look at [image 1]")
                             (list "text" "[image 1]") (list "image" harness-agent-images-test-b64))
                       (mapcar (lambda (b) (list (plist-get b :type)
                                                 (or (plist-get b :text) (plist-get b :data)
                                                     (plist-get b :content))))
                               (plist-get last :content))))))))

(ert-deftest harness-agent-images-hosted-failed-call-and-odd-images-send-none ()
  "A failed call hands the model no image, nor does one that is no image.
Such a result is text for the provider, and the transcript names none:
an image a provider cannot take would stay in the conversation for good."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:eyes")))
      (setq harness-agent-images-test-result
            (lambda (_) (harness-tool-error "could not decode" :images (list (list :path png :mime "image/png")))))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let ((response (car harness-agent-images-test-responses)))
        (should (plist-get response :is-error))
        (should (equal "could not decode" (plist-get response :content)))
        (should-not (plist-member response :images)))
      (should-not (plist-member (harness-agent-images-test-result-node id) :images)))
    (dolist (images (list (list (list :path png :mime "image/svg+xml"))
                          (list (list :path png))
                          (list (list :mime "image/png"))
                          (list (list :path "" :mime "image/png"))
                          (list "shot.png")))
      (setq harness-agent-images-test-responses nil)
      (let ((id (harness-agent-images-test-session "hosted:eyes")))
        (setq harness-agent-images-test-result (lambda (_) (harness-tool-ok "text" :images images)))
        (should (eq 'end-turn (harness-agent-images-test-run id)))
        (let ((response (car harness-agent-images-test-responses)))
          (should (equal "text" (plist-get response :content)))
          (should-not (plist-member response :images)))
        (should-not (plist-member (harness-agent-images-test-result-node id) :images))))))

(ert-deftest harness-agent-images-hosted-image-bytes-are-not-in-the-node-or-the-text ()
  "The images the tool returned beyond what the contract names are not kept.
Only the path and the type go in the transcript, whatever else the tool
put in the entry, bytes included."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:eyes")))
      (setq harness-agent-images-test-result
            (lambda (_) (harness-tool-ok "text" :images (list (list :path png :mime "image/png"
                                                                    :data "QUJD" :name "x.png")))))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (should (equal (list (list :path png :mime "image/png"))
                     (plist-get (harness-agent-images-test-result-node id) :images))))))

(ert-deftest harness-agent-images-hosted-request-needs-no-image-bytes ()
  "A hosted loop keeps the pictures it was handed itself.
Its request is made without reading a file of the history, and with
none of its images."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "hosted:eyes")))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (harness-agent-images-test-counting-reads reads
        (let* ((messages (harness-agent--request-messages (harness-call 'session/get id)))
               (blocks (cl-loop for m in messages append (plist-get m :content))))
          (should (= 0 reads))
          (should (cl-some (lambda (b) (equal (plist-get b :type) "tool_result")) blocks))
          (should-not (cl-some (lambda (b) (plist-member b :images)) blocks))
          (should-not (string-search harness-agent-images-test-b64 (format "%S" messages))))))))

;;;; A loop the harness runs

(ert-deftest harness-agent-images-native-vision-request-carries-the-image ()
  "The step after a result with an image sends the image, inline.
Nothing is read when the call ends (there is no provider to answer), only
when the next request is made."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "native:eyes"))
          (at-result nil))
      (harness-agent-images-test-counting-reads reads
        (harness-on 'agent/tool-result (lambda (&rest _) (setq at-result reads)))
        (should (eq 'end-turn (harness-agent-images-test-run id)))
        (should (= 0 at-result))
        (should (= 1 reads)))
      (should (= 2 (length harness-agent-images-test-requests)))
      (let* ((request (cadr harness-agent-images-test-requests))
             (result (car (last (plist-get (car (last (plist-get request :messages))) :content)))))
        (should (equal "tool_result" (plist-get result :type)))
        (should (equal "Image shot.png attached." (plist-get result :content)))
        (should (equal (list (list :type "image" :mime "image/png" :data harness-agent-images-test-b64))
                       (plist-get result :images))))
      ;; Not a byte of it in the transcript.
      (should-not (string-search harness-agent-images-test-b64
                                 (format "%S" (harness-call 'session/nodes id)))))))

(ert-deftest harness-agent-images-native-blind-request-reads-nothing ()
  "A native model that reads no images is sent none, and no file is read.
The text of the result says that only the user sees the image."
  (harness-agent-images-test-with
    (let ((id (harness-agent-images-test-session "native:blind")))
      (harness-agent-images-test-counting-reads reads
        (should (eq 'end-turn (harness-agent-images-test-run id)))
        (should (= 0 reads)))
      (let* ((request (cadr harness-agent-images-test-requests))
             (result (car (last (plist-get (car (last (plist-get request :messages))) :content)))))
        (should (equal (concat "Image shot.png attached." harness-agent-images-test-blind-note)
                       (plist-get result :content)))
        (should-not (plist-member result :images)))
      (should (equal (list (list :path png :mime "image/png"))
                     (plist-get (harness-agent-images-test-result-node id) :images))))))

(ert-deftest harness-agent-images-read-file-image-reaches-the-model ()
  "The real read_file hands the model an image it reads, hosted or native."
  (harness-agent-images-test-with
    (harness-test-load-module 'tools-fs)
    (setq harness-agent-images-test-call (cons "read_file" (list :path png)))
    ;; A hosted loop is handed it with the result.
    (let ((id (harness-agent-images-test-session "hosted:eyes")))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let ((response (car harness-agent-images-test-responses)))
        (should-not (plist-get response :is-error))
        (should (string-prefix-p "Image " (plist-get response :content)))
        (should (equal (list (list :mime "image/png" :data harness-agent-images-test-b64 :name "shot.png"))
                       (plist-get response :images)))))
    ;; A native loop sends it with its next request.
    (let ((id (harness-agent-images-test-session "native:eyes")))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let* ((request (car (last harness-agent-images-test-requests)))
             (result (car (last (plist-get (car (last (plist-get request :messages))) :content)))))
        (should (equal (list (list :type "image" :mime "image/png" :data harness-agent-images-test-b64))
                       (plist-get result :images)))))
    ;; A model that reads none is told the user sees it.
    (let ((id (harness-agent-images-test-session "native:blind")))
      (should (eq 'end-turn (harness-agent-images-test-run id)))
      (let* ((request (car (last harness-agent-images-test-requests)))
             (result (car (last (plist-get (car (last (plist-get request :messages))) :content)))))
        (should-not (plist-member result :images))
        (should (string-suffix-p harness-agent-images-test-blind-note (plist-get result :content)))))))

;;;; Making a request ready

(defun harness-agent-images-test--result (n png &optional images)
  "Return a user message holding the result of call N, with IMAGES (one of PNG)."
  (list :role 'user
        :content (list (list :type "tool_result" :tool_use_id (format "c%d" n)
                             :content (format "result %d" n) :is_error nil
                             :images (or images (list (list :type "image" :mime "image/png" :path png)))))))

(ert-deftest harness-agent-images-prepare-block-inlines-notes-and-leaves-the-rest ()
  "A tool_result block with images is made ready for the model reading them.
A model that reads images gets each as data; one whose file is gone is
dropped, and the text says so.  A model that does not gets none, and a
note.  A block without images is returned as it is."
  (harness-agent-images-test-with
    (let* ((eyes (list :model "native:eyes"))
           (blind (list :model "native:blind"))
           (plain (list :type "tool_result" :tool_use_id "c1" :content "text" :is_error nil))
           (gone (expand-file-name "gone.png" dir))
           (block (list :type "tool_result" :tool_use_id "c2" :content "two" :is_error nil
                        :images (list (list :type "image" :mime "image/png" :path png)
                                      (list :type "image" :mime "image/jpeg" :path gone)))))
      (should (eq plain (harness-agent--prepare-block plain eyes)))
      (should (eq plain (harness-agent--prepare-block plain blind)))
      (should (equal (list :type "tool_result" :tool_use_id "c2"
                           :content (format "two\n\n[The image this call returned (%s) is gone; read the file again to see it.]"
                                            gone)
                           :is_error nil
                           :images (list (list :type "image" :mime "image/png" :data harness-agent-images-test-b64)))
                     (harness-agent--prepare-block block eyes)))
      (should (equal (list :type "tool_result" :tool_use_id "c2"
                           :content (concat "two" harness-agent-images-test-blind-note) :is_error nil)
                     (harness-agent--prepare-block block blind)))
      ;; Every image gone: the key goes with them.
      (let ((only-gone (list :type "tool_result" :tool_use_id "c3" :content "x" :is_error nil
                             :images (list (list :type "image" :mime "image/png" :path gone)))))
        (should-not (plist-member (harness-agent--prepare-block only-gone eyes) :images)))
      ;; An image that carries its data is kept as it is, with no file read.
      (let ((inline (list :type "tool_result" :tool_use_id "c4" :content "x" :is_error nil
                          :images (list (list :type "image" :mime "image/png" :data "QUJD")))))
        (harness-agent-images-test-counting-reads reads
          (should (equal inline (harness-agent--prepare-block inline eyes)))
          (should (= 0 reads))))
      ;; The block asked about is not changed.
      (should (equal (list (list :type "image" :mime "image/png" :path png)
                           (list :type "image" :mime "image/jpeg" :path gone))
                     (plist-get block :images)))
      (should (equal "two" (plist-get block :content))))))

(ert-deftest harness-agent-images-prepare-messages-keeps-requests-without-images-alone ()
  "A request with no tool-result image is made ready as it always was."
  (harness-agent-images-test-with
    (let* ((plain (list :type "tool_result" :tool_use_id "c1" :content "text" :is_error nil))
           (messages (list (list :role 'user :content (list (list :type "text" :text "go")))
                           (list :role 'assistant :content (list (list :type "tool_use" :id "c1" :name "look" :input :empty)))
                           (list :role 'user :content (list plain))))
           (ready (harness-agent--prepare-messages (list :model "native:eyes") messages)))
      (should (equal messages ready))
      (should (eq plain (car (plist-get (nth 2 ready) :content)))))))

(defun harness-agent-images-test--dropped (messages)
  "Return the numbers of the calls in MESSAGES whose image was left out for size."
  (cl-loop for m in messages
           append (cl-loop for b in (plist-get m :content)
                           when (and (equal (plist-get b :type) "tool_result")
                                     (string-search "no longer attached" (plist-get b :content)))
                           collect (string-to-number (substring (plist-get b :tool_use_id) 1)))))

(ert-deftest harness-agent-images-history-keeps-the-newest-in-chunks ()
  "Past the limit, the oldest images go in chunks of half the limit.
With a limit of 4: 4 images stay, 5 drop 2, 6 drop 2, 7 drop 4.  The
window moves only every half-limit images, so the request stays the same
in between and the provider's prompt cache with it.  A dropped image
is never read, and its result says it is no longer attached."
  (harness-agent-images-test-with
    (let ((eyes (list :model "native:eyes")))
      (dolist (case '((4 . 0) (5 . 2) (6 . 2) (7 . 4) (8 . 4) (9 . 6) (10 . 6) (11 . 8)))
        (let* ((total (car case))
               (harness-agent-history-images 4)
               (messages (cl-loop for n from 1 to total collect (harness-agent-images-test--result n png))))
          (harness-agent-images-test-counting-reads reads
            (let ((ready (harness-agent--prepare-messages eyes messages)))
              ;; The oldest are the ones dropped.
              (should (equal (number-sequence 1 (cdr case)) (harness-agent-images-test--dropped ready)))
              (should (= (- total (cdr case)) reads))
              (should (= (- total (cdr case))
                         (cl-loop for m in ready
                                  sum (cl-loop for b in (plist-get m :content)
                                               sum (length (plist-get b :images)))))))))))
    ;; The default is 16: 17 drop 8, 24 drop 8, 25 drop 16.
    (should (= 16 (default-value 'harness-agent-history-images)))
    (dolist (case '((16 . 0) (17 . 8) (24 . 8) (25 . 16) (32 . 16) (33 . 24)))
      (let ((messages (cl-loop for n from 1 to (car case) collect (harness-agent-images-test--result n png))))
        (should (= (cdr case)
                   (length (harness-agent-images-test--dropped
                            (harness-agent--prepare-messages (list :model "native:eyes") messages)))))))))

(ert-deftest harness-agent-images-history-cap-edges ()
  "The limit nil keeps every image; 0 keeps none; a model that reads none is capped by nothing.
Results are noted for what happened to their image: left out for size,
or not read at all."
  (harness-agent-images-test-with
    (let ((eyes (list :model "native:eyes"))
          (blind (list :model "native:blind"))
          (messages (cl-loop for n from 1 to 6 collect (harness-agent-images-test--result n png))))
      (let ((harness-agent-history-images nil))
        (should (equal nil (harness-agent-images-test--dropped (harness-agent--prepare-messages eyes messages)))))
      (let ((harness-agent-history-images 0))
        (should (equal '(1 2 3 4 5 6) (harness-agent-images-test--dropped (harness-agent--prepare-messages eyes messages)))))
      (let ((harness-agent-history-images 2))
        ;; A model that reads no image drops nothing for size: it never got any.
        (harness-agent-images-test-counting-reads reads
          (let ((ready (harness-agent--prepare-messages blind messages)))
            (should (= 0 reads))
            (should-not (harness-agent-images-test--dropped ready))
            (should (cl-every (lambda (m)
                                (string-suffix-p harness-agent-images-test-blind-note
                                                 (plist-get (car (plist-get m :content)) :content)))
                              ready))))
        ;; Images of the user's own are not counted: they are not tool results.
        (let ((with-user (cons (list :role 'user :content (list (list :type "image" :mime "image/png" :data "QUJD")))
                               (cl-subseq messages 0 2))))
          (should-not (harness-agent-images-test--dropped (harness-agent--prepare-messages eyes with-user))))))))

(ert-deftest harness-agent-images-history-cap-cuts-within-a-result ()
  "A result with several images loses the oldest of them, once noted."
  (harness-agent-images-test-with
    (let* ((harness-agent-history-images 4)
           (image (list :type "image" :mime "image/png" :path png))
           (messages (list (harness-agent-images-test--result 1 png (list image image image))
                           (harness-agent-images-test--result 2 png (list image image image))))
           (ready (harness-agent--prepare-messages (list :model "native:eyes") messages)))
      ;; Six images, limit 4: two go, both from the first result.
      (let ((first (car (plist-get (car ready) :content))))
        (should (= 1 (length (plist-get first :images))))
        (should (equal "result 1\n\n[The image this call returned is no longer attached, to keep the request small; read the file again to see it.]"
                       (plist-get first :content))))
      (let ((second (car (plist-get (cadr ready) :content))))
        (should (= 3 (length (plist-get second :images))))
        (should (equal "result 2" (plist-get second :content)))))))

;;;; Stripping the images

(ert-deftest harness-agent-images-strip-leaves-the-text ()
  "Stripping takes the images from tool results and nothing else.
A message with none is returned as it is."
  (let* ((plain (list :role 'user :content (list (list :type "text" :text "go")
                                                 (list :type "tool_result" :tool_use_id "c1" :content "t" :is_error nil))))
         (assistant (list :role 'assistant :content (list (list :type "text" :text "ok"))))
         (with (list :role 'user
                     :content (list (list :type "tool_result" :tool_use_id "c2" :content "see" :is_error nil
                                          :images (list (list :type "image" :mime "image/png" :path "/a.png")))
                                    (list :type "image" :mime "image/png" :path "/user.png"))))
         (stripped (harness-agent-strip-result-images (list plain assistant with))))
    (should (eq plain (car stripped)))
    (should (eq assistant (cadr stripped)))
    (should (equal (list :role 'user
                         :content (list (list :type "tool_result" :tool_use_id "c2" :content "see" :is_error nil)
                                        (list :type "image" :mime "image/png" :path "/user.png")))
                   (nth 2 stripped)))
    ;; The messages it was given are not changed.
    (should (plist-get (car (plist-get with :content)) :images))))

(ert-deftest harness-agent-images-title-and-summary-requests-carry-none ()
  "A title and a summary are written from words; their requests hold no image.
A summary of a conversation that outgrew its window must not be sent
every picture of it, which a provider could refuse as too large."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider provider-demo tools session agent compaction naming))
      (harness-test-load-module m))
    (clrhash harness-sessions)
    (clrhash harness-tools)
    (clrhash harness-agent--turns)
    (clrhash harness-compaction--running)
    (clrhash harness-compaction--pending)
    (let* ((png (harness-agent-images-test--png dir))
           (harness-naming-auto nil)
           (harness-provider-demo--delay 0.005)
           (harness-compaction--context-reserve 1000)
           (harness-provider-demo-script-override
            '((:type text :delta "SUMMARY") (:type done :stop-reason end-turn)))
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                        :model "demo:scripted" :context-window 8000)
                          :id))
           (requests nil))
      (harness-call 'session/append id '(:kind user :content "look at the screenshot"))
      (harness-call 'session/append id '(:kind tool-call :tool "read_file" :call-id "c1" :input (:path "shot.png")))
      (harness-call 'session/append id (list :kind 'tool-result :call-id "c1" :output "Image shot.png attached."
                                             :images (list (list :path png :mime "image/png"))))
      (harness-call 'session/append id '(:kind assistant :content "It is a login page."))
      ;; The conversation does carry the image...
      (should (plist-get (car (plist-get (nth 2 (harness-call 'session/messages id)) :content)) :images))
      ;; ...the title request does not...
      (let ((messages (harness-naming--messages id)))
        (should-not (string-search ":images" (format "%S" messages)))
        (should (string-search "Image shot.png attached." (format "%S" messages))))
      ;; ...nor does the summary's.
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (harness-await (harness-call 'compaction/compact id)))
      (should (= 1 (length requests)))
      (let ((text (format "%S" (plist-get (car requests) :messages))))
        (should-not (string-search ":images" text))
        (should-not (string-search "shot.png\" :mime" text))
        (should (string-search "Image shot.png attached." text))))))

;;;; Getting there

(ert-deftest harness-agent-images-survive-the-guard-and-the-filters ()
  "A result's images ride through `tools/execute' whole.
The size guard truncates the text and the secrets filter masks it; both
rebuild the result, and neither may lose the images."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store tools secrets))
      (harness-test-load-module m))
    (cancel-function-timers #'harness-secrets--prime)
    (clrhash harness-tools)
    (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
    (let* ((secret (concat "FAKE/" (substring (md5 (format "%s %s" (random) (float-time))) 0 24) "+Zz9"))
           (harness-secrets-mask t)
           (harness-secrets-sources (list (list :literal secret :label "k")))
           (harness-tools-max-output-chars 200)
           (images (list (list :path "/a/shot.png" :mime "image/png")))
           (call (lambda (text)
                   (harness-define-tool "pic" :label "Pic" :description "x" :kind 'read
                                        :handler (lambda (_input _ctx)
                                                   (harness-tool-ok text :images images)))
                   (harness-await (harness-call 'tools/execute nil (list :id "c1" :name "pic" :input nil)) 20))))
      (harness-secrets-forget)
      (unwind-protect
          (progn
            ;; Masked.
            (let ((result (funcall call (format "key=%s" secret))))
              (should-not (string-search secret (plist-get result :content)))
              (should (plist-get (plist-get result :meta) :masked))
              (should (equal images (plist-get result :images))))
            ;; Truncated.
            (let ((result (funcall call (make-string 1000 ?x))))
              (should (plist-get result :truncated))
              (should (equal images (plist-get result :images))))
            ;; Both.
            (let ((result (funcall call (concat secret (make-string 1000 ?x)))))
              (should (plist-get result :truncated))
              (should (plist-get (plist-get result :meta) :masked))
              (should (equal images (plist-get result :images)))))
        (harness-secrets-forget)))))

(provide 'harness-agent-images-test)
;;; harness-agent-images-test.el ends here
