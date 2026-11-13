;;; setup-eglot.el --- Prepare the integration test dependency -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Naoya Yamashita
;; Assisted-by: Codex:gpt-6.1-sol
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Install the current GNU ELPA Eglot in the test sandbox when needed.

;;; Code:

(require 'package)
(require 'eglot)
(unless (fboundp 'eglot-semantic-tokens-mode)
  (package-refresh-contents)
  (package-install (car (alist-get 'eglot package-archive-contents))))

;;; setup-eglot.el ends here
