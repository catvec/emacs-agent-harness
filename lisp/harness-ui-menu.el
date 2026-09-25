;;; harness-ui-menu.el --- Transient help menus for every harness mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;; URL: https://github.com/noahhuppert/emacs-agent-harness

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Every harness major mode binds `?' to a `transient' menu.  Pressing `?'
;; anywhere shows the commands that make sense right there, grouped and
;; described, without having to read the whole major-mode help.
;;
;; The menus are centralised in one file for two reasons.  First, an audit of
;; "does every mode have a menu?" is a single `transient-define-prefix' away
;; from "yes".  Second, `transient' is a large library that a headless run
;; (`harness-agent' with no UI) has no use for: the mode files only *name*
;; their menu in a key binding, and `harness.el' requires this file, so the
;; core never loads `transient'.
;;
;; Each mode binds `?' to its prefix in its own keymap; the prefixes live
;; here.  The menus call the same commands the mode's keys do, so a menu entry
;; is never the only way to reach something.

;;; Code:

(require 'transient)

(declare-function harness-conversation-send "harness-ui-conversation" ())
(declare-function harness-conversation-clear-input "harness-ui-conversation" ())
(declare-function harness-conversation-abort "harness-ui-conversation" ())
(declare-function harness-conversation-approve "harness-ui-conversation" ())
(declare-function harness-conversation-approve-always "harness-ui-conversation" ())
(declare-function harness-conversation-deny "harness-ui-conversation" ())
(declare-function harness-conversation-search "harness-ui-conversation" (regexp))
(declare-function harness-conversation-load-earlier "harness-ui-conversation" ())
(declare-function harness-conversation-next-message "harness-ui-conversation" ())
(declare-function harness-conversation-previous-message "harness-ui-conversation" ())
(declare-function harness-conversation-toggle-fold "harness-ui-conversation" ())
(declare-function harness-conversation-toggle-thinking "harness-ui-conversation" ())
(declare-function harness-conversation-refresh "harness-ui-conversation" ())
(declare-function harness-search-results-jump "harness-ui-conversation" ())
(declare-function harness-queue-commit "harness-queue" ())
(declare-function harness-queue-cancel "harness-queue" ())
(declare-function harness-queue-delete-section-at-point "harness-queue" ())
(declare-function harness-queue-next "harness-queue" ())
(declare-function harness-queue-previous "harness-queue" ())
(declare-function harness-ask-submit "harness-ui-ask" ())
(declare-function harness-ask-cancel "harness-ui-ask" ())
(declare-function harness-model-use "harness-ui-model" ())
(declare-function harness-model-refresh "harness-ui-model" ())
(declare-function harness-sessions-view "harness-ui-sessions" ())
(declare-function harness-sessions-resume "harness-ui-sessions" ())
(declare-function harness-sessions-delete "harness-ui-sessions" ())
(declare-function harness-sessions-close "harness-ui-sessions" ())
(declare-function harness-sessions-approve "harness-ui-sessions" ())
(declare-function harness-sessions-approve-always "harness-ui-sessions" ())
(declare-function harness-sessions-deny "harness-ui-sessions" ())
(declare-function harness-sessions-abort "harness-ui-sessions" ())
(declare-function harness-sessions-search "harness-ui-sessions" (query))
(declare-function harness-sessions-filter "harness-ui-sessions" (filter))
(declare-function harness-sessions-filter-project "harness-ui-sessions" ())
(declare-function harness-sessions-new "harness-ui-sessions" ())
(declare-function harness-sessions-rename "harness-ui-sessions" ())
(declare-function harness-sessions-refresh "harness-ui-sessions" ())
(declare-function harness-tree-goto-message "harness-ui-tree" ())
(declare-function harness-tree-toggle-output "harness-ui-tree" ())
(declare-function harness-tree-next "harness-ui-tree" ())
(declare-function harness-tree-previous "harness-ui-tree" ())
(declare-function harness-tree-refresh "harness-ui-tree" ())


;;; Per-mode menus

(transient-define-prefix harness-conversation-menu ()
  "Menu of `harness-conversation-mode' commands."
  ["Message"
   ("s" "Send the message" harness-conversation-send)
   ("k" "Clear the input" harness-conversation-clear-input)
   ("b" "Abort the run" harness-conversation-abort)]
  ["Approvals"
   ("a" "Allow the pending approval" harness-conversation-approve)
   ("A" "Allow and remember the approval" harness-conversation-approve-always)
   ("d" "Deny the pending approval" harness-conversation-deny)]
  ["Session"
   ("m" "Select the model" harness-select-model)
   ("t" "Show the message tree" harness-tree)
   ("e" "Edit the queued messages" harness-queue-edit)
   ("f" "Search the transcript" harness-conversation-search)
   ("l" "Load earlier messages" harness-conversation-load-earlier)
   ("z" "Compact the session" harness-compact-session)
   ("w" "Set the working directory" harness-set-working-directory)]
  ["View"
   ("n" "Next message" harness-conversation-next-message)
   ("p" "Previous message" harness-conversation-previous-message)
   ("o" "Toggle the fold at point" harness-conversation-toggle-fold)
   ("T" "Show or hide reasoning traces" harness-conversation-toggle-thinking)
   ("g" "Re-render the buffer" harness-conversation-refresh)
   ("q" "Bury the buffer" bury-buffer)])

(transient-define-prefix harness-queue-menu ()
  "Menu of `harness-queue-mode' commands."
  ["Queue"
   ("s" "Save and close" harness-queue-commit)
   ("k" "Discard the edits" harness-queue-cancel)
   ("d" "Delete the message at point" harness-queue-delete-section-at-point)]
  ["Move"
   ("n" "Next message" harness-queue-next)
   ("p" "Previous message" harness-queue-previous)
   ("q" "Bury the buffer" bury-buffer)])

(transient-define-prefix harness-ask-menu ()
  "Menu of `harness-ask-mode' commands."
  ["Answer"
   ("s" "Submit the answers" harness-ask-submit)
   ("k" "Decline and let the model continue" harness-ask-cancel)]
  ["Move"
   ("n" "Next field" widget-forward)
   ("p" "Previous field" widget-backward)
   ("q" "Bury the buffer" bury-buffer)])

(transient-define-prefix harness-model-menu ()
  "Menu of `harness-model-mode' commands."
  ["Model"
   ("s" "Use the model at point" harness-model-use)
   ("R" "Fetch the catalogue again" harness-model-refresh)]
  ["View"
   ("g" "Revert the list" revert-buffer)
   ("q" "Quit the window" quit-window)])

(transient-define-prefix harness-sessions-menu ()
  "Menu of `harness-sessions-mode' commands."
  ["Session"
   ("v" "View the session" harness-sessions-view)
   ("r" "Resume the session" harness-sessions-resume)
   ("n" "New session" harness-sessions-new)
   ("R" "Rename the session" harness-sessions-rename)
   ("k" "Close the live session" harness-sessions-close)
   ("d" "Delete the session" harness-sessions-delete)]
  ["Approvals"
   ("a" "Allow the pending approval" harness-sessions-approve)
   ("A" "Allow and remember the approval" harness-sessions-approve-always)
   ("D" "Deny the pending approval" harness-sessions-deny)
   ("x" "Abort the run" harness-sessions-abort)]
  ["Find"
   ("s" "Search the transcripts" harness-sessions-search)
   ("/" "Filter by status" harness-sessions-filter)
   ("P" "Filter by this project" harness-sessions-filter-project)
   ("m" "Select the model" harness-select-model)]
  ["View"
   ("g" "Refresh the browser" harness-sessions-refresh)
   ("q" "Quit the window" quit-window)])

(transient-define-prefix harness-tree-menu ()
  "Menu of `harness-tree-mode' commands."
  ["Message"
   ("j" "Jump to the conversation" harness-tree-goto-message)
   ("t" "Show or hide tool output" harness-tree-toggle-output)]
  ["Outline"
   ("c" "Toggle the subtree" outline-toggle-children)
   ("C" "Cycle the subtree" outline-cycle)]
  ["Move"
   ("n" "Next message" harness-tree-next)
   ("p" "Previous message" harness-tree-previous)
   ("g" "Re-render the tree" harness-tree-refresh)
   ("q" "Quit the window" quit-window)])

(transient-define-prefix harness-search-results-menu ()
  "Menu of `harness-search-results-mode' commands."
  ["Result"
   ("j" "Jump to the message at point" harness-search-results-jump)
   ("n" "Next result" forward-button)
   ("p" "Previous result" backward-button)
   ("q" "Quit the window" quit-window)])


;;; Global menu

(transient-define-prefix harness-menu ()
  "Menu of the global harness commands bound to \\[global-harness-mode]."
  ["Sessions"
   ("n" "New session" harness-new-session)
   ("o" "Open a session for this project" harness-open-at-project)
   ("r" "Resume a session" harness-resume-session)
   ("l" "List sessions" harness-list-sessions)
   ("s" "Search sessions" harness-search-sessions-ui)
   ("b" "Switch to a blocked session" harness-switch-blocked)
   ("c" "Cycle sessions" harness-cycle-sessions)]
  ["Session"
   ("m" "Select the model" harness-select-model)
   ("M" "List models" harness-list-models)
   ("f" "Refresh model stats" harness-refresh-models)
   ("t" "Show the message tree" harness-tree)
   ("q" "Edit the queued messages" harness-queue-edit)
   ("d" "Describe the session" harness-describe-session)
   ("z" "Compact the session" harness-compact-session)
   ("a" "Approve the next request" harness-approve-next)
   ("A" "Toggle auto mode" harness-toggle-auto-mode)]
  ["Worktree"
   ("w" "Create a worktree" harness-worktree-create)
   ("W" "Remove a worktree" harness-worktree-remove)
   ("V" "Switch worktree" harness-worktree-switch)]
  ["Harness"
   ("e" "Evaluate an expression" harness-eval-expression)
   ("R" "Reload the harness" harness-reload)
   ("P" "Reload the plugins" harness-reload-plugins)
   ("L" "Toggle plugin watch mode" harness-plugin-mode)
   ("N" "Author a plugin" harness-author-plugin)
   ("x" "Abort every run" harness-abort-all)
   ("i" "Rebuild the search index" harness-index-rebuild)
   ("h" "Run setup" harness-setup)])

(provide 'harness-ui-menu)
;;; harness-ui-menu.el ends here
