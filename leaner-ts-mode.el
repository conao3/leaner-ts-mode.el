;;; leaner-ts-mode.el --- Lean 4 major mode using tree-sitter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Naoya Yamashita

;; Author: Naoya Yamashita <conao3@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; Version: 0.0.1
;; Keywords: languages
;; Package-Requires: ((emacs "30.1"))
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

;; A major mode for the Lean 4 theorem prover and programming language,
;; built on the facilities Emacs already provides: tree-sitter for
;; syntax, `completing-read' and `completion-at-point' for completion,
;; Flymake for diagnostics, ElDoc for hover, xref for definitions, and
;; project.el for the project root.
;;
;; The package is under construction and does not define the major
;; mode yet.


;;; Code:

(defgroup leaner-ts nil
  "Lean 4 major mode using tree-sitter."
  :prefix "leaner-ts-"
  :group 'languages
  :link '(url-link :tag "Github" "https://github.com/conao3/leaner-ts-mode.el"))

(provide 'leaner-ts-mode)

;;; leaner-ts-mode.el ends here
