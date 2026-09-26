;;; harness-acp-inprocess.el --- Local ACP transport -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; The local transport: two ACP connections in the same Emacs process send
;; message plists to each other by direct function call.  No sockets, no
;; serialization, no new threads of control -- but also no JSON validation,
;; so the protocol module still uses the same message shapes as the TCP
;; transport.

;;; Code:

(require 'harness-core)
(require 'harness-acp)

(defun harness-acp-inprocess-pair ()
  "Create two connected ACP connections in this process.
Returns a cons (AGENT . CLIENT).  The agent side already has the standard
agent method table installed."
  (let* ((agent nil)
         (client nil)
         (agent-transport
          (harness-acp-transport-create
           :name "inprocess-agent"
           :send-fn (lambda (message)
                      (when (and client (not (harness-acp-connection-closed client)))
                        (harness-acp-connection-receive client message)))
           :close-fn (lambda ()
                       (when client (harness-acp-connection-close client "peer closed")))))
         (client-transport
          (harness-acp-transport-create
           :name "inprocess-client"
           :send-fn (lambda (message)
                      (when (and agent (not (harness-acp-connection-closed agent)))
                        (harness-acp-connection-receive agent message)))
           :close-fn (lambda ()
                       (when agent (harness-acp-connection-close agent "peer closed"))))))
    (setq agent (harness-acp-connection-create 'agent agent-transport))
    (setq client (harness-acp-connection-create 'client client-transport))
    (harness-acp-agent-started agent)
    (cons agent client)))

(defun harness-acp-inprocess-connect (agent)
  "Create a client connection to AGENT, an existing agent connection.
The agent's transport must be an in-process transport."
  (let* ((client nil)
         (agent-transport (harness-acp-connection-transport agent))
         (client-transport
          (harness-acp-transport-create
           :name "inprocess-client"
           :send-fn (lambda (message)
                      (unless (harness-acp-connection-closed agent)
                        (harness-acp-connection-receive agent message)))
           :close-fn (lambda () nil))))
    (setq client (harness-acp-connection-create 'client client-transport))
    ;; Replace the agent's send function so it reaches this client.
    (setf (harness-acp-transport-send-fn agent-transport)
          (lambda (message)
            (when (and client (not (harness-acp-connection-closed client)))
              (harness-acp-connection-receive client message))))
    (setf (harness-acp-transport-close-fn agent-transport)
          (lambda ()
            (when client (harness-acp-connection-close client "peer closed"))))
    client))

(defun harness-acp-inprocess-setup ()
  "Set up the in-process transport module."
  nil)

(harness-module-define 'harness-acp-inprocess
  :version harness-version
  :description "In-process ACP transport for the local UI."
  :requires '((harness-core "0.1.0") (harness-acp "0.1.0"))
  :provides '(harness-acp-inprocess)
  :setup #'harness-acp-inprocess-setup)

(provide 'harness-acp-inprocess)
;;; harness-acp-inprocess.el ends here
