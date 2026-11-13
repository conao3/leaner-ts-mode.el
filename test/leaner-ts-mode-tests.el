;;; leaner-ts-mode-tests.el --- Test definitions for leaner-ts-mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Naoya Yamashita

;; Author: Naoya Yamashita <conao3@gmail.com>
;; Assisted-by: Codex:gpt-6.1-sol
;; URL: https://github.com/conao3/leaner-ts-mode.el

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

;; Test definitions for `leaner-ts-mode'.


;;; Code:

(require 'cort)
(require 'leaner-ts-mode)

(when-let* ((directory (getenv "LEANER_TS_GRAMMAR_DIR")))
  (add-to-list 'treesit-extra-load-path directory))

(unless (treesit-language-available-p 'leanflat)
  (error "Install the Lean grammar before running the editing tests"))

(defmacro leaner-ts-test--buffer (text &rest body)
  "Insert TEXT, activate the mode, and evaluate BODY in a temporary buffer."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (leaner-ts-mode)
     ,@body))

(defun leaner-ts-test--indent (text)
  "Return TEXT after indenting it as Lean."
  (leaner-ts-test--buffer text
    (indent-region (point-min) (point-max))
    (buffer-string)))

(cort-deftest leaner-ts-mode/editing
  '((:eq (leaner-ts-test--buffer "def value := 10\n" major-mode) 'leaner-ts-mode)
    (:eq (leaner-ts-test--buffer "" (leaner-ts-mode) (length (treesit-parser-list))) 1)
    (:equal (leaner-ts-test--buffer "def value := 10\n"
              (goto-char (point-min)) (comment-region (point-min) (point-max))
              (buffer-string))
            "-- def value := 10\n")
    (:eq (leaner-ts-test--buffer "/- outer /- nested -/ text -/\ndef value := 10\n"
           (nth 4 (syntax-ppss 20))) 2)
    (:eq (leaner-ts-test--buffer "def quote : Char := '\"'\ndef value := 10\n"
           (nth 3 (syntax-ppss (1- (point-max))))) nil)))

(cort-deftest leaner-ts-mode/indentation
  '((:equal (leaner-ts-test--indent "structure Pair where\nfirst : Nat\nsecond : Nat\n")
            "structure Pair where\n  first : Nat\n  second : Nat\n")
    (:equal (leaner-ts-test--indent "example : True := by\ntrivial\n")
            "example : True := by\n  trivial\n")
    (:equal (leaner-ts-test--indent "def main : IO Unit := do\nIO.println 42\nIO.println 43\n")
            "def main : IO Unit := do\n  IO.println 42\n  IO.println 43\n")
    (:equal (leaner-ts-test--indent "example : True := by -- explanation\ntrivial\n")
            "example : True := by -- explanation\n  trivial\n")
    (:equal (leaner-ts-test--indent "def text := \"by\"\ndef next := 1\n")
            "def text := \"by\"\ndef next := 1\n")
    (:equal (leaner-ts-test--indent "example : True ∧ True := by\nconstructor\n· trivial\n· trivial\n")
            "example : True ∧ True := by\n  constructor\n  · trivial\n  · trivial\n")
    (:equal (leaner-ts-test--indent "example : True := by\n  have h : True := by\n    trivial\n  exact h\n")
            "example : True := by\n  have h : True := by\n    trivial\n  exact h\n")
    (:equal (leaner-ts-test--indent "def pick (n : Nat) : Nat :=\nmatch n with\n| 0 =>\n1\n| k =>\nk\n")
            "def pick (n : Nat) : Nat :=\n  match n with\n  | 0 =>\n    1\n  | k =>\n    k\n")
    (:equal (leaner-ts-test--indent "def point := {\nx := 1\ny := 2\n}\n")
            "def point := {\n  x := 1\n  y := 2\n}\n")
    (:equal (leaner-ts-test--indent "example :\nTrue :=\nTrue.intro\n")
            "example :\n    True :=\n  True.intro\n")
    (:equal (leaner-ts-test--indent "example : True := by\n  · have h : True := by\ntrivial\n")
            "example : True := by\n  · have h : True := by\n      trivial\n")
    (:equal (leaner-ts-test--buffer "structure Data where\nx : Nat\n"
              (setq-local leaner-ts-indent-offset 4)
              (indent-region (point-min) (point-max)) (buffer-string))
            "structure Data where\n    x : Nat\n")
    (:equal (leaner-ts-test--indent "example : True := by\n  trivial\n\n#check True\n")
            "example : True := by\n  trivial\n\n#check True\n")))

(cort-deftest leaner-ts-mode/declarations
  '((:equal
     (leaner-ts-test--buffer
         "namespace Outer\nsection Vars\nvariable (n : Nat)\n/-- A definition. -/\n@[simp] private def twice (n : Nat) := n + n\nend Vars\nnamespace Inner\ntheorem ok : True := by\n  trivial\nend Inner\nend Outer\n"
       (mapcar #'car (funcall imenu-create-index-function)))
     '("Outer.twice" "Outer.Inner.ok"))
    (:equal
     (leaner-ts-test--buffer
         "/-\ndef fake := 1\n-/\ndef text := \"theorem fake : True := by trivial\"\n-- def hidden := 3\ndef real := 2\n"
       (mapcar #'car (leaner-ts--imenu)))
     '("text" "real"))
    (:equal
     (leaner-ts-test--buffer "@[simp, inline] def twice := 2\n"
       (mapcar #'car (leaner-ts--imenu)))
     '("twice"))
    (:equal
     (leaner-ts-test--buffer "def first := 1\n"
       (leaner-ts--imenu)
       (goto-char (point-max)) (insert "def second := 2\n")
       (mapcar #'car (leaner-ts--imenu)))
     '("first" "second"))
    (:equal
     (leaner-ts-test--buffer "/-- Documentation. -/\n@[simp]\nprivate def first := 1\n\ndef second := 2\n"
       (goto-char (point-max))
       (beginning-of-defun) (beginning-of-defun)
       (list (point) (funcall add-log-current-defun-function)))
     '(1 "first"))
    (:equal
     (leaner-ts-test--buffer "def first := 1\n#check first\ndef second := 2\n"
       (goto-char (point-min)) (end-of-defun)
       (buffer-substring-no-properties (point-min) (point)))
     "def first := 1\n")
    (:equal
     (leaner-ts-test--buffer "namespace Scope\ndef first := 1\nend Scope\n"
       (goto-char (point-min)) (outline-next-heading)
       (list (line-number-at-pos) (funcall outline-level)))
     '(2 2))))

(cort-deftest leaner-ts-mode/font-lock
  '((:eq
     (leaner-ts-test--buffer "def answer := 42\n"
       (font-lock-ensure) (get-text-property 5 'face))
     font-lock-function-name-face)
    (:eq
     (leaner-ts-test--buffer "structure Data where\n  n : Nat\n"
       (font-lock-ensure) (get-text-property 11 'face))
     font-lock-type-face)
    (:eq
     (leaner-ts-test--buffer "example : True := by sorry\n"
       (font-lock-ensure) (goto-char (point-min)) (search-forward "sorry")
       (get-text-property (- (point) 5) 'face))
     font-lock-warning-face)
    (:eq
     (leaner-ts-test--buffer "/-- Read me. -/\ndef name := \"Lean\"\n"
       (font-lock-ensure) (get-text-property 6 'face))
     font-lock-doc-face)
    (:eq
     (leaner-ts-test--buffer "-- theorem fake := sorry\n"
       (font-lock-ensure) (get-text-property 12 'face))
     font-lock-comment-face)))

(cort-deftest leaner-ts-mode/newline
  '((:equal
     (leaner-ts-test--buffer "example : True := by"
       (goto-char (point-max)) (newline-and-indent) (buffer-string))
     "example : True := by\n  ")
    (:equal
     (leaner-ts-test--buffer "structure Box where\n  value : Nat"
       (goto-char (point-max)) (newline-and-indent) (buffer-string))
     "structure Box where\n  value : Nat\n  ")
    (:equal
     (leaner-ts-test--buffer ""
       (indent-for-tab-command) (buffer-string))
     "")
    (:equal
     (leaner-ts-test--buffer "def name := \"by\""
       (goto-char (point-max)) (newline-and-indent) (buffer-string))
     "def name := \"by\"\n")))

(defun leaner-ts-test--lake-project ()
  "Check project discovery and compilation within nested Lake projects."
  (let ((root (make-temp-file "leaner-ts-project-" t)))
    (unwind-protect
        (let ((child (expand-file-name "src/exercise/" root)))
          (make-directory (expand-file-name "Library/" child) t)
          (with-temp-file (expand-file-name "lean-toolchain" root)
            (insert "leanprover/lean4:v4.35.0\n"))
          (with-temp-file (expand-file-name "lakefile.toml" child)
            (insert "name = \"exercise\"\n"))
          (with-temp-buffer
            (setq default-directory (expand-file-name "Library/" child))
            (leaner-ts-mode)
            (list (equal (project-root (project-current)) child)
                  (equal compile-command (concat "lake -d " (shell-quote-argument child) " build"))
                  (equal (project-root (leaner-ts--project-find root))
                         (file-name-as-directory root)))))
      (delete-directory root t))))

(cort-deftest leaner-ts-mode/project
  '((:equal (leaner-ts-test--lake-project) '(t t t))))

;;; leaner-ts-mode-tests.el ends here
