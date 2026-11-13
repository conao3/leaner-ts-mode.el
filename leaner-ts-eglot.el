;;; leaner-ts-eglot.el --- Lean editing facilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Naoya Yamashita
;; Author: Naoya Yamashita <conao3@gmail.com>
;; Assisted-by: Codex:gpt-6.1-sol

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

;; Facilities used by `leaner-ts-mode'.

;;; Code:

(require 'eglot)
(require 'leaner-ts-mode)
(require 'leaner-ts-lsp)

(defclass leaner-ts-eglot-server (eglot-lsp-server) ()
  :documentation "A Lean language server with Lean RPC support.")

(add-to-list 'eglot-server-programs
             '((leaner-ts-mode :language-id "lean4") . (leaner-ts-eglot-server "lake" "serve")))

(defvar-local leaner-ts--processing 0
  "Number of Lean processing ranges in the current buffer.")

(cl-defmethod eglot-client-capabilities ((_server leaner-ts-eglot-server))
  "Advertise Lean refresh support for the server."
  (let* ((capabilities (copy-tree (cl-call-next-method)))
         (workspace (plist-get capabilities :workspace)))
    (plist-put capabilities :workspace (plist-put workspace :inlayHint '(:refreshSupport t)))
    capabilities))

(cl-defmethod eglot-initialization-options ((_server leaner-ts-eglot-server))
  "Enable interactive diagnostic data for the Lean server."
  '(:hasWidgets t))

(cl-defmethod eglot-handle-request
  ((server leaner-ts-eglot-server) (_method (eql workspace/inlayHint/refresh)))
  "Refresh inlay hints in buffers managed by SERVER."
  (dolist (buffer (eglot--managed-buffers server))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (bound-and-true-p eglot-inlay-hints-mode)
          (eglot-inlay-hints-mode -1)
          (eglot-inlay-hints-mode 1)))))
  nil)

(cl-defmethod eglot-handle-notification
  ((_server leaner-ts-eglot-server) (_method (eql $/lean/fileProgress))
   &key textDocument processing &allow-other-keys)
  "Display processing progress for TEXTDOCUMENT using PROCESSING ranges."
  (when-let* ((uri (plist-get textDocument :uri))
              (buffer (find-buffer-visiting (eglot-uri-to-path uri))))
    (with-current-buffer buffer
      (setq leaner-ts--processing (length processing))
      (force-mode-line-update))))

(defun leaner-ts--eglot-managed ()
  "Configure buffer-local progress when Eglot manages a Lean buffer."
  (when (derived-mode-p 'leaner-ts-mode)
    (unless (eglot-managed-p) (setq leaner-ts--processing 0))
    (setq-local mode-line-process
                '(:eval (when (> leaner-ts--processing 0)
                          (format " Lean:%d" leaner-ts--processing))))))

(add-hook 'eglot-managed-mode-hook #'leaner-ts--eglot-managed)

(cl-defmethod leaner-ts-lsp-current ()
  "Return the current Eglot connection for Lean."
  (let ((server (eglot-current-server)))
    (unless (and server (object-of-class-p server 'leaner-ts-eglot-server)
                 (jsonrpc-running-p server))
      (user-error "Start the Lean server with M-x leaner-ts-eglot-ensure"))
    server))

(cl-defmethod leaner-ts-lsp-position ()
  "Flush changes and return the current Eglot document position."
  (leaner-ts-lsp-current)
  (eglot--signal-textDocument/didChange)
  (eglot--TextDocumentPositionParams))

(cl-defmethod leaner-ts-lsp-request
  ((connection leaner-ts-eglot-server) method params &optional timeout)
  "Send METHOD and PARAMS to CONNECTION with TIMEOUT."
  (jsonrpc-request connection method params :timeout (or timeout 10)))

(cl-defmethod leaner-ts-lsp-request-async
  ((connection leaner-ts-eglot-server) method params success error)
  "Send METHOD and PARAMS to CONNECTION using SUCCESS and ERROR."
  (jsonrpc-async-request connection method params :success-fn success :error-fn error
                         :timeout 10 :timeout-fn (lambda () (funcall error '(:message "Lean request timed out")))))

(cl-defmethod leaner-ts-lsp-notify ((connection leaner-ts-eglot-server) method params)
  "Send METHOD and PARAMS as a notification to CONNECTION."
  (jsonrpc-notify connection method params))

(cl-defmethod leaner-ts-lsp-visit-location ((connection leaner-ts-eglot-server) location)
  "Visit LOCATION from CONNECTION in its negotiated position encoding."
  (let ((uri (or (plist-get location :targetUri) (plist-get location :uri)))
        (range (or (plist-get location :targetSelectionRange) (plist-get location :range)))
        (encoding (plist-get (eglot--capabilities connection) :positionEncoding)))
    (xref-push-marker-stack)
    (find-file (eglot-uri-to-path uri))
    (let ((eglot-move-to-linepos-function
           (pcase encoding
             ("utf-8" #'eglot-move-to-utf-8-linepos)
             ("utf-32" #'eglot-move-to-utf-32-linepos)
             (_ #'eglot-move-to-utf-16-linepos))))
      (goto-char (eglot--lsp-position-to-point (plist-get range :start))))))

;;;###autoload
(defun leaner-ts-eglot-ensure ()
  "Start or join the Lean language server for the current Lake project."
  (interactive)
  (unless (fboundp 'eglot-semantic-tokens-mode)
    (user-error "Install Eglot 1.20 or newer from GNU ELPA"))
  (unless (derived-mode-p 'leaner-ts-mode)
    (user-error "This command requires a Lean source buffer"))
  (unless (executable-find "lake")
    (user-error "Lake must be available on exec-path; enter the project's development environment"))
  (unless (eglot-current-server)
    (eglot '(leaner-ts-mode) (project-current t) 'leaner-ts-eglot-server
           '("lake" "serve") '("lean4"))))

(provide 'leaner-ts-eglot)

;;; leaner-ts-eglot.el ends here
