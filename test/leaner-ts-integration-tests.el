;;; leaner-ts-integration-tests.el --- Lean editing facilities  -*- lexical-binding: t; -*-

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

(require 'cort)
(require 'leaner-ts-eglot)
(require 'leaner-ts-infoview)
(require 'leaner-ts-search)

(defvar trusted-content)

(defconst leaner-ts-test--fixture
  (expand-file-name "fixtures/lsp/Fixture.lean" (file-name-directory load-file-name))
  "Source fixture used for real Lean server integration tests.")

(defun leaner-ts-test--await (predicate description)
  "Wait for PREDICATE or signal an error describing DESCRIPTION."
  (let ((deadline (+ (float-time) 25)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless (funcall predicate) (error "Timed out waiting for %s" description))))

(defun leaner-ts-test--rpc (session position method params)
  "Call SESSION's METHOD with PARAMS at POSITION and return the real response."
  (let (done response failure)
    (leaner-ts--rpc-call session position method params
                         (lambda (value) (setq response value done t))
                         (lambda (error) (setq failure error done t)))
    (leaner-ts-test--await (lambda () done) method)
    (when failure (error "Lean RPC %s failed: %S" method failure))
    response))

(defun leaner-ts-test--integration ()
  "Exercise input, Eglot, diagnostics and interactive RPC against Lean."
  (unless (executable-find "lake") (error "Integration tests require Lake on PATH"))
  (let* ((source (find-file-noselect leaner-ts-test--fixture))
         (trusted-content (list (abbreviate-file-name (file-name-directory leaner-ts-test--fixture))))
         (eglot-sync-connect t)
         (eglot-autoshutdown nil)
         server info pin checks)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer source)
          (leaner-ts-mode)
          (leaner-ts-eglot-ensure)
          (setq server (leaner-ts-lsp-current))
          (push (object-of-class-p server 'leaner-ts-eglot-server) checks)
          (goto-char (point-min)) (search-forward "constructor")
          (setq info (leaner-ts-infoview))
          (leaner-ts-test--await (lambda () (with-current-buffer info leaner-ts--info-session)) "initial infoview")
          (with-current-buffer info
            (push (and (string-match-p "Goal 1 (left)" (buffer-string))
                       (string-match-p "⊢ q" (buffer-string)) t) checks)
            (goto-char (point-min)) (search-forward "⊢ q") (backward-char)
            (let* ((session leaner-ts--info-session)
                   (ref (get-text-property (point) 'leaner-ts-info))
                   (popup (leaner-ts-test--rpc session leaner-ts--info-position
                                               "Lean.Widget.InteractiveDiagnostics.infoToInteractive" ref)))
              (push (equal "Prop" (leaner-ts--tagged-text (plist-get popup :type))) checks)
              (setq pin (leaner-ts-infoview-pin))
              (leaner-ts-infoview-freeze-mode 1)
              (with-current-buffer source (goto-char (point-min)) (search-forward "n + n"))
              (leaner-ts--info-refresh)
              (push (eq session leaner-ts--info-session) checks)
              (leaner-ts-infoview-freeze-mode -1)
              (leaner-ts-test--await (lambda () (with-current-buffer info (not (eq session leaner-ts--info-session)))) "term goal")
              (push (and (string-match-p "Expected type" (buffer-string))
                         (string-match-p "Nat" (buffer-string)) t) checks)
              (push (and (leaner-ts--session-closed session)
                         (null (leaner-ts--session-refs session))) checks)))
          (with-current-buffer source
            (goto-char (point-min)) (search-forward "theorem double_spec") (search-forward ":= by"))
          (with-current-buffer info
            (let ((old leaner-ts--info-session))
              (leaner-ts--info-refresh t)
              (leaner-ts-test--await (lambda () (with-current-buffer info (not (eq old leaner-ts--info-session)))) "definition goal"))
            (goto-char (point-min)) (search-forward "double")
            (let* ((ref (get-text-property (- (point) 6) 'leaner-ts-info))
                   (locations (leaner-ts-test--rpc leaner-ts--info-session leaner-ts--info-position
                                                   "Lean.Widget.getGoToLocation"
                                                   (list :kind "definition" :info ref))))
              (push (and (length> locations 0)
                         (string-suffix-p "Fixture.lean" (plist-get (aref locations 0) :targetUri))
                         (save-window-excursion
                           (leaner-ts-lsp-visit-location server (aref locations 0))
                           (eq (current-buffer) source))) checks)))
          (with-current-buffer pin
            (let ((pos (marker-position leaner-ts--info-source)))
              (leaner-ts--info-refresh)
              (push (= pos (marker-position leaner-ts--info-source)) checks)))
          (with-current-buffer source
            (let ((modules (leaner-ts--modules)))
              (push (and (assoc "Fixture" modules) (file-readable-p (cdr (assoc "Init.Prelude" modules)))) checks))
            (goto-char (point-min)) (search-forward "#check")
            (with-current-buffer info (leaner-ts--info-refresh t))
            (leaner-ts-test--await
             (lambda () (with-current-buffer info (string-match-p "Integration.double" (buffer-string)))) "interactive diagnostics")
            (push t checks)
            (goto-char (point-min)) (search-forward "#synth")
            (with-current-buffer info
              (let ((old leaner-ts--info-session))
                (leaner-ts--info-refresh t)
                (leaner-ts-test--await (lambda () (with-current-buffer info (not (eq old leaner-ts--info-session)))) "trace diagnostics"))
              (push (and (string-match-p "synthInstance" (buffer-string)) t) checks)
              (let ((pos (text-property-not-all (point-min) (point-max) 'leaner-ts-lazy nil)))
                (unless pos (error "The trace fixture did not produce lazy children"))
                (leaner-ts--info-expand-trace (button-at pos))
                (leaner-ts-test--await
                 (lambda () (with-current-buffer info
                              (not (get-text-property pos 'leaner-ts-lazy)))) "lazy trace expansion")
                (push t checks)))
            (goto-char (point-max))
            (insert "\nexample : True := by\n  exact missingIdentifier\n")
            (leaner-ts-lsp-position)
            (leaner-ts-lsp-request
             server :textDocument/waitForDiagnostics
             (list :uri (plist-get (plist-get (leaner-ts-lsp-position) :textDocument) :uri)
                   :version eglot--docver) 20)
            (flymake-start nil t)
            (leaner-ts-test--await (lambda () (with-current-buffer source (flymake-diagnostics))) "Flymake errors")
            (push (cl-some (lambda (diagnostic) (string-match-p "missingIdentifier" (flymake-diagnostic-text diagnostic)))
                           (flymake-diagnostics)) checks))
          (unless (cl-every #'identity checks) (error "Failed Lean integration checks: %S" (reverse checks)))
          (length checks))
      (when (buffer-live-p info) (kill-buffer info))
      (when (buffer-live-p pin) (kill-buffer pin))
      (when (and server (jsonrpc-running-p server)) (eglot-shutdown server))
      (with-current-buffer source (set-buffer-modified-p nil))
      (kill-buffer source))))

(cort-deftest leaner-ts-mode/real-server
  '((:eq (leaner-ts-test--integration) 13)))

;;; leaner-ts-integration-tests.el ends here
