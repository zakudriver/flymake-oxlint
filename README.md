# flymake-oxlint
Flymake backend for Javascript using oxlint


## Installation

0. Make sure `oxlint` is installed and present on your emacs `exec-path`.  For Linux systems `exec-path` usually equals your `$PATH` environment variable; for other systems, you're on your own.
1. Install:
  - manually: download and place inside `~/.emacs.d/lisp` then edit `~/.emacs` or equivalent:
  ```lisp
  (add-to-list 'load-path "~/.emacs.d/lisp")
  (require "flymake-oxlint.el")
  ```
  - with `use-package` + `straight.el`:
  ```lisp
  (use-package flymake-oxlint
    :straight '(flymake-oxlint :type git :host github :repo "orzechowskid/flymake-oxlint"))
  ```
2. Enable:
```lisp
(add-hook 'web-mode-hook ; or whatever the mode-hook is for your mode of choice
  (lambda ()
    (flymake-oxlint-enable)))
```
## Customization

useful variables are members of the `flymake-oxlint` group and can be viewed and modified with the command `M-x customize-group [RET] flymake-oxlint [RET]`.

```lisp
(defcustom flymake-oxlint-executable-name "oxlint"
  "Name of executable to run when checker is called.  Must be present in variable `exec-path'."
  :type 'string
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-executable-args nil
  "Extra arguments to pass to oxlint."
  :type 'string
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-show-rule-name t
  "Set to t to append rule name to end of warning or error message, nil otherwise."
  :type 'boolean
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-defer-binary-check nil
  "Set to t to bypass the initial check which ensures oxlint is present.

Useful when the value of variable `exec-path' is set dynamically and the location of oxlint might not be known ahead of time."
  :type 'boolean
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-project-root nil
  "Buffer-local.  Set to a filesystem path to use that path as the current working directory of the linting process."
  :type 'string
  :group 'flymake-oxlint)

(defcustom flymake-oxlint-prefer-json-diagnostics nil
  "Try to use the JSON diagnostic format when runnin Oxlint.
This gives more accurate diagnostics but requires having an Emacs
version with JSON support."
  :type 'boolean
  :group 'flymake-oxlint)
```

## Bugs

yes

## See Also

[flymake-stylelint](https://github.com/orzechowskid/flymake-stylelint)

## License

MIT
