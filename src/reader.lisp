;;;; ailisp reader macros (M0/M2 seed)
;;;;   [a b c]   -> literal list   (a b c)        ; data-level list
;;;;   {:k v ..} -> (%map :k v ..)                ; tagged map form
;;;;   #t #f     -> T NIL
;;;; In ailisp *code* (later, M2) `[..]` will mean (list ..). At M0 we only need to
;;;; READ test-case data, where a literal list is exactly what we want.
(in-package :ailisp)

(defun sym= (s name)
  "True if S is a symbol whose name STRING-EQUALs NAME (package-insensitive)."
  (and (symbolp s) (string-equal (symbol-name s) name)))

(defun %map (&rest kvs)
  "Map constructor: in CODE position {:k v ...} => (%map :k v ...) builds the map
   value (keyword keys literal, values evaluated). Schemas use bare type-name
   symbols, so a schema literal is data -- quote it: '{:name string :age int}."
  (cons '%map kvs))

(defvar *ailisp-readtable* (copy-readtable nil))

(let ((*readtable* *ailisp-readtable*))
  (set-macro-character #\[
    (lambda (s c) (declare (ignore c)) (read-delimited-list #\] s t)))
  (set-macro-character #\] (get-macro-character #\)))
  (set-macro-character #\{
    (lambda (s c) (declare (ignore c)) (cons '%map (read-delimited-list #\} s t))))
  (set-macro-character #\} (get-macro-character #\)))
  (set-dispatch-macro-character #\# #\t
    (lambda (s c n) (declare (ignore s c n)) t))
  (set-dispatch-macro-character #\# #\f
    (lambda (s c n) (declare (ignore s c n)) nil))
  ;; Comma = whitespace (Clojure-style). LLMs write list/tuple args JSON-style
  ;; ([1, 2], (a, b)); without this they fail to read. `'` (quote) stays as-is.
  (set-syntax-from-char #\, #\Space))
