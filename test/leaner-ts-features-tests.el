;;; leaner-ts-features-tests.el --- Lean editing facilities  -*- lexical-binding: t; -*-

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
(require 'leaner-ts-input)
(require 'leaner-ts-infoview)
(require 'leaner-ts-search)

(cort-deftest leaner-ts-mode/symbols
  '((:equal (cdr (assoc "alpha" leaner-ts--abbreviations)) "α")
    (:eq (> (length leaner-ts--abbreviations) 1800) t)
    (:equal (with-temp-buffer (leaner-ts-insert-symbol "<>") (list (buffer-string) (point)))
            '("⟨⟩" 2))
    (:equal (with-temp-buffer
              (insert "\\alpha")
              (add-hook 'completion-at-point-functions #'leaner-ts-symbol-completion-at-point nil t)
              (completion-at-point) (buffer-string)) "α")
    (:equal (with-temp-buffer
              (set-input-method "Leaner")
              (let ((unread-command-events (string-to-list "alpha ")))
                (concat (quail-input-method ?\\)))) "α")
    (:equal (with-temp-buffer
              (set-input-method "Leaner")
              (let* ((unread-command-events (string-to-list "<> "))
                     (events (quail-input-method ?\\)))
                (dolist (event events)
                  (let ((last-command-event event)) (self-insert-command 1)))
                (while (equal (car unread-command-events) '(no-record . left))
                  (pop unread-command-events) (left-char)))
              (list (buffer-string) (point))) '("⟨⟩" 2))
    (:eq (completion-metadata-get
          (completion-metadata "" #'leaner-ts--symbol-table nil) 'category) 'leaner-ts-abbrev)))

(cort-deftest leaner-ts-mode/tagged-text
  '((:equal (leaner-ts--tagged-text '(:append [(:text "p") (:tag [(:info (:p "1")) (:text " → q")])]))
            "p → q")
    (:equal (leaner-ts--rpc-refs '(:type (:tag [(:info (:p "2")) (:text "Nat")]) :ctx (:p "3")))
            '((:p "2") (:p "3")))
    (:equal (with-temp-buffer
              (leaner-ts--insert-tagged '(:tag [(:info (:p "4")) (:text "Nat")]))
              (list (buffer-substring-no-properties (point-min) (point-max))
                    (get-text-property 1 'leaner-ts-info) (and (button-at 1) t)))
            '("Nat" (:p "4") t))
    (:eq (string-match-p "No goals" (leaner-ts--info-render nil nil [])) 8)))

(cort-deftest leaner-ts-mode/module-metadata
  '((:equal (leaner-ts--module-source "/work/pkg/.lake/build/lib/lean/" "Example/One")
            "/work/pkg/Example/One.lean")
    (:equal (leaner-ts--module-source "/toolchain/lib/lean/" "Init/Prelude")
            "/toolchain/src/lean/Init/Prelude.lean")
    (:eq (completion-metadata-get
          (completion-metadata "" (leaner-ts--module-table '(("Init" . "/Init.lean"))) nil)
          'category) 'leaner-ts-module)
    (:eq (completion-metadata-get
          (completion-metadata "" (leaner-ts--loogle-table '((:name "Nat.add" :type "Nat → Nat → Nat" :module "Init"))) nil)
          'category) 'leaner-ts-declaration)))

(cort-deftest leaner-ts-mode/infoview-state
  '((:equal (with-temp-buffer
              (leaner-ts-infoview-mode)
              (let ((inhibit-read-only t)) (insert "* Goals\n** One\n*** h : True\n"))
              (mapcar #'car (leaner-ts--info-index))) '("Goals" "One" "h : True"))
    (:eq (with-temp-buffer
           (leaner-ts-infoview-mode)
           (leaner-ts-infoview-freeze-mode 1)
           leaner-ts-infoview-freeze-mode) t)))

;;; leaner-ts-features-tests.el ends here
