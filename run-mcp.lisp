;;;; MCP-as-tool-source demo: connect an MCP server (stdio), list its tools, wrap them as ailisp
;;;; tools, and use them. The offline self-check spawns the in-repo example server (no model, no
;;;; network -- a real JSON-RPC subprocess round-trip); the live section drives a react loop over
;;;; the MCP tools and needs hiai-core.
;;;;   sbcl --script run-mcp.lisp
(setf sb-impl::*default-external-format* :utf-8)
(defvar cl-user::*mcp-root* (or *load-pathname* *default-pathname-defaults*))
(let ((root cl-user::*mcp-root*))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/mcp"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

(defparameter *server*
  (namestring (merge-pathnames "examples/mcp-add-server.lisp" cl-user::*mcp-root*)))
(defun connect () (mcp-connect "sbcl" "--script" *server*))

;;; ---- deterministic self-check: a real stdio JSON-RPC round-trip, no model ----
(format t "~&[MCP self-check -- real subprocess, no model]~%")
(let ((c (connect)))
  (flet ((chk (label got want)
           (format t "  ~A ~A => ~S~%" (if (equal got want) "ok  " "FAIL") label got)))
    (chk "tools/list" (mapcar (lambda (ts) (%mget ts "name")) (mcp-list-tools c)) '("add" "multiply"))
    (chk "tools/call add(40,2)" (mcp-call c "add" '(("a" . 40) ("b" . 2))) "42")
    (chk "tools/call multiply(6,7)" (mcp-call c "multiply" '(("a" . 6) ("b" . 7))) "42")
    (let* ((tools (mcp-tools c))
           (add (find 'add tools :key #'tool-name)))
      (chk "wrapped ailisp tool names" (mapcar #'tool-name tools) '(add multiply))
      ;; positional ailisp call (add 3 4) -> named MCP args {a:3,b:4}; result is text "7".
      (chk "wrapped (add 3 4)" (funcall (tool-fn add) 3 4) "7"))
    (mcp-close c)))

;;; ---- live: a model drives the MCP tools through a react loop ----
(setf *model* (make-openai-model))
(format t "~%[live react over MCP tools]~%")
(let ((c (connect)))
  (let ((tools (mcp-tools c)))
    (multiple-value-bind (ans n)
        (react "用 add 工具计算 40 加 2 等于多少?只回答数字。" tools :max-steps 4)
      (format t "  ANSWER: ~S   (MCP tool called ~A time~:p; expect 42)~%" ans n)))
  (mcp-close c))
