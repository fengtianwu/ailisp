;;;; A tiny example MCP server (stdio transport, newline-delimited JSON-RPC 2.0) used to demo +
;;;; test ailisp's MCP client without any external dependency. Two tools: add(a,b), multiply(a,b).
;;;; Run by `mcp-connect "sbcl" "--script" "examples/mcp-add-server.lisp"`. Reuses ailisp's JSON
;;;; only to PARSE incoming requests; responses are emitted as plain JSON strings.
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("../src/package" "../src/reader" "../src/model"))   ; model.lisp = json-decode/%mget
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))

(defpackage :mcp-srv (:use :cl) (:import-from :ailisp #:json-decode #:%mget))
(in-package :mcp-srv)

(defparameter *tools-json*
  (concatenate 'string
    "{\"name\":\"add\",\"description\":\"add two integers a and b\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":"
    "{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]}},"
    "{\"name\":\"multiply\",\"description\":\"multiply two integers a and b\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":"
    "{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]}}"))

(defun send (s) (write-string s) (write-char #\Newline) (force-output))

(defun tool-text (name args)
  (let ((a (%mget args "a")) (b (%mget args "b")))
    (cond ((string= name "add")      (princ-to-string (+ a b)))
          ((string= name "multiply") (princ-to-string (* a b)))
          (t "unknown tool"))))

(loop for line = (read-line *standard-input* nil nil)
      while line
      for msg = (ignore-errors (json-decode line))
      when msg do
        (let ((method (%mget msg "method")) (id (%mget msg "id")))
          (cond
            ((null id) nil)                                   ; notification (e.g. initialized): no reply
            ((string= method "initialize")
             (send (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"ailisp-example\",\"version\":\"0.1\"}}}" id)))
            ((string= method "tools/list")
             (send (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"tools\":[~A]}}" id *tools-json*)))
            ((string= method "tools/call")
             (let* ((params (%mget msg "params"))
                    (name (%mget params "name"))
                    (args (%mget params "arguments")))
               (send (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"content\":[{\"type\":\"text\",\"text\":~S}]}}"
                             id (tool-text name args)))))
            (t (send (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}" id))))))
