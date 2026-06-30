;;;; ailisp NL reader macro (DESIGN §4 / L4): natural language written INLINE in code,
;;;; translated to a Lisp form AT READ TIME by the model. The finest-grained "lower↓":
;;;;   (* 2 #L"the sum of the integers 1 to 100")   ; reads as (* 2 <synthesized form>)
;;;; This is `intent` pushed down to the READER: where intent is a macro over s-expr syntax,
;;;; #L lets you write raw natural language with no parens and the reader itself synthesizes +
;;;; SAFETY-walks the code and splices it in. Like intent it is FROZEN to the on-disk cache
;;;; (read time calls the LLM and is non-deterministic) -- first read synthesizes, later reads
;;;; are pure offline cache hits; commit the cache and the program is fixed.
;;;;   In the 3 primitives: #L = b2s(:sexpr, code-mode) ∘ llm ∘ s2b(text), resolved at READ time.
(in-package :ailisp)

(defun synth-nl-form (text &key (model *model*) tools (read-package *package*) (max-tries 3))
  "Synthesize ONE Lisp EXPRESSION realizing the natural-language TEXT: ask the model, parse
   (interning in READ-PACKAGE), SAFETY-walk (only TOOLS + safe builtins), retrying with error
   feedback. Returns the form, or NIL if it can't produce a safe, parseable expression."
  (let ((feedback ""))
    (dotimes (i max-tries nil)
      (let* ((prompt
               (format nil "Translate this instruction into ONE Lisp expression that computes it.~%~
INSTRUCTION: ~A~%You MAY use ~A and the usual safe builtins (+ - * / < > = if cond when let lambda ~
mapcar reduce loop count-if remove-if-not find-if every some length nth elt reverse sort list cons ~
first rest ...). Output ONLY the s-expression (an expression that yields the value), no prose, no ~
markdown, no defun -- a bare (lambda ...) only if the value itself is a function.~A"
                       text (if tools (format nil "~{~(~A~)~^ ~}" tools) "(none)") feedback))
             (raw (handler-case
                      (llm prompt :model model :params '(:temp 0)
                                  :system "You translate a natural-language instruction into ONE Lisp expression. Output only the s-expression.")
                    (error () nil)))
             (form (and raw (ignore-errors (read-sexpr-safe raw read-package)))))
        (cond
          ((null form)
           (setf feedback (format nil "~%(your output did not parse; output exactly ONE s-expression)")))
          ((walk-check form tools)
           (setf feedback (format nil "~%(your expression used a disallowed operator: ~(~A~); use only the allowed ops)"
                                  (walk-check form tools))))
          (t (return-from synth-nl-form form)))))))

(defun nl-expand (text &key (model *model*) tools (read-package *package*))
  "Read-time helper: return a verified Lisp form for the natural-language TEXT -- from the
   intent cache, else synthesize (calling the model), SAFETY-walk, and FREEZE to the cache.
   Reuses intent's on-disk cache (keyed by (:nl text)) so #L is reproducible/offline after the
   first read. Errors if synthesis fails."
  (let* ((key (format nil "~S" (list :nl text)))
         (hit (assoc key (%intent-cache-load) :test #'string=)))
    (if hit
        (cdr hit)
        (let ((form (synth-nl-form text :model model :tools tools :read-package read-package)))
          (unless form
            (error "#L: could not synthesize a safe form for ~S. Is *model* set / hiai-core up?" text))
          (push (cons key form) *intent-cache*)
          (%intent-cache-save)
          form))))

(defun nl-reader (stream subchar arg)
  "Dispatch reader for #L\"natural language\": read the following string and expand it (at READ
   time) into the synthesized, cached, safety-checked Lisp form, spliced in place."
  (declare (ignore subchar arg))
  (let ((text (read stream t nil t)))
    (unless (stringp text)
      (error "#L must be followed by a string, e.g. #L\"the sum of 1 to 10\"; got ~S" text))
    (nl-expand text :read-package *package*)))

;; Register #L on the ailisp readtable (alongside [] {} #t #f). Active wherever the ailisp
;; readtable is (read-sexpr-safe, the REPL, loading showcase/demo) -- NOT the default CL reader.
(set-dispatch-macro-character #\# #\L #'nl-reader *ailisp-readtable*)
