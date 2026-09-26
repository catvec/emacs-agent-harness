;;; harness-acp-tcp.el --- ACP over a TCP byte stream -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Newline-delimited JSON over TCP, per the ACP custom-transport rules: the
;; JSON-RPC message format is preserved, only framing is added.  Everything
;; is filter/sentinel driven; no operation waits for the network.
;;
;; Two directions:
;;
;;   `harness-acp-tcp-server'  listen for clients (this harness controls
;;                             the sessions; remote UIs connect here),
;;   `harness-acp-tcp-connect' connect to a remote harness (the local UI
;;                             controls a session on another host).

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-acp)

(defvar harness-acp-tcp-default-host "127.0.0.1"
  "Default address for `harness-acp-tcp-server'.")

(defun harness-acp-tcp--send (process message)
  "Serialize MESSAGE and send it to PROCESS followed by a newline."
  (process-send-string process (concat (harness-acp-serialize message) "\n")))

(defun harness-acp-tcp--connection-for (process role)
  "Return (creating it first if needed) the ACP connection for PROCESS.
ROLE is 'agent or 'client."
  (or (process-get process 'harness-acp-connection)
      (let* ((transport
              (harness-acp-transport-create
               :name "tcp"
               :send-fn (lambda (message)
                          (when (process-live-p process)
                            (harness-acp-tcp--send process message)))
               :close-fn (lambda ()
                           (when (process-live-p process)
                             (delete-process process)))))
             (connection (harness-acp-connection-create role transport)))
        (process-put process 'harness-acp-connection connection)
        (process-put process 'harness-acp-buffer "")
        connection)))

(defun harness-acp-tcp--receive (process chunk)
  "Feed CHUNK from PROCESS into its connection, splitting on newlines."
  (let ((connection (process-get process 'harness-acp-connection)))
    (when connection
      (let ((buffer (concat (or (process-get process 'harness-acp-buffer) "") chunk)))
        (while (string-match "\n" buffer)
          (let ((line (substring buffer 0 (match-beginning 0))))
            (setq buffer (substring buffer (match-end 0)))
            (unless (string-empty-p (string-trim line))
              (condition-case err
                  (harness-acp-connection-receive
                   connection (harness-acp-parse line))
                (error
                 (harness-log "acp tcp: bad message from %s: %S"
                              (process-name process) err))))))
        (process-put process 'harness-acp-buffer buffer)))))

(defun harness-acp-tcp--sentinel (process event)
  "Close the connection for PROCESS when EVENT says it went away."
  (let ((connection (process-get process 'harness-acp-connection)))
    (when (and connection
               (not (harness-acp-connection-closed connection))
               (memq (process-status process) '(closed failed exit signal)))
      (harness-acp-connection-close connection event))))

(defun harness-acp-tcp-server (port &optional on-connection host)
  "Listen for ACP clients on PORT.
When a client connects, create an agent-role connection and call
ON-CONNECTION with it (default `harness-acp-agent-started').  HOST
defaults to `harness-acp-tcp-default-host'.  Returns the server process."
  (let ((start (or on-connection #'harness-acp-agent-started))
        (server nil))
    (setq server
          (make-network-process
           :name (format "harness-acp-server:%s" port)
           :server t
           :host (or host harness-acp-tcp-default-host)
           :service port
           :family 'ipv4
           :coding 'utf-8-unix
           :noquery t
           :reuse-addr t
           ;; For a server these are inherited by each connection; the
           ;; server itself never uses them.
           :filter (lambda (process chunk)
                     (let ((connection (process-get process 'harness-acp-connection)))
                       (unless connection
                         (setq connection (harness-acp-tcp--connection-for process 'agent))
                         (funcall start connection))
                       (harness-acp-tcp--receive process chunk)))
           :sentinel #'harness-acp-tcp--sentinel))
    server))

(defun harness-acp-tcp-listen-port (server)
  "Return the port SERVER is listening on."
  (process-contact server :service))

(defun harness-acp-tcp-connect (host port &optional role)
  "Connect to an ACP peer at HOST:PORT and return a connection.
ROLE defaults to 'client.  Connection establishment is synchronous but
bounded by the OS; callers should show a loading state."
  (let* ((process (open-network-stream
                   (format "harness-acp-client:%s:%s" host port)
                   nil host port
                   :type 'plain
                   :coding 'utf-8-unix
                   :noquery t))
         (connection (harness-acp-tcp--connection-for process (or role 'client))))
    (set-process-filter
     process
     (lambda (proc chunk)
       (harness-acp-tcp--receive proc chunk)))
    (set-process-sentinel process #'harness-acp-tcp--sentinel)
    connection))

(defun harness-acp-tcp-setup ()
  "Set up the TCP transport module."
  nil)

(harness-module-define 'harness-acp-tcp
  :version harness-version
  :description "Newline-delimited JSON ACP transport over TCP."
  :requires '((harness-core "0.1.0") (harness-acp "0.1.0"))
  :provides '(harness-acp-tcp)
  :setup #'harness-acp-tcp-setup)

(provide 'harness-acp-tcp)
;;; harness-acp-tcp.el ends here
