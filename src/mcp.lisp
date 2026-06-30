;;;; ailisp MCP client -- MCP as a TOOL SOURCE (api-todo #9). MCP isn't a tool; it's a standard
;;;; protocol for SOURCING tools from external servers. So this is an ADAPTER: connect to an MCP
;;;; server, list its tools, and wrap each as an ailisp `tool` whose fn calls the server -- then
;;;; react / build / plan-execute use them like any other tool (tool-use = eval, unchanged).
;;;; Transport: stdio (subprocess, newline-delimited JSON-RPC 2.0) -- the common local transport,
;;;; and one we can drive with run-program (like sqlite/wolfram) and test without a network.
;;;;   (let ((c (mcp-connect "sbcl" "--script" "examples/mcp-add-server.lisp")))
;;;;     (react "add 40 and 2" (mcp-tools c)) (mcp-close c))
(in-package :ailisp)

(defstruct mcp proc in out (id 0))

;;; ---- JSON-RPC 2.0 over newline-delimited stdio ----

(defun %rpc-request (method params id)
  (list (cons "jsonrpc" "2.0") (cons "id" id) (cons "method" method) (cons "params" params)))

(defun %rpc-notify (method &optional (params :emptyobj))
  (list (cons "jsonrpc" "2.0") (cons "method" method) (cons "params" params)))

(defun %mcp-send (conn obj)
  (let ((in (mcp-in conn)))
    (write-string (json-encode obj) in)
    (write-char #\Newline in)
    (force-output in)))

(defun %mcp-read (conn)
  "Read one newline-delimited JSON message from the server, decoded (or NIL at EOF)."
  (let ((line (read-line (mcp-out conn) nil nil)))
    (and line (ignore-errors (json-decode line)))))

(defun %mcp-request (conn method params)
  "Send a JSON-RPC request and read its response (synchronous request/response)."
  (%mcp-send conn (%rpc-request method params (incf (mcp-id conn))))
  (%mcp-read conn))

;;; ---- lifecycle ----

(defun mcp-connect (command &rest args)
  "Start an MCP server subprocess (stdio transport) and run the initialize handshake. COMMAND +
   ARGS go to run-program (e.g. \"node\" \"server.js\", or \"sbcl\" \"--script\" \"srv.lisp\").
   Returns an MCP connection; close it with MCP-CLOSE."
  (let* ((proc (sb-ext:run-program command args :search t :wait nil
                                                :input :stream :output :stream :error nil
                                                :external-format :utf-8))
         (conn (make-mcp :proc proc
                         :in (sb-ext:process-input proc)
                         :out (sb-ext:process-output proc))))
    (%mcp-request conn "initialize"
                  (list (cons "protocolVersion" "2024-11-05")
                        (cons "capabilities" :emptyobj)
                        (cons "clientInfo" (list (cons "name" "ailisp") (cons "version" "0.1")))))
    (%mcp-send conn (%rpc-notify "notifications/initialized"))  ; notification: no response
    conn))

(defun mcp-close (conn)
  "Close stdin (signals EOF -> the server exits), then reap the subprocess."
  (ignore-errors (close (mcp-in conn)))
  (ignore-errors (sb-ext:process-wait (mcp-proc conn)))
  (ignore-errors (sb-ext:process-close (mcp-proc conn)))
  t)

;;; ---- tools/list + tools/call, mapped to ailisp tools ----

(defun mcp-list-tools (conn)
  "Return the server's tool specs (a list of %map: name / description / inputSchema)."
  (%mget (%mget (%mcp-request conn "tools/list" :emptyobj) "result") "tools"))

(defun %mcp-param-names (tool-spec)
  "Ordered parameter names from a tool's inputSchema.properties (object key order is preserved
   by json-decode). Used to zip a positional ailisp call onto MCP's named arguments."
  (let* ((schema (%mget tool-spec "inputSchema"))
         (props (and schema (%mget schema "properties"))))
    (when (and (consp props) (sym= (car props) "%MAP"))
      (loop for (k v) on (cdr props) by #'cddr collect k))))

(defun %mcp-args (param-names positional)
  "Zip POSITIONAL call args to PARAM-NAMES -> a JSON-object alist for tools/call."
  (loop for p in param-names for a in positional collect (cons p a)))

(defun %mcp-result-value (result)
  "Flatten an MCP tool result's content blocks ([{type:text,text:..}]) to a string."
  (let ((content (and result (%mget result "content"))))
    (if (consp content)
        (with-output-to-string (s)
          (dolist (block content)
            (let ((txt (%mget block "text"))) (when (stringp txt) (write-string txt s)))))
        "")))

(defun mcp-call (conn name args-alist)
  "Invoke MCP tool NAME with ARGS-ALIST (a JSON object alist); return its text result."
  (let ((result (%mget (%mcp-request conn "tools/call"
                                     (list (cons "name" name)
                                           (cons "arguments" (or args-alist :emptyobj))))
                       "result")))
    (%mcp-result-value result)))

(defun mcp-tool (conn tool-spec &key (package (find-package :ailisp)))
  "Wrap one MCP TOOL-SPEC as an ailisp TOOL: a positional call (toolname a b ...) is zipped onto
   the tool's named parameters (inputSchema order) and sent to the server via tools/call."
  (let ((name (%mget tool-spec "name"))
        (params (%mcp-param-names tool-spec)))
    (make-tool :name (intern (string-upcase name) package)
               :doc (or (%mget tool-spec "description") "")
               :fn (lambda (&rest args) (mcp-call conn name (%mcp-args params args))))))

(defun mcp-tools (conn &key (package (find-package :ailisp)))
  "Connect the server's whole toolset as ailisp tools (pass straight to react/build/plan-execute)."
  (mapcar (lambda (ts) (mcp-tool conn ts :package package)) (mcp-list-tools conn)))
