;;; flymake-oxlint.el --- A Flymake backend for Javascript using oxlint  -*- lexical-binding: t; -*-

;; Package-Version: 20240925.1224
;; Package-Revision: 66a4f7d619ec
;; Author: Dan Orzechowski
;; Contributor: Terje Larsen
;; URL: https://github.com/orzechowskid/flymake-oxlint
;; Package-Requires: ((emacs "26.1"))
;; Keywords: languages, tools

;;; Commentary:

;; A backend for Flymake which uses oxlint.  Enable it with M-x
;; flymake-oxlint-enable RET.  Alternately, configure a mode-hook for your
;; Javascript major mode of choice:

;; (add-hook 'some-js-major-mode-hook #'flymake-oxlint-enable)

;; A handful of configurable options can be found in the flymake-oxlint
;; customization group: view and modify them with the M-x customize-group RET
;; flymake-oxlint RET.

;; License: MIT

;;; Code:

;;;; Requirements

(require 'cl-lib)
(when (featurep 'project)
  (require 'project))
(when (featurep 'json)
  (require 'json))

;;;; Customization

(defgroup flymake-oxlint nil
  "Flymake checker for Javascript using oxlint."
  :group 'programming
  :prefix "flymake-oxlint-")

(defcustom flymake-oxlint-executable-name "oxlint"
  "Name of executable to run when checker is called.
Must be present in variable `exec-path'."
  :type 'string
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-executable-args nil
  "Extra arguments to pass to oxlint."
  :type '(choice string (repeat string))
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-show-rule-name t
  "When non-nil show oxlint rule name in flymake diagnostic."
  :type 'boolean
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-defer-binary-check nil
  "Defer the oxlint binary presence check.
When non-nil, the initial check, which ensures that oxlint binary
is present, is disabled.  Instead, this check is performed during
backend execution.

Useful when the value of variable `exec-path' is set dynamically
and the location of oxlint might not be known ahead of time."
  :type 'boolean
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-project-root nil
  "Buffer-local.
Set to a filesystem path to use that path as the current working
directory of the linting process."
  :type 'string
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-prefer-json-diagnostics nil
  "Try to use the JSON diagnostic format when running oxlint.
This gives more accurate diagnostics but requires having an Emacs
installation with JSON support."
  :type 'boolean
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-project-markers
  '("oxlint.config.js" "oxlint.config.mjs" "oxlint.config.cjs" "package.json")
  "List of files indicating the root of a JavaScript project.

flymake-oxlint starts Oxlint at the root of your JavaScript
project. This root is defined as the first directory containing a file
of this list, starting from the value of `default-directory' in the
current buffer.

Adding a \".oxlintrc.js\" entry (or another supported extension) to this
list only makes sense if there is at most one such file per project."
  :type '(repeat string)
  :group 'flymake-oxlint)

;;;; Variables

(defvar flymake-oxlint--message-regexp
  (rx bol (* space) (group (+ num)) ":" (group (+ num)) ; line:col
      (+ space) (group (or "error" "warning"))          ; type
      (+ space) (group (+? anychar))                    ; message
      (>= 2 space) (group (* not-newline)) eol)        ; rule name
  "Regexp to match oxlint messages.")

(defvar-local flymake-oxlint--process nil
  "Handle to the linter process for the current buffer.")

;;;; Functions

;;;;; Public

;;;###autoload
(defun flymake-oxlint-enable ()
  "Enable Flymake and flymake-oxlint.
Add this function to some js major mode hook."
  (interactive)
  (unless flymake-oxlint-defer-binary-check
    (flymake-oxlint--ensure-binary-exists))
  (make-local-variable 'flymake-oxlint-project-root)
  (flymake-mode t)
  (add-hook 'flymake-diagnostic-functions 'flymake-oxlint--checker nil t))

;;;;; Private

(defun flymake-oxlint--executable-args ()
  "Get additional arguments for `flymake-oxlint-executable-name'.
Return `flymake-oxlint-executable-args' value and ensure that
this is a list."
  (if (listp flymake-oxlint-executable-args)
      flymake-oxlint-executable-args
    (list flymake-oxlint-executable-args)))

(defun flymake-oxlint--ensure-binary-exists ()
  "Ensure that `flymake-oxlint-executable-name' exists.
Otherwise, throw an error and tell Flymake to disable this
backend if `flymake-oxlint-executable-name' can't be found in
variable `exec-path'"
  (unless (executable-find flymake-oxlint-executable-name)
    (let ((option 'flymake-oxlint-executable-name))
      (error "Can't find \"%s\" in exec-path - try to configure `%s'"
             (symbol-value option) option))))

(defun flymake-oxlint--get-position (line column buffer)
  "Get the position at LINE and COLUMN for BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (when (and line column)
        (goto-char (point-min))
        (forward-line (1- line))
        (forward-char (1- column))
        (point)))))


(defun flymake-oxlint--diag-for-single-rule (diag span buffer)
  "Transform single rule diagnostic for BUFFER into a Flymake one."
  (let* ((beg-line (gethash "line" span))
         (beg-col (gethash "column" span))
         (beg-pos (flymake-oxlint--get-position beg-line beg-col buffer))
         (end-pos (cdr (flymake-diag-region buffer beg-line)))
         (lint-rule (gethash "code" diag))
         (severity (gethash "severity" diag))
         (type (if (string= severity "error") :error :warning))
         (msg (gethash "message" diag))
         (full-msg (concat
                    msg
                    (when (and flymake-oxlint-show-rule-name lint-rule)
                      (format " [%s]" lint-rule)))))
    (flymake-make-diagnostic
     buffer
     beg-pos
     end-pos
     type
     full-msg
     (list :rule-name lint-rule))))

(defun flymake-oxlint--diag-from-oxlint (oxlint-diag buffer)
  "Transform OXLINT-DIAG diagnostic for BUFFER into a Flymake one."
  (seq-map
   (lambda (label)
     (flymake-oxlint--diag-for-single-rule oxlint-diag (gethash "span" label) buffer))
   (gethash "labels" oxlint-diag)))

(defun flymake-oxlint--report-json (oxlint-stdout-buffer source-buffer)
  "Create Flymake diagnostics from the JSON diagnostic in OXLINT-STDOUT-BUFFER.
The diagnostics are reported against SOURCE-BUFFER."
  (if (featurep 'json)
      (with-current-buffer oxlint-stdout-buffer
        (goto-char (point-min))
        (let* ((result (flymake-oxlint--json-parse-buffer))
               (oxlint-diags (gethash "diagnostics" result)))
          (seq-mapcat
           (lambda (diag)
             (flymake-oxlint--diag-from-oxlint diag source-buffer))
           oxlint-diags)))
    (error
     "Tried to parse JSON diagnostics but current Emacs does not support it.")))

(defun flymake-oxlint--json-parse-buffer ()
  "Return oxlint diagnostics in the current buffer.

The current buffer is expected to contain a JSON output of
diagnostics messages written by oxlint.

The return value is a list containing a single element: a hash
table of oxlint execution results.

When oxlint crashes, the current buffer may contain non-JSON
output. In this case, the function returns the same kind of data
but the only contained error consists of information about the
crash."
  (condition-case nil
      (json-parse-buffer :object-type 'hash-table :array-type 'list)
    (json-parse-error (flymake-oxlint--generate-fake-diagnostics-from-non-json-output))))

(defun flymake-oxlint--generate-fake-diagnostics-from-non-json-output ()
  "Return a diagnostic list containing the reason for oxlint's crash."
  (let ((oxlint-message (make-hash-table :test 'equal)))
    (puthash "line" 1 oxlint-message)
    (puthash "column" 1 oxlint-message)
    (puthash "ruleId" "oxlint" oxlint-message)
    (puthash "severity" 2 oxlint-message)
    (puthash "message"
             (buffer-substring-no-properties (point-min) (point-max))
             oxlint-message)
    (let ((oxlint-messages (list oxlint-message))
          (result (make-hash-table :test 'equal)))
      (puthash "messages" oxlint-messages result)
      (list result))))

(defun flymake-oxlint--use-json-p ()
  "Check if oxlint diagnostics should be requested to be formatted as JSON."
  (and (featurep 'json) flymake-oxlint-prefer-json-diagnostics))

(defun flymake-oxlint--report (oxlint-stdout-buffer source-buffer)
  "Create Flymake diag messages from contents of OXLINT-STDOUT-BUFFER.
They are reported against SOURCE-BUFFER.  Return a list of
results."
  (with-current-buffer oxlint-stdout-buffer
    ;; start at the top and check each line for an oxlint message
    (goto-char (point-min))
    (if (looking-at-p "Error:")
        (pcase-let ((`(,beg . ,end) (with-current-buffer source-buffer
                                      (cons (point-min) (point-max))))
                    (msg (thing-at-point 'line t)))
          (list (flymake-make-diagnostic source-buffer beg end :error msg)))
      (cl-loop
       until (eobp)
       when (looking-at flymake-oxlint--message-regexp)
       collect (let* ((row (string-to-number (match-string 1)))
                      (column (string-to-number (match-string 2)))
                      (type (match-string 3))
                      (msg (match-string 4))
                      (lint-rule (match-string 5))
                      (msg-text (concat (format "%s: %s" type msg)
                                        (when flymake-oxlint-show-rule-name
                                          (format " [%s]" lint-rule))))
                      (type-symbol (pcase type ("warning" :warning) (_ :error)))
                      (src-pos (flymake-diag-region source-buffer row column)))
                 ;; new Flymake diag message
                 (flymake-make-diagnostic
                  source-buffer
                  (car src-pos)
                  ;; buffer might have changed size
                  (min (buffer-size source-buffer) (cdr src-pos))
                  type-symbol
                  msg-text
                  (list :rule-name lint-rule)))
       do (forward-line 1)))))

;; Heavily based on the example found at
;; https://www.gnu.org/software/emacs/manual/html_node/flymake/An-annotated-example-backend.html
(defun flymake-oxlint--create-process (source-buffer callback)
  "Create linter process for SOURCE-BUFFER.
CALLBACK is invoked once linter has finished the execution.
CALLBACK accepts a buffer containing stdout from linter as its
argument."
  (when (process-live-p flymake-oxlint--process)
    (kill-process flymake-oxlint--process))
  (let ((default-directory
         (or
          flymake-oxlint-project-root
          (flymake-oxlint--directory-containing-project-marker)
          (when (and (featurep 'project)
                     (project-current))
            (project-root (project-current)))
          default-directory))
        (format-args
         (if (flymake-oxlint--use-json-p)
             '("--format" "json")
           "")))
    (setq flymake-oxlint--process
          (make-process
           :name "flymake-oxlint"
           :connection-type 'pipe
           :noquery t
           :buffer (generate-new-buffer " *flymake-oxlint*")
           :command `(,flymake-oxlint-executable-name
                      ;; "--no-color"
                      "--no-ignore"
                      ,@format-args
                      ;; "--stdin"
                      ;; "--stdin-filename"
                      ,(or (buffer-file-name source-buffer) (buffer-name source-buffer))
                      ,@(flymake-oxlint--executable-args))
           :sentinel
           (lambda (proc &rest ignored)
             (let ((status (process-status proc))
                   (buffer (process-buffer proc)))
               (when (and (eq 'exit status)
                          ;; make sure we're not using a deleted buffer
                          (buffer-live-p source-buffer)
                          ;; make sure we're using the latest lint process
                          (eq proc (buffer-local-value 'flymake-oxlint--process
                                                       source-buffer)))
                 ;; read from oxlint output
                 (funcall callback buffer))
               ;; destroy temp buffer when done or killed
               (when (memq status '(exit signal))
                 (kill-buffer buffer))))))))

(defun flymake-oxlint--directory-containing-project-marker ()
  "Return the directory containing a project marker.

Return the first directory containing a file of `flymake-oxlint-project-markers',
starting from the value of `default-directory' in the current buffer."
  (locate-dominating-file
   default-directory
   (lambda (directory)
     (seq-find
      (lambda (project-marker)
        (file-exists-p (expand-file-name project-marker directory)))
      flymake-oxlint-project-markers))))

(defun flymake-oxlint--check-and-report (source-buffer report-fn)
  "Run oxlint against SOURCE-BUFFER.
Use REPORT-FN to report results."
  (when flymake-oxlint-defer-binary-check
    (flymake-oxlint--ensure-binary-exists))
  (let ((diag-builder-fn
         (if (flymake-oxlint--use-json-p)
             'flymake-oxlint--report-json
           'flymake-oxlint--report)))
    (let ((content (buffer-string)))
      (if (string-empty-p content)
          (funcall report-fn (list))
        (flymake-oxlint--create-process
         source-buffer
         (lambda (oxlint-stdout)
           (funcall
            report-fn
            (funcall diag-builder-fn oxlint-stdout source-buffer))))
        (with-current-buffer source-buffer
          (process-send-string flymake-oxlint--process (buffer-string))
          (process-send-eof flymake-oxlint--process))))))

(defun flymake-oxlint--checker (report-fn &rest _ignored)
  "Run oxlint on the current buffer.
Report results using REPORT-FN.  All other parameters are
currently ignored."
  (flymake-oxlint--check-and-report (current-buffer) report-fn))

;;;; Footer

(provide 'flymake-oxlint)

;;; flymake-oxlint.el ends here
