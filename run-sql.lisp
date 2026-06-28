;;;; Live SQL eval-target demo: SQL as a THIRD eval language (declarative/relational),
;;;; alongside the functional host Lisp and Wolfram's symbolic math. Needs sqlite3 (always
;;;; on macOS) for the self-check; needs hiai-core for the live react section.
;;;;   sbcl --script run-sql.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/sql"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

(defparameter *seed* "create table city(name text, pop int);
insert into city values ('Tokyo',37),('Delhi',32),('Paris',11),('NewYork',19),('Shanghai',29);")

;;; ---- deterministic self-check (no model; just sqlite3) ----
(format t "~&[SQL self-check]~%")
(flet ((chk (label got want)
         (format t "  ~A ~A => ~S~%" (if (equal got want) "ok  " "FAIL") label got)))
  (chk "count pop>20" (sql-eval "select count(*) as n from city where pop>20" :setup *seed*)
       '((%map "n" 3)))
  (chk "sum of squares" (sql-eval "select sum(pop*pop) as ssq from city" :setup *seed*)
       '((%map "ssq" 3716)))
  (chk "read-only guard" (sql-eval "drop table city" :setup *seed*)
       '(:deny "only read-only SELECT/WITH queries are allowed"))
  (chk "single-stmt guard" (sql-eval "select 1; delete from city" :setup *seed*)
       '(:deny "only a single statement is allowed")))

;;; ---- live: the model writes SQL, Lisp runs it read-only, reads rows back ----
(setf *model* (make-openai-model))
(format t "~%[live react with a SQL eval-tool: hiai-core]~%")
(let ((tools (list (sql-tool :setup *seed*
                             :doc "Run a read-only SQL SELECT over table city(name,pop). e.g. (sql \"SELECT name FROM city WHERE pop>20\")"))))
  (multiple-value-bind (ans n)
      (react "Using the city table, how many cities have population over 20 (million)?"
             tools :max-steps 4)
    (format t "~&~%ANSWER: ~S   (sql tool called ~A times; expected count = 3)~%" ans n)))
