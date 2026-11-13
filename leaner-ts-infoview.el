;;; leaner-ts-infoview.el --- Lean editing facilities  -*- lexical-binding: t; -*-

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
(require 'button)
(require 'eldoc)
(require 'imenu)
(require 'outline)
(require 'leaner-ts-mode)
(require 'leaner-ts-lsp)

(defcustom leaner-ts-infoview-delay 0.3
  "Idle seconds before refreshing the Lean infoview."
  :type 'number
  :group 'leaner-ts)

(defvar-local leaner-ts--info-source nil
  "Marker identifying the source location for this infoview.")
(defvar-local leaner-ts--info-pinned nil
  "Non-nil when the infoview follows a fixed source marker.")
(defvar-local leaner-ts--info-session nil
  "RPC session owning the currently displayed references.")
(defvar-local leaner-ts--info-pending nil
  "RPC session currently preparing an updated display.")
(defvar-local leaner-ts--info-position nil
  "LSP position associated with the displayed RPC data.")
(defvar-local leaner-ts--info-last-key nil
  "Last requested source, modification tick, point and connection.")
(defvar-local leaner-ts--info-serial 0
  "Generation number for rejecting stale asynchronous responses.")
(defvar-local leaner-ts--info-timer nil
  "Idle timer for this infoview.")
(defvar leaner-ts--render-info nil
  "Dynamically bound reference for the innermost rendered expression.")

(defvar leaner-ts-infoview-freeze-mode)

(define-button-type 'leaner-ts-term
  'follow-link t
  'help-echo "RET: definition; move point here for type and documentation"
  'action #'leaner-ts--info-definition)

(defun leaner-ts--tagged-text (value)
  "Return the plain text contained in Lean tagged VALUE."
  (cond
   ((stringp value) value)
   ((plist-member value :text) (plist-get value :text))
   ((plist-member value :append)
    (mapconcat #'leaner-ts--tagged-text (plist-get value :append) ""))
   ((plist-member value :tag) (leaner-ts--tagged-text (aref (plist-get value :tag) 1)))
   (t "")))

(defun leaner-ts--insert-text (text)
  "Insert TEXT with an expression button when a reference is available."
  (if (and leaner-ts--render-info (not (string-empty-p text)))
      (insert-text-button text 'type 'leaner-ts-term 'leaner-ts-info leaner-ts--render-info)
    (insert text)))

(defun leaner-ts--insert-tagged (value)
  "Render Lean tagged VALUE, preserving partial-expression references."
  (cond
   ((stringp value) (leaner-ts--insert-text value))
   ((plist-member value :text) (leaner-ts--insert-text (plist-get value :text)))
   ((plist-member value :append)
    (mapc #'leaner-ts--insert-tagged (plist-get value :append)))
   ((plist-member value :tag)
    (let* ((tag (plist-get value :tag))
           (meta (aref tag 0))
           (body (aref tag 1))
           (start (point)))
      (cond
       ((plist-member meta :expr) (leaner-ts--insert-tagged (plist-get meta :expr)))
       ((plist-member meta :goal) (leaner-ts--insert-goal (plist-get meta :goal) "Goal" 3))
       ((plist-member meta :widget)
        (leaner-ts--insert-tagged (plist-get (plist-get meta :widget) :alt)))
       ((plist-member meta :trace) (leaner-ts--insert-trace (plist-get meta :trace)))
       (t (let ((leaner-ts--render-info (or (plist-get meta :info) leaner-ts--render-info)))
            (leaner-ts--insert-tagged body))))
      (when-let* ((diff (plist-get meta :diffStatus)))
        (add-face-text-property start (point)
                                (pcase diff
                                  ((or "wasInserted" "willInsert") 'diff-added)
                                  ((or "wasDeleted" "willDelete") 'diff-removed)
                                  (_ 'font-lock-warning-face)) t))))))

(defun leaner-ts--insert-goal (goal title level)
  "Insert GOAL under TITLE as an outline heading at LEVEL."
  (insert (make-string level ?*) " " title)
  (when-let* ((name (plist-get goal :userName))) (insert " (" name ")"))
  (insert "\n")
  (mapc (lambda (hyp)
          (insert (make-string (1+ level) ?*) " "
                  (mapconcat #'identity (plist-get hyp :names) " ") " : ")
          (leaner-ts--insert-tagged (plist-get hyp :type))
          (when-let* ((value (plist-get hyp :val)))
            (insert " := ") (leaner-ts--insert-tagged value))
          (insert "\n"))
        (plist-get goal :hyps))
  (insert (make-string (1+ level) ?*) " " (or (plist-get goal :goalPrefix) "⊢ "))
  (leaner-ts--insert-tagged (plist-get goal :type))
  (insert "\n\n"))

(defun leaner-ts--insert-trace (trace)
  "Insert a TRACE node with strict or lazy children."
  (let ((children (plist-get trace :children)))
    (insert "\n*** " (plist-get trace :cls) "\n")
    (leaner-ts--insert-tagged (plist-get trace :msg))
    (insert "\n")
    (cond
     ((plist-member children :strict)
      (mapc #'leaner-ts--insert-tagged (plist-get children :strict)))
     ((plist-member children :lazy)
      (insert-text-button "Expand trace" 'follow-link t
                          'leaner-ts-lazy (plist-get children :lazy)
                          'action #'leaner-ts--info-expand-trace)
      (insert "\n")))))

(defun leaner-ts--info-render (goals term diagnostics)
  "Render GOALS, TERM and DIAGNOSTICS to a propertized string."
  (with-temp-buffer
    (insert "* Goals\n")
    (if (length> (plist-get goals :goals) 0)
        (cl-loop for goal across (plist-get goals :goals) for index from 1
                 do (leaner-ts--insert-goal goal (format "Goal %d" index) 2))
      (insert "No goals at this position.\n\n"))
    (when term
      (insert "* Expected type\n")
      (leaner-ts--insert-goal term "Term" 2))
    (insert "* Messages\n")
    (if (length> diagnostics 0)
        (mapc (lambda (diagnostic)
                (insert "** " (pcase (plist-get diagnostic :severity)
                                (1 "Error") (2 "Warning") (_ "Message")) "\n")
                (leaner-ts--insert-tagged (plist-get diagnostic :message))
                (insert "\n\n")) diagnostics)
      (insert "No messages on this line.\n"))
    (buffer-string)))

(defun leaner-ts--info-install (text session position)
  "Install rendered TEXT backed by SESSION and POSITION, retaining view state."
  (let ((inhibit-read-only t)
        (old-point (point))
        (windows (mapcar (lambda (window) (list window (window-start window) (window-point window)))
                         (get-buffer-window-list (current-buffer) nil t))))
    (leaner-ts--rpc-close leaner-ts--info-session)
    (setq leaner-ts--info-session session leaner-ts--info-pending nil
          leaner-ts--info-position position)
    (if (equal (buffer-substring-no-properties (point-min) (point-max))
               (substring-no-properties text))
        (with-silent-modifications
          (remove-list-of-text-properties
           (point-min) (point-max)
           '(button category action follow-link help-echo mouse-face face leaner-ts-info leaner-ts-lazy))
          (let ((pos 0))
            (while (< pos (length text))
              (let ((next (next-property-change pos text (length text))))
                (add-text-properties (1+ pos) (1+ next) (text-properties-at pos text))
                (setq pos next)))))
      (erase-buffer) (insert text))
    (goto-char (min old-point (point-max)))
    (dolist (state windows)
      (when (window-live-p (car state))
        (set-window-start (car state) (min (nth 1 state) (point-max)) t)
        (set-window-point (car state) (min (nth 2 state) (point-max)))))))

(defun leaner-ts--info-valid-p (buffer serial source tick)
  "Check BUFFER, SERIAL, SOURCE and TICK against a pending response."
  (and (buffer-live-p buffer) (buffer-live-p source)
       (= tick (buffer-chars-modified-tick source))
       (with-current-buffer buffer (= serial leaner-ts--info-serial))))

(defun leaner-ts--info-fetch (buffer source position key)
  "Fetch the data for BUFFER at SOURCE's POSITION using request KEY."
  (let* ((serial (with-current-buffer buffer (cl-incf leaner-ts--info-serial)))
         (tick (buffer-chars-modified-tick source))
         (connection (with-current-buffer source (leaner-ts-lsp-current)))
         (uri (plist-get (plist-get position :textDocument) :uri))
         (valid (lambda () (leaner-ts--info-valid-p buffer serial source tick))))
    (cl-labels
        ((failed (session error)
           (leaner-ts--rpc-close session)
           (when (funcall valid)
             (with-current-buffer buffer
               (setq leaner-ts--info-pending nil
                     header-line-format (format "Lean: %s" (plist-get error :message)))
               (when (= (or (plist-get error :code) 0) -32900)
                 (setq leaner-ts--info-last-key nil)))))
         (request (session)
           (if (not (funcall valid)) (leaner-ts--rpc-close session)
             (with-current-buffer buffer
               (leaner-ts--rpc-close leaner-ts--info-pending)
               (setq leaner-ts--info-pending session))
             (leaner-ts--rpc-call
              session position "Lean.Widget.getInteractiveGoals" position
              (lambda (goals)
                (if (not (funcall valid)) (leaner-ts--rpc-close session)
                  (leaner-ts--rpc-call
                   session position "Lean.Widget.getInteractiveTermGoal" position
                   (lambda (term)
                     (if (not (funcall valid)) (leaner-ts--rpc-close session)
                       (let ((line (plist-get (plist-get position :position) :line)))
                         (leaner-ts--rpc-call
                          session position "Lean.Widget.getInteractiveDiagnostics"
                          (list :lineRange (list :start line :end (1+ line)))
                          (lambda (diagnostics)
                            (if (not (funcall valid)) (leaner-ts--rpc-close session)
                              (with-current-buffer buffer
                                (setq header-line-format
                                      (format "%s:%d" (buffer-name source) (1+ line)))
                                (leaner-ts--info-install
                                 (leaner-ts--info-render goals term diagnostics) session position))))
                          (lambda (error) (failed session error))))))
                   (lambda (error) (failed session error)))))
              (lambda (error) (failed session error))))))
      (with-current-buffer buffer (setq leaner-ts--info-last-key key))
      (leaner-ts--rpc-connect connection uri #'request (lambda (error) (failed nil error))))))

(defun leaner-ts--info-refresh (&optional force)
  "Refresh this infoview from its source, or unconditionally with FORCE."
  (unless (and leaner-ts-infoview-freeze-mode (not force))
    (let ((selected (window-buffer (selected-window))))
      (when (and (not leaner-ts--info-pinned)
                 (with-current-buffer selected (derived-mode-p 'leaner-ts-mode)))
        (set-marker leaner-ts--info-source (window-point (selected-window)) selected)))
    (when-let* ((source (and leaner-ts--info-source (marker-buffer leaner-ts--info-source))))
      (let ((buffer (current-buffer))
            (source-point (marker-position leaner-ts--info-source)))
        (unless leaner-ts--info-pinned
          (when-let* ((window (get-buffer-window source t)))
            (setq source-point (window-point window))
            (set-marker leaner-ts--info-source source-point)))
        (condition-case error
            (with-current-buffer source
              (save-excursion
                (goto-char source-point)
                (let* ((connection (leaner-ts-lsp-current))
                       (key (list source (buffer-chars-modified-tick) (point) connection)))
                  (unless (and (not force)
                               (with-current-buffer buffer (equal key leaner-ts--info-last-key)))
                    (leaner-ts--info-fetch buffer source (leaner-ts-lsp-position) key)))))
          (user-error (setq header-line-format (error-message-string error))))))))

(defun leaner-ts--info-idle (buffer)
  "Refresh BUFFER from its idle timer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (and leaner-ts--info-source (marker-buffer leaner-ts--info-source))
          (leaner-ts--info-refresh)
        (setq header-line-format "Lean source buffer closed")
        (leaner-ts--info-cleanup)))))

(defun leaner-ts--info-revert (&rest _)
  "Refresh the current infoview explicitly."
  (leaner-ts--info-refresh t))

(defun leaner-ts--info-cleanup ()
  "Stop timers and release RPC data owned by the current infoview."
  (cl-incf leaner-ts--info-serial)
  (when (timerp leaner-ts--info-timer) (cancel-timer leaner-ts--info-timer))
  (leaner-ts--rpc-close leaner-ts--info-pending)
  (leaner-ts--rpc-close leaner-ts--info-session)
  (setq leaner-ts--info-timer nil leaner-ts--info-pending nil leaner-ts--info-session nil)
  (when leaner-ts--info-source (set-marker leaner-ts--info-source nil)))

(defun leaner-ts--info-index ()
  "Return an Imenu index of goals, hypotheses and messages."
  (save-excursion
    (goto-char (point-min))
    (let (entries)
      (while (re-search-forward "^\\*+ \\(.*\\)$" nil t)
        (push (cons (match-string-no-properties 1) (line-beginning-position)) entries))
      (nreverse entries))))

(defvar-keymap leaner-ts-infoview-mode-map
  :doc "Keymap for the Lean infoview."
  :parent special-mode-map
  "g" #'revert-buffer
  "f" #'leaner-ts-infoview-freeze-mode
  "p" #'leaner-ts-infoview-pin
  "M-." #'leaner-ts--info-definition)

(define-derived-mode leaner-ts-infoview-mode special-mode "Lean Info"
  "Display Lean goals, terms and diagnostics with interactive subexpressions."
  (setq-local outline-regexp "\\*+ "
              imenu-create-index-function #'leaner-ts--info-index
              revert-buffer-function #'leaner-ts--info-revert)
  (outline-minor-mode 1)
  (add-hook 'eldoc-documentation-functions #'leaner-ts--info-eldoc nil t)
  (eldoc-mode 1)
  (add-hook 'kill-buffer-hook #'leaner-ts--info-cleanup nil t))

;;;###autoload
(define-minor-mode leaner-ts-infoview-freeze-mode
  "Freeze automatic updates of this Lean infoview."
  :lighter " Frozen"
  (unless (derived-mode-p 'leaner-ts-infoview-mode)
    (setq leaner-ts-infoview-freeze-mode nil)
    (user-error "Freeze is available in a Lean infoview buffer"))
  (cl-incf leaner-ts--info-serial)
  (unless leaner-ts-infoview-freeze-mode (leaner-ts--info-refresh t)))

(defun leaner-ts--info-create (source pinned name)
  "Create an infoview for SOURCE with PINNED state and buffer NAME."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'leaner-ts-infoview-mode) (leaner-ts-infoview-mode))
      (when leaner-ts--info-source (set-marker leaner-ts--info-source nil))
      (setq leaner-ts--info-source (copy-marker source)
            leaner-ts--info-pinned pinned)
      (unless (timerp leaner-ts--info-timer)
        (setq leaner-ts--info-timer
              (run-with-idle-timer leaner-ts-infoview-delay t #'leaner-ts--info-idle buffer)))
      (leaner-ts--info-refresh t))
    (display-buffer buffer)
    buffer))

;;;###autoload
(defun leaner-ts-infoview ()
  "Display automatically updated Lean goals for the current source buffer."
  (interactive)
  (require 'leaner-ts-eglot)
  (leaner-ts-eglot-ensure)
  (leaner-ts-lsp-current)
  (leaner-ts--info-create (point-marker) nil "*leaner-ts-info*"))

;;;###autoload
(defun leaner-ts-infoview-pin ()
  "Open an infoview pinned to the current Lean source location."
  (interactive)
  (unless (or (derived-mode-p 'leaner-ts-mode) (derived-mode-p 'leaner-ts-infoview-mode))
    (user-error "Pin a location from a Lean source or infoview buffer"))
  (let* ((source (if (derived-mode-p 'leaner-ts-infoview-mode)
                     leaner-ts--info-source (point-marker)))
         (buffer (marker-buffer source)))
    (unless buffer (user-error "The Lean source buffer has been closed"))
    (leaner-ts--info-create
     source t (generate-new-buffer-name
               (format "*leaner-ts-info: %s:%d*" (buffer-name buffer)
                       (with-current-buffer buffer (line-number-at-pos source)))))))

(defun leaner-ts--info-eldoc (callback &rest _)
  "Pass the hovered partial term's type and documentation to CALLBACK."
  (when-let* ((ref (get-text-property (point) 'leaner-ts-info))
              (session leaner-ts--info-session))
    (let ((buffer (current-buffer)) (serial leaner-ts--info-serial))
      (leaner-ts--rpc-call
       session leaner-ts--info-position "Lean.Widget.InteractiveDiagnostics.infoToInteractive" ref
       (lambda (popup)
         (unwind-protect
             (when (and (buffer-live-p buffer)
                        (with-current-buffer buffer (= serial leaner-ts--info-serial)))
               (funcall callback
                        (string-join
                         (delq nil (list (when (plist-get popup :type)
                                           (leaner-ts--tagged-text (plist-get popup :type)))
                                         (plist-get popup :doc))) "\n\n")))
           (leaner-ts--rpc-release-value session popup)))
       (lambda (error)
         (leaner-ts--info-rpc-error buffer error)
         (funcall callback nil)))
      t)))

(defun leaner-ts--info-rpc-error (buffer error)
  "Schedule a refresh of BUFFER when ERROR reports an expired RPC session."
  (when (and (buffer-live-p buffer) (= (or (plist-get error :code) 0) -32900))
    (with-current-buffer buffer (setq leaner-ts--info-last-key nil))))

(defun leaner-ts--info-definition (&optional button)
  "Visit the definition referenced by BUTTON or the term at point."
  (interactive)
  (let ((ref (if button (button-get button 'leaner-ts-info)
               (get-text-property (point) 'leaner-ts-info)))
        (session leaner-ts--info-session)
        (buffer (current-buffer)))
    (unless (and ref session) (user-error "There is no Lean term at point"))
    (leaner-ts--rpc-call
     session leaner-ts--info-position "Lean.Widget.getGoToLocation"
     (list :kind "definition" :info ref)
     (lambda (locations)
       (if (length> locations 0)
           (leaner-ts-lsp-visit-location (leaner-ts--session-connection session) (aref locations 0))
         (message "No definition location for this term")))
     (lambda (error)
       (leaner-ts--info-rpc-error buffer error)
       (message "Lean definition: %s" (plist-get error :message))))))

(defun leaner-ts--info-expand-trace (button)
  "Expand the lazy trace represented by BUTTON."
  (let ((buffer (current-buffer))
        (start (copy-marker (button-start button)))
        (end (copy-marker (button-end button) t))
        (serial leaner-ts--info-serial)
        (session leaner-ts--info-session))
    (leaner-ts--rpc-call
     session leaner-ts--info-position "Lean.Widget.lazyTraceChildrenToInteractive"
     (button-get button 'leaner-ts-lazy)
     (lambda (children)
       (unwind-protect
           (when (and (buffer-live-p buffer)
                      (with-current-buffer buffer (= serial leaner-ts--info-serial)))
             (with-current-buffer buffer
               (let ((inhibit-read-only t))
                 (save-excursion
                   (delete-region start end) (goto-char start)
                   (mapc #'leaner-ts--insert-tagged children)))))
         (set-marker start nil) (set-marker end nil)))
     (lambda (error)
       (leaner-ts--info-rpc-error buffer error)
       (set-marker start nil) (set-marker end nil)
       (message "Lean trace: %s" (plist-get error :message))))))

(defun leaner-ts-eldoc-goal (callback &rest _)
  "Pass a one-line goal at the source position to CALLBACK."
  (let ((connection (leaner-ts-lsp-current))
        (position (leaner-ts-lsp-position)))
    (leaner-ts-lsp-request-async
     connection :$/lean/plainGoal position
     (lambda (goal)
       (funcall callback (car (split-string (or (plist-get goal :rendered) "") "\n" t))))
     (lambda (_error) (funcall callback nil)))
    t))

(provide 'leaner-ts-infoview)

;;; leaner-ts-infoview.el ends here
