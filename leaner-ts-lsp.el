;;; leaner-ts-lsp.el --- Lean editing facilities  -*- lexical-binding: t; -*-

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

(require 'cl-lib)
(require 'jsonrpc)

(cl-defgeneric leaner-ts-lsp-current ()
  "Return the Lean connection managing the current source buffer.")

(cl-defgeneric leaner-ts-lsp-position ()
  "Return the current document and position in the negotiated encoding.")

(cl-defgeneric leaner-ts-lsp-request (connection method params &optional timeout)
  "Send METHOD with PARAMS to CONNECTION, waiting at most TIMEOUT seconds.")

(cl-defgeneric leaner-ts-lsp-request-async (connection method params success error)
  "Send METHOD and PARAMS to CONNECTION using SUCCESS and ERROR callbacks.")

(cl-defgeneric leaner-ts-lsp-notify (connection method params)
  "Notify CONNECTION of METHOD with PARAMS.")

(cl-defgeneric leaner-ts-lsp-visit-location (connection location)
  "Visit LOCATION returned by CONNECTION using its position encoding.")

(cl-defstruct (leaner-ts--session (:constructor leaner-ts--make-session))
              connection uri id refs timer closed)

(defun leaner-ts--rpc-refs (value)
  "Collect all RPC references nested in VALUE."
  (cond
   ((vectorp value) (apply #'append (mapcar #'leaner-ts--rpc-refs value)))
   ((and (consp value) (keywordp (car value)))
    (if (plist-member value :p) (list value)
      (cl-loop for (_key item) on value by #'cddr append (leaner-ts--rpc-refs item))))
   (t nil)))

(defun leaner-ts--rpc-track (session value)
  "Track references in VALUE returned for SESSION."
  (setf (leaner-ts--session-refs session)
        (append (leaner-ts--rpc-refs value) (leaner-ts--session-refs session)))
  (when (leaner-ts--session-closed session) (leaner-ts--rpc-release session))
  value)

(defun leaner-ts--rpc-release (session)
  "Release all remote references held by SESSION."
  (when (leaner-ts--session-refs session)
    (when (jsonrpc-running-p (leaner-ts--session-connection session))
      (leaner-ts-lsp-notify
       (leaner-ts--session-connection session) :$/lean/rpc/release
       (list :uri (leaner-ts--session-uri session)
             :sessionId (leaner-ts--session-id session)
             :refs (vconcat (leaner-ts--session-refs session)))))
    (setf (leaner-ts--session-refs session) nil)))

(defun leaner-ts--rpc-close (session)
  "Release references and cancel the keep-alive timer for SESSION."
  (when session
    (setf (leaner-ts--session-closed session) t)
    (when (timerp (leaner-ts--session-timer session))
      (cancel-timer (leaner-ts--session-timer session)))
    (leaner-ts--rpc-release session)))

(defun leaner-ts--rpc-release-value (session value)
  "Release SESSION's references from VALUE after extracting plain text."
  (let ((refs (leaner-ts--rpc-refs value)))
    (when (and refs (not (leaner-ts--session-closed session)))
      (when (jsonrpc-running-p (leaner-ts--session-connection session))
        (leaner-ts-lsp-notify
         (leaner-ts--session-connection session) :$/lean/rpc/release
         (list :uri (leaner-ts--session-uri session)
               :sessionId (leaner-ts--session-id session) :refs (vconcat refs))))
      (dolist (ref refs)
        (setf (leaner-ts--session-refs session)
              (cl-delete ref (leaner-ts--session-refs session) :test #'equal :count 1))))))

(defun leaner-ts--rpc-connect (connection uri success error)
  "Connect to CONNECTION for URI and call SUCCESS or ERROR."
  (leaner-ts-lsp-request-async
   connection :$/lean/rpc/connect (list :uri uri)
   (lambda (reply)
     (let ((session (leaner-ts--make-session
                     :connection connection :uri uri :id (plist-get reply :sessionId))))
       (setf (leaner-ts--session-timer session)
             (run-at-time
              10 10 (lambda ()
                      (if (jsonrpc-running-p connection)
                          (leaner-ts-lsp-notify
                           connection :$/lean/rpc/keepAlive
                           (list :uri uri :sessionId (leaner-ts--session-id session)))
                        (leaner-ts--rpc-close session)))))
       (funcall success session)))
   error))

(defun leaner-ts--rpc-call (session position method params success error)
  "Call SESSION's METHOD with PARAMS at POSITION using SUCCESS and ERROR."
  (leaner-ts-lsp-request-async
   (leaner-ts--session-connection session) :$/lean/rpc/call
   (append position (list :sessionId (leaner-ts--session-id session)
                          :method method :params params))
   (lambda (reply) (funcall success (leaner-ts--rpc-track session reply))) error))

(provide 'leaner-ts-lsp)

;;; leaner-ts-lsp.el ends here
