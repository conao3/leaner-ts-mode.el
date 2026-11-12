;;; leaner-ts-mode-tests.el --- Test definitions for leaner-ts-mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Naoya Yamashita

;; Author: Naoya Yamashita <conao3@gmail.com>
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

(cort-deftest leaner-ts-mode/feature
  '((:eq (featurep 'leaner-ts-mode) t)))

(provide 'leaner-ts-mode-tests)

;;; leaner-ts-mode-tests.el ends here
