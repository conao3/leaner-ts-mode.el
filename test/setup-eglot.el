;;; setup-eglot.el --- Prepare the integration test dependency -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Naoya Yamashita
;; Assisted-by: Codex:gpt-6.1-sol
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Install the current GNU ELPA Eglot in the test sandbox when needed.

;;; Code:

(require 'package)
(setq package-user-dir (or (getenv "KEGLINTPACKAGEUSERDIR")
                           (error "Run this setup through keg exec"))
      package-gnupghome-dir (expand-file-name "gnupg" package-user-dir))
(package-initialize)
(unless (package-installed-p 'eglot '(1 20))
  (package-refresh-contents)
  (package-install (car (alist-get 'eglot package-archive-contents))))

;;; setup-eglot.el ends here
