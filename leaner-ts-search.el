;;; leaner-ts-search.el --- Lean editing facilities  -*- lexical-binding: t; -*-

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
(require 'json)
(require 'url)
(require 'leaner-ts-mode)

(defcustom leaner-ts-loogle-url "https://loogle.lean-lang.org/json"
  "Endpoint used for interactive Loogle queries."
  :type 'string
  :group 'leaner-ts)

(defvar-local leaner-ts--module-cache nil
  "Cached project root and module source table.")

(defun leaner-ts--module-source (directory relative)
  "Find the source for RELATIVE module in a Lean library DIRECTORY."
  (let ((root (cond
               ((string-match "/\\.lake/build/lib/lean/?\\'" directory)
                (substring directory 0 (match-beginning 0)))
               ((string-match "/lib/lean/?\\'" directory)
                (concat (substring directory 0 (match-beginning 0)) "/src/lean"))
               (t directory))))
    (expand-file-name (concat relative ".lean") root)))

(defun leaner-ts--modules (&optional refresh)
  "Return the current Lake project's module table, optionally REFRESH it."
  (let ((root (project-root (project-current t))))
    (if (and (not refresh) (equal root (car leaner-ts--module-cache)))
        (cdr leaner-ts--module-cache)
      (let ((default-directory root)
            (table (make-hash-table :test #'equal)))
        (with-temp-buffer
          (unless (eq 0 (process-file "lake" nil t nil "env" "printenv" "LEAN_PATH"))
            (error "Could not read Lake's module path: %s" (buffer-string)))
          (dolist (directory (parse-colon-path (string-trim (buffer-string))))
            (setq directory (expand-file-name directory root))
            (when (file-directory-p directory)
              (dolist (file (directory-files-recursively directory "\\.olean\\'"))
                (let* ((relative (file-name-sans-extension (file-relative-name file directory)))
                       (name (replace-regexp-in-string "/" "." relative)))
                  (unless (gethash name table)
                    (puthash name (leaner-ts--module-source directory relative) table)))))))
        (dolist (file (directory-files-recursively
                       root "\\.lean\\'" nil
                       (lambda (dir)
                         (not (member (file-name-nondirectory (directory-file-name dir))
                                      '(".lake" ".git" ".claude-dev"))))))
          (unless (member (file-name-nondirectory file) '("lakefile.lean"))
            (puthash (replace-regexp-in-string
                      "/" "." (file-name-sans-extension (file-relative-name file root))) file table)))
        (setq leaner-ts--module-cache
              (cons root (sort (cl-loop for name being the hash-keys of table
                                        using (hash-values source) collect (cons name source))
                               (lambda (a b) (string-lessp (car a) (car b))))))
        (cdr leaner-ts--module-cache)))))

(defun leaner-ts--module-table (modules)
  "Return a completion table with metadata for MODULES."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata
          (category . leaner-ts-module)
          (annotation-function . ,(lambda (name) (concat "  " (cdr (assoc name modules)))))
          (group-function . ,(lambda (name transform)
                               (if transform name (car (split-string name "\\."))))))
      (complete-with-action action modules string predicate))))

(defun leaner-ts-module-completion-at-point ()
  "Complete a module name following Lean's import command."
  (when (and (not (nth 8 (syntax-ppss)))
             (save-excursion
               (re-search-backward "^[ \t]*import[ \t]+\\(?:all[ \t]+\\)?[[:alnum:]_.' ]*\\="
                                   (line-beginning-position) t)))
    (let ((end (point))
          (start (save-excursion (skip-chars-backward "[:alnum:]_.'") (point))))
      (list start end (leaner-ts--module-table (leaner-ts--modules)) :exclusive 'no))))

;;;###autoload
(defun leaner-ts-find-module (&optional refresh)
  "Find a Lean module's source, rebuilding the index with prefix REFRESH."
  (interactive "P")
  (let* ((modules (leaner-ts--modules refresh))
         (name (completing-read "Lean module: " (leaner-ts--module-table modules) nil t))
         (source (cdr (assoc name modules))))
    (unless (file-readable-p source)
      (user-error "Source is unavailable for module %s: %s" name source))
    (find-file source)))

(defun leaner-ts--loogle-table (hits)
  "Return a completion table with types and modules from Loogle HITS."
  (let ((names (mapcar (lambda (hit) (plist-get hit :name)) hits)))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          `(metadata
            (category . leaner-ts-declaration)
            (annotation-function
             . ,(lambda (name)
                  (let ((hit (cl-find name hits :test #'equal
                                      :key (lambda (item) (plist-get item :name)))))
                    (concat "  " (string-trim (or (plist-get hit :type) ""))))))
            (group-function
             . ,(lambda (name transform)
                  (if transform name
                    (plist-get (cl-find name hits :test #'equal
                                        :key (lambda (item) (plist-get item :name))) :module)))))
        (complete-with-action action names string predicate)))))

(defun leaner-ts--loogle-select (data marker)
  "Select a declaration from Loogle DATA and insert it at MARKER."
  (unwind-protect
      (if-let* ((hits (plist-get data :hits)))
          (when (marker-buffer marker)
            (let ((name (completing-read "Lean declaration: " (leaner-ts--loogle-table hits) nil t)))
              (with-current-buffer (marker-buffer marker)
                (goto-char marker) (insert name))))
        (user-error "%s" (or (plist-get data :error) "Loogle found no declarations")))
    (set-marker marker nil)))

;;;###autoload
(defun leaner-ts-search (query)
  "Search Loogle for QUERY, then select a declaration to insert."
  (interactive (list (read-string "Loogle query: " (thing-at-point 'symbol t))))
  (let ((marker (copy-marker (point) t))
        (url-request-extra-headers '(("User-Agent" . "leaner-ts-mode/0.2.0"))))
    (url-retrieve
     (concat leaner-ts-loogle-url "?q=" (url-hexify-string query))
     (lambda (status)
       (unwind-protect
           (if (plist-get status :error)
               (progn (set-marker marker nil)
                      (message "Loogle request failed: %s" (plist-get status :error)))
             (goto-char (point-min))
             (re-search-forward "\r?\n\r?\n")
             (let ((data (json-parse-buffer :object-type 'plist :array-type 'list
                                            :null-object nil :false-object nil)))
               (run-at-time 0 nil #'leaner-ts--loogle-select data marker)))
         (kill-buffer (current-buffer)))) nil t t)))

(provide 'leaner-ts-search)

;;; leaner-ts-search.el ends here
