;;; leaner-ts-mode.el --- Lean 4 major mode using tree-sitter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Naoya Yamashita

;; Author: Naoya Yamashita <conao3@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5, Codex:gpt-6.1-sol
;; Version: 0.1.0
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
;; syntax, Imenu for declaration lookup, Outline for folding, project.el
;; for the project root, and `compile' for Lake builds.
;;
;; Install the grammar with `leaner-ts-install-grammar', then open a
;; .lean file.  C-c C-c builds the nearest Lake project.  Syntax editing,
;; declaration navigation, Imenu and Outline work without a Lean server.


;;; Code:

(require 'cl-lib)
(require 'treesit)
(require 'project)
(require 'compile)
(require 'imenu)
(require 'outline)

(defgroup leaner-ts nil
  "Lean 4 major mode using tree-sitter."
  :prefix "leaner-ts-"
  :group 'languages
  :link '(url-link :tag "Github" "https://github.com/conao3/leaner-ts-mode.el"))

(defcustom leaner-ts-indent-offset 2
  "Number of columns used for Lean indentation."
  :type 'natnum
  :safe #'natnump
  :group 'leaner-ts)

(defconst leaner-ts--grammar-revision
  "d3c99bdcfad217d289bc513c51e6f825fcf9484f"
  "Revision of tree-sitter-lean-flat used by this mode.")

(add-to-list 'treesit-language-source-alist
             '(leanflat "https://github.com/lua-vr/tree-sitter-lean-flat" "main"))

(add-to-list 'treesit-load-name-override-list
             '(leanflat "libtree-sitter-leanflat" "tree_sitter_lean"))

(defvar leaner-ts-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?' "_" table)
    (modify-syntax-entry ?/ ". 14n" table)
    (modify-syntax-entry ?- ". 123b" table)
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?\⟨ "(⟩" table)
    (modify-syntax-entry ?\⟩ ")⟨" table)
    (modify-syntax-entry ?\⦃ "(⦄" table)
    (modify-syntax-entry ?\⦄ ")⦃" table)
    table)
  "Syntax table for `leaner-ts-mode'.")

(defvar-keymap leaner-ts-mode-map
  :doc "Keymap for `leaner-ts-mode'."
  "C-c C-c" #'compile)

(defconst leaner-ts--declaration-keywords
  '("def" "theorem" "lemma" "abbrev" "opaque" "axiom" "instance"
    "structure" "class" "inductive" "coinductive" "example"
    "initialize" "builtin_initialize")
  "Keywords introducing declarations.")

(defconst leaner-ts--command-keywords
  (append leaner-ts--declaration-keywords
          '("namespace" "section" "end" "mutual" "variable" "universe"
            "open" "export" "import" "import all" "prelude" "set_option"
            "syntax" "macro" "macro_rules" "elab" "elab_rules" "notation"
            "infix" "infixl" "infixr" "prefix" "postfix"))
  "Keywords introducing command boundaries.")

(defvar-local leaner-ts--cache nil
  "Cached modification tick, commands, and definition-name positions.")

(defun leaner-ts--line-leading-p (node)
  "Return non-nil if NODE follows only declaration prefixes on its line."
  (save-excursion
    (goto-char (treesit-node-start node))
    (string-match-p
     (concat "\\`[ \t]*\\(?:@\\[[^]\n]*\\][ \t]*\\|"
             "\\(?:private\\|public\\|protected\\|noncomputable\\|partial"
             "\\|unsafe\\|nonrec\\|local\\|scoped\\|meta\\)\\_>[ \t]+\\)*\\'")
     (buffer-substring-no-properties (line-beginning-position) (point)))))

(defun leaner-ts--header-start (node)
  "Return the start of NODE's attached documentation and prefixes."
  (let ((start (save-excursion
                 (goto-char (treesit-node-start node))
                 (line-beginning-position)))
        (previous (treesit-node-prev-sibling node t)))
    (while (and previous
                (member (treesit-node-type previous)
                        '("doc_comment" "attribute" "modifier"))
                (string-match-p "\\`[ \t\n]*\\'"
                                (buffer-substring-no-properties
                                 (treesit-node-end previous)
                                 (treesit-node-start node))))
      (setq start (save-excursion
                    (goto-char (treesit-node-start previous))
                    (line-beginning-position))
            node previous
            previous (treesit-node-prev-sibling node t)))
    start))

(defun leaner-ts--commands ()
  "Return lexical command boundaries, rebuilding after a buffer edit."
  (if (eq (car leaner-ts--cache) (buffer-chars-modified-tick))
      (cadr leaner-ts--cache)
    (save-excursion
      (let ((root (treesit-buffer-root-node 'leanflat))
            (names (make-hash-table :test #'eql))
            commands scopes)
        (dotimes (index (treesit-node-child-count root t))
          (let* ((node (treesit-node-child root index t))
                 (kind (treesit-node-text node t)))
            (when (and (equal (treesit-node-type node) "keyword")
                       (or (member kind leaner-ts--command-keywords)
                           (string-prefix-p "#" kind))
                       (leaner-ts--line-leading-p node))
              (goto-char (treesit-node-start node))
              (back-to-indentation)
              (let* ((next (treesit-node-next-sibling node t))
                     (name (and next
                                (equal (treesit-node-type next) "identifier")
                                (not (member kind '("example" "end")))
                                (treesit-node-text next t)))
                     (qualified (and name
                                     (mapconcat #'identity
                                                (append (reverse (delq nil (copy-sequence scopes)))
                                                        (list name)) ".")))
                     (entry (list :kind kind :name qualified
                                  :name-start (and name (treesit-node-start next))
                                  :position (treesit-node-start node)
                                  :head (line-beginning-position)
                                  :start (leaner-ts--header-start node)
                                  :indent (current-indentation)
                                  :level (+ 1 (length scopes)
                                            (/ (current-indentation)
                                               (max 1 leaner-ts-indent-offset))))))
                (when (and name (member kind leaner-ts--declaration-keywords))
                  (puthash (treesit-node-start next)
                           (if (member kind '("structure" "class" "inductive" "coinductive"))
                               'font-lock-type-face
                             'font-lock-function-name-face)
                           names))
                (push entry commands)
                (cond
                 ((equal kind "namespace") (push name scopes))
                 ((member kind '("section" "mutual")) (push nil scopes))
                 ((equal kind "end") (pop scopes)))))))
        (setq commands (nreverse commands))
        (cl-loop for tail on commands
                 for entry = (car tail)
                 do (plist-put
                     entry :end
                     (save-excursion
                       (goto-char
                        (or (cl-loop for next in (cdr tail)
                                     when (<= (plist-get next :indent)
                                              (plist-get entry :indent))
                                     return (plist-get next :start))
                            (point-max)))
                       (skip-chars-backward " \t\n")
                       (point))))
        (setq leaner-ts--cache (list (buffer-chars-modified-tick) commands names))
        commands))))

(defun leaner-ts--defuns ()
  "Return the declarations in the current buffer."
  (cl-remove-if-not
   (lambda (entry) (member (plist-get entry :kind) leaner-ts--declaration-keywords))
   (leaner-ts--commands)))

(defun leaner-ts--fontify-definition (node override start end &rest _)
  "Fontify definition NODE within START and END, respecting OVERRIDE."
  (leaner-ts--commands)
  (when-let* ((face (gethash (treesit-node-start node) (nth 2 leaner-ts--cache))))
    (treesit-fontify-with-override
     (treesit-node-start node) (treesit-node-end node) face override start end)))

(defun leaner-ts--font-lock-settings ()
  "Return fontification rules for the flat Lean grammar."
  (treesit-font-lock-rules
   :language 'leanflat :feature 'comment
   '([(line_comment) (block_comment)] @font-lock-comment-face)
   :language 'leanflat :feature 'doc
   '([(doc_comment) (mod_doc_comment)] @font-lock-doc-face)
   :language 'leanflat :feature 'string
   '([(string) (char)] @font-lock-string-face)
   :language 'leanflat :feature 'keyword
   '([(keyword) (modifier)] @font-lock-keyword-face)
   :language 'leanflat :feature 'type
   '((storage_type) @font-lock-type-face)
   :language 'leanflat :feature 'number
   '((number) @font-lock-number-face)
   :language 'leanflat :feature 'attribute
   '((attribute) @font-lock-preprocessor-face)
   :language 'leanflat :feature 'error
   '([(invalid) (ERROR)] @font-lock-warning-face)
   :language 'leanflat :feature 'definition
   '((identifier) @leaner-ts--fontify-definition)))

(defun leaner-ts--syntax-propertize (start end)
  "Mark character literals between START and END as strings."
  (dolist (capture (treesit-query-capture
                    (treesit-buffer-root-node 'leanflat) '((char) @char) start end))
    (let ((beg (treesit-node-start (cdr capture)))
          (finish (treesit-node-end (cdr capture))))
      (put-text-property beg (1+ beg) 'syntax-table (string-to-syntax "|"))
      (put-text-property (1- finish) finish 'syntax-table (string-to-syntax "|"))
      (when (= (char-after (1+ beg)) ?\")
        (put-text-property (1+ beg) (+ beg 2) 'syntax-table (string-to-syntax "."))))))

(defun leaner-ts--line-code ()
  "Return the current line with comments masked and literals neutralized."
  (let* ((beg (line-beginning-position))
         (end (line-end-position))
         (code (buffer-substring-no-properties beg end))
         (node (treesit-node-at beg 'leanflat)))
    (while (and (treesit-node-parent node)
                (not (equal (treesit-node-type (treesit-node-parent node)) "source_file")))
      (setq node (treesit-node-parent node)))
    (while (and node (< (treesit-node-start node) end))
      (let ((type (treesit-node-type node)))
        (when (member type '("line_comment" "block_comment" "doc_comment"
                             "mod_doc_comment" "string" "char"))
          (cl-loop for index from (- (max beg (treesit-node-start node)) beg)
                   below (- (min end (treesit-node-end node)) beg)
                   do (aset code index (if (member type '("string" "char")) ?x ?\s)))))
      (setq node (treesit-node-next-sibling node t)))
    (string-trim-right code)))

(defun leaner-ts--indent-column ()
  "Return a lexical indentation column for the current line."
  (save-excursion
    (back-to-indentation)
    (let* ((bol (point))
           (existing (current-indentation))
           (state (syntax-ppss))
           (current (string-trim-left (leaner-ts--line-code)))
           (offset leaner-ts-indent-offset))
      (cond
       ((or (nth 3 state) (nth 4 state)) existing)
       ((and (nth 1 state) (looking-at "[])}⟩⦄]"))
        (goto-char (nth 1 state)) (current-indentation))
       ((and (> existing 0) (= (% existing (max 1 offset)) 0)) existing)
       ((let* ((node (treesit-node-at bol 'leanflat))
               (kind (treesit-node-type node))
               (text (treesit-node-text node t)))
          (or (member kind '("modifier" "attribute"))
              (and (equal kind "keyword")
                   (or (member text leaner-ts--command-keywords)
                       (string-prefix-p "#" text))))) 0)
       ((string-prefix-p "@[" current) 0)
       ((nth 1 state)
        (goto-char (nth 1 state)) (+ (current-indentation) offset))
       ((= (line-beginning-position) (point-min)) 0)
       (t
        (forward-line -1)
        (let* ((previous (leaner-ts--line-code))
               (base (current-indentation))
               (focused (string-match-p "\\`[ \t]*·" previous)))
          (cond
           ((string-empty-p (string-trim previous)) existing)
           ((string-match-p "\\`[·|]" current)
            (let ((bullet (substring current 0 1)) found)
              (while (and (not found) (>= (current-indentation) offset))
                (when (string-prefix-p bullet (string-trim-left (leaner-ts--line-code)))
                  (setq found (current-indentation)))
                (unless found
                  (if (= (forward-line -1) 0) nil (setq found 0))))
              (or found base)))
           ((string-match-p ":[ \t]*\\'" previous) (* 2 offset))
           ((string-match-p "\\(?:\\`[ \t]*\\|·[ \t]*\\)sorry[ \t]*\\'" previous)
            (max 0 (- (+ base (if focused offset 0)) offset)))
           ((string-match-p ":=[ \t]*\\'" previous)
            (let ((owner (cl-find-if
                          (lambda (entry)
                            (and (<= (plist-get entry :start) (point))
                                 (< (point) (plist-get entry :end))))
                          (reverse (leaner-ts--defuns)))))
              (if (and owner
                       (equal (save-excursion
                                (goto-char (plist-get owner :position))
                                (search-forward ":=" bol t))
                              (+ (line-beginning-position)
                                 (or (string-match ":=[ \t]*\\'" previous) 0) 2)))
                  (+ (plist-get owner :indent) offset)
                (+ base offset))))
           ((string-match-p
             "\\(?:\\_<\\(?:by\\|do\\|try\\|finally\\|then\\|else\\|where\\|from\\|extends\\|deriving\\)\\_>\\|=>\\| =\\|[{[(⟨⦃]\\)[ \t]*\\'"
             previous)
            (+ base offset (if focused offset 0)))
           (focused (+ base offset))
           (t base))))))))

(defun leaner-ts--indent-rule (_node _parent _bol)
  "Return a tree-sitter indent rule using lexical Lean layout."
  (cons (point-min) (leaner-ts--indent-column)))

(defun leaner-ts-beginning-of-defun (&optional arg)
  "Move to the beginning of the ARGth Lean declaration.
With negative ARG, move forward instead."
  (let ((count (or arg 1)) found)
    (dotimes (_ (abs count))
      (setq found
            (if (< count 0)
                (cl-find-if (lambda (entry) (> (plist-get entry :start) (point)))
                            (leaner-ts--defuns))
              (cl-find-if (lambda (entry) (< (plist-get entry :start) (point)))
                          (reverse (leaner-ts--defuns)))))
      (when found (goto-char (plist-get found :start))))
    (and found t)))

(defun leaner-ts-end-of-defun ()
  "Move to the end of the current or next Lean declaration."
  (when-let* ((entry (cl-find-if (lambda (item) (> (plist-get item :end) (point)))
                                 (leaner-ts--defuns))))
    (goto-char (plist-get entry :end))
    t))

(defun leaner-ts--current-defun ()
  "Return the qualified name of the enclosing Lean declaration."
  (plist-get (cl-find-if (lambda (entry)
                           (and (<= (plist-get entry :start) (point))
                                (<= (point) (plist-get entry :end))))
                         (reverse (leaner-ts--defuns))) :name))

(defun leaner-ts--imenu ()
  "Return an Imenu index with qualified declaration names."
  (cl-loop for entry in (leaner-ts--defuns)
           when (plist-get entry :name)
           collect (cons (plist-get entry :name) (plist-get entry :start))))

(defun leaner-ts--outline-search (&optional bound move backward looking-at)
  "Search for a lexical heading using BOUND, MOVE, BACKWARD and LOOKING-AT."
  (let* ((origin (point))
         (entries (cl-remove-if-not
                   (lambda (entry)
                     (or (member (plist-get entry :kind) leaner-ts--declaration-keywords)
                         (member (plist-get entry :kind) '("namespace" "section" "mutual"))))
                   (leaner-ts--commands)))
         (entry (cl-find-if
                 (lambda (item)
                   (let ((pos (plist-get item :head)))
                     (cond
                      (looking-at (= pos origin))
                      (backward (and (< pos origin) (>= pos (or bound (point-min)))))
                      (t (and (>= pos origin) (< pos (or bound (point-max))))))))
                 (if backward (reverse entries) entries))))
    (if entry
        (let ((pos (plist-get entry :head)))
          (unless looking-at (goto-char pos) (end-of-line))
          (set-match-data (list pos (save-excursion (goto-char pos) (line-end-position))))
          t)
      (when move (goto-char (or bound (if backward (point-min) (point-max)))))
      nil)))

(defun leaner-ts--outline-level ()
  "Return the nesting level of the current Lean heading."
  (or (plist-get (cl-find (line-beginning-position) (leaner-ts--commands)
                          :key (lambda (entry) (plist-get entry :head))) :level) 1))

(cl-defmethod project-root ((project (head leaner-ts)))
  "Return the root of the Lean PROJECT."
  (cdr project))

(defun leaner-ts--project-find (directory)
  "Find the nearest Lake project containing DIRECTORY."
  (when-let* ((root (or (locate-dominating-file
                         directory (lambda (dir)
                                     (or (file-exists-p (expand-file-name "lakefile.toml" dir))
                                         (file-exists-p (expand-file-name "lakefile.lean" dir)))))
                        (locate-dominating-file directory "lean-toolchain"))))
    (cons 'leaner-ts (expand-file-name root))))

;;;###autoload
(defun leaner-ts-install-grammar (&optional directory)
  "Install the pinned tree-sitter-lean-flat grammar into DIRECTORY.
DIRECTORY defaults to the tree-sitter directory under `user-emacs-directory'.
Git and a C compiler must be available on the variable `exec-path'."
  (interactive)
  (let* ((work (make-temp-file "leaner-ts-grammar-" t))
         (output (expand-file-name "output" work))
         (destination (or directory (locate-user-emacs-file "tree-sitter"))))
    (unwind-protect
        (with-temp-buffer
          (dolist (args `(("init" "--quiet" ,work)
                          ("-C" ,work "fetch" "--quiet" "--depth" "1"
                           "https://github.com/lua-vr/tree-sitter-lean-flat"
                           ,leaner-ts--grammar-revision)
                          ("-C" ,work "checkout" "--quiet" "--detach" "FETCH_HEAD")))
            (unless (eq 0 (apply #'process-file "git" nil t t args))
              (error "Could not fetch Lean grammar: %s" (buffer-string))))
          (let ((treesit-language-source-alist `((leanflat ,work)))
                (treesit-extra-load-path (cons output treesit-extra-load-path)))
            (treesit-install-language-grammar 'leanflat output))
          (let ((libraries (and (file-directory-p output)
                                (directory-files output t "\\`libtree-sitter-leanflat\\."))))
            (unless libraries (error "Lean grammar compilation failed; check *Warnings*"))
            (make-directory destination t)
            (dolist (library libraries)
              (copy-file library (expand-file-name (file-name-nondirectory library) destination) t)))
          (message "Installed tree-sitter-lean-flat %s" leaner-ts--grammar-revision))
      (delete-directory work t))))

;;;###autoload
(define-derived-mode leaner-ts-mode prog-mode "Lean"
  "Edit Lean 4 with the flat tree-sitter grammar.
Use `leaner-ts-install-grammar' to install the grammar.
Indentation follows lexical layout and preserves explicit proof indentation."
  :syntax-table leaner-ts-mode-syntax-table
  (setq-local comment-start "-- "
              comment-end ""
              comment-start-skip "\\(?:--+\\|/-+\\)[ \t]*"
              indent-tabs-mode nil
              leaner-ts--cache nil)
  (add-hook 'project-find-functions #'leaner-ts--project-find nil t)
  (let ((root (leaner-ts--project-find default-directory)))
    (setq-local compile-command
                (if root (concat "lake -d " (shell-quote-argument (project-root root)) " build")
                  "lake build")))
  (unless (treesit-ready-p 'leanflat)
    (user-error "Install the Lean grammar with M-x leaner-ts-install-grammar"))
  (treesit-parser-create 'leanflat)
  (unless (condition-case nil
              (progn (treesit-query-compile 'leanflat '((keyword) @keyword) t) t)
            (treesit-query-error nil))
    (user-error "Expected tree-sitter-lean-flat; reinstall with M-x leaner-ts-install-grammar and restart Emacs"))
  (setq-local treesit-font-lock-settings (leaner-ts--font-lock-settings)
              treesit-font-lock-feature-list
              '((comment doc string) (keyword type error definition) (number attribute))
              treesit-indent-function #'leaner-ts--indent-rule
              syntax-propertize-function #'leaner-ts--syntax-propertize)
  (treesit-major-mode-setup)
  (setq-local indent-region-function nil
              beginning-of-defun-function #'leaner-ts-beginning-of-defun
              end-of-defun-function #'leaner-ts-end-of-defun
              add-log-current-defun-function #'leaner-ts--current-defun
              imenu-create-index-function #'leaner-ts--imenu
              outline-search-function #'leaner-ts--outline-search
              outline-level #'leaner-ts--outline-level))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.lean\\'" . leaner-ts-mode))

(provide 'leaner-ts-mode)

;;; leaner-ts-mode.el ends here
