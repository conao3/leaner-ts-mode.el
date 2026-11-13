;;; leaner-ts-input.el --- Lean editing facilities  -*- lexical-binding: t; -*-

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
(require 'quail)
(require 'leaner-ts-symbols)

(defun leaner-ts--quail-update (control)
  "Commit the Quail translation according to CONTROL and its cursor template."
  (when (numberp control)
    (if (zerop control)
        (setq quail-current-str quail-current-key)
      (quail-add-unread-command-events (substring quail-current-key control))))
  (when (and (null control) (null quail-current-str))
    (setq quail-current-str quail-current-key)
    (when input-method-exit-on-first-char (setq control t)))
  (when (and control (> (length quail-current-key) 0))
    (let* ((key (substring quail-current-key 1 (when (numberp control) (max 1 control))))
           (expansion (cdr (assoc key leaner-ts--abbreviations)))
           (cursor (and expansion (string-match (regexp-quote "$CURSOR") expansion))))
      (when cursor
        (quail-add-unread-command-events
         (make-vector (- (length expansion) cursor (length "$CURSOR")) 'left)))))
  control)

(defun leaner-ts--quail-select ()
  "Commit the current Lean abbreviation, including its cursor template."
  (interactive)
  (quail-update-translation t))

(defun leaner-ts--insert-expansion (expansion)
  "Insert EXPANSION, positioning point at its cursor placeholder."
  (let ((start (point))
        (cursor (string-match (regexp-quote "$CURSOR") expansion)))
    (insert (replace-regexp-in-string (regexp-quote "$CURSOR") "" expansion t t))
    (when cursor (goto-char (+ start cursor)))))

(defun leaner-ts--symbol-annotation (candidate)
  "Return the Unicode expansion and name for CANDIDATE."
  (when-let* ((value (cdr (assoc candidate leaner-ts--abbreviations)))
              (clean (replace-regexp-in-string (regexp-quote "$CURSOR") "" value t t)))
    (format "  %s  %s" clean
            (if (string-empty-p clean) ""
              (or (get-char-code-property (aref clean 0) 'name) "")))))

(defun leaner-ts--symbol-table (string predicate action)
  "Complete STRING with PREDICATE and ACTION using Lean abbreviations."
  (if (eq action 'metadata)
      '(metadata (category . leaner-ts-abbrev)
                 (annotation-function . leaner-ts--symbol-annotation))
    (complete-with-action action leaner-ts--abbreviations string predicate)))

;;;###autoload
(defun leaner-ts-insert-symbol (abbreviation)
  "Insert the Unicode expansion of ABBREVIATION."
  (interactive (list (completing-read "Lean symbol: " #'leaner-ts--symbol-table nil t)))
  (let ((expansion (cdr (assoc abbreviation leaner-ts--abbreviations))))
    (unless expansion (user-error "Unknown Lean abbreviation: %s" abbreviation))
    (leaner-ts--insert-expansion expansion)))

(defun leaner-ts-symbol-completion-at-point ()
  "Complete the Lean abbreviation following a backslash at point."
  (let ((end (point)))
    (save-excursion
      (when (and (search-backward "\\" (line-beginning-position) t)
                 (not (string-match-p "[ \t\n]"
                                      (buffer-substring-no-properties (1+ (point)) end))))
        (let ((start (point)))
          (list (1+ start) end #'leaner-ts--symbol-table
                :exclusive 'no
                :exit-function
                (lambda (candidate status)
                  (when (eq status 'finished)
                    (delete-region start (point))
                    (goto-char start)
                    (leaner-ts--insert-expansion
                     (cdr (assoc candidate leaner-ts--abbreviations)))))))))))

(quail-define-package
 "Leaner" "UTF-8" "ℒ" t
 "Lean Unicode abbreviations.  Type a backslash followed by an abbreviation."
 '(("\t" . leaner-ts--quail-select)) t t nil nil t nil nil
 #'leaner-ts--quail-update nil t)

(dolist (entry leaner-ts--abbreviations)
  (let* ((expansion (cdr entry))
         (translation (vector (replace-regexp-in-string
                               (regexp-quote "$CURSOR") "" expansion t t))))
    (quail-defrule
     (concat "\\" (car entry))
     translation
     "Leaner")))

(provide 'leaner-ts-input)

;;; leaner-ts-input.el ends here
