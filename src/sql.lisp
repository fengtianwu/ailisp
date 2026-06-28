;;;; ailisp SQL eval target -- a THIRD eval language, and the first DECLARATIVE /
;;;; relational paradigm (distinct from the functional host Lisp and Wolfram's symbolic
;;;; math). Proves the b2s code-end {print, read, eval} generalizes across PARADIGMS, not
;;;; just syntaxes: here eval_X = the sqlite3 CLI, read_X = parse its -json rows back into
;;;; (%map ...) data. The model writes a SELECT; Lisp seeds a trusted schema, runs the
;;;; query READ-ONLY, and reads the rows back as ordinary symbolic data.
(in-package :ailisp)

(defun %sql-guard (query)
  "Return a deny-reason string if QUERY isn't a SINGLE READ-ONLY statement, else NIL.
   Read-only = a single SELECT/WITH (so DDL/DML/PRAGMA/ATTACH can't be the statement)."
  (let* ((q (string-trim '(#\Space #\Newline #\Tab #\Return #\;) query))
         (up (string-upcase q)))
    (cond
      ((zerop (length q)) "empty query")
      ((find #\; q) "only a single statement is allowed")             ; no chaining
      ((not (or (eql 0 (search "SELECT" up)) (eql 0 (search "WITH" up))))
       "only read-only SELECT/WITH queries are allowed")
      (t nil))))

(defun sql-eval (query &key (setup "") (timeout 10))
  "Run a READ-ONLY SQL QUERY against an in-memory SQLite db via the sqlite3 CLI. SETUP
   (trusted DDL/seed SQL) runs first. Returns the decoded rows (a list of (%map ...)),
   '() for no rows, or (:deny reason) for a non-read-only query / (:error text)."
  (let ((reason (%sql-guard query)))
    (if reason
        (list :deny reason)
        (let* ((q (string-right-trim '(#\; #\Space #\Newline) (string-trim '(#\Space #\Newline) query)))
               (sql (format nil "~A~%~A;~%" setup q))
               (out (make-string-output-stream))
               (err (make-string-output-stream)))
          (handler-case
              (let ((proc (sb-ext:with-timeout timeout
                            (sb-ext:run-program "sqlite3" (list "-json" ":memory:")
                                                :search t
                                                :input (make-string-input-stream sql)
                                                :output out :error err))))
                (cond
                  ((null proc) (list :error "sqlite3 not available"))
                  ((not (eql 0 (sb-ext:process-exit-code proc)))
                   (list :error (string-trim '(#\Space #\Newline)
                                             (get-output-stream-string err))))
                  (t (let ((text (string-trim '(#\Space #\Newline) (get-output-stream-string out))))
                       (if (zerop (length text))
                           '()                                  ; query ran, no rows
                           (or (ignore-errors (json-decode text)) (list :error text)))))))
            (sb-ext:timeout () (list :error "timeout"))
            (error (e) (list :error (princ-to-string e))))))))

(defun sql-tool (&key (setup "") doc)
  "A TOOL wrapping read-only SQL eval over a trusted in-memory schema (SETUP seeds it).
   The model writes (sql \"SELECT ...\"); Lisp seeds the schema, runs it read-only, reads
   rows back. A DECLARATIVE eval target alongside the functional host + Wolfram."
  (make-tool :name 'sql
             :fn (lambda (q) (sql-eval q :setup setup))
             :doc (or doc "Run a read-only SQL SELECT, e.g. (sql \"SELECT name FROM city WHERE pop>20\")")))
