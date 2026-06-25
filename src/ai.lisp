;;;; ailisp `ai` -- the LLM-as-function call site (L1).
;;;; (ai prompt &key model system into params max-retries)
;;;; Pipeline: call model -> parse output -> (if :into) validate -> retry on failure.
;;;; On exhaustion signals AI-ERROR. Structured output + validate + retry = pillar 3.
(in-package :ailisp)

(define-condition ai-error (error)
  ((reason :initarg :reason :reader ai-error-reason)))

(defun parse-output (raw into &optional (format :json) read-package)
  "Normalize raw model output to a lisp value. => (values value ok-p).
   No schema   : pass raw through (free text).
   :json string: JSON-decode + keywordize keys (structured data).
   :sexpr str  : READ as an s-expression (tool/agent forms; tool-use = eval).
   structured  : already a value (mock path) => pass through."
  (cond ((null into) (values raw t))
        ((not (stringp raw)) (values raw t))
        ((eq format :sexpr)
         (let ((v (ignore-errors (read-sexpr-safe raw read-package))))
           (if v (values v t) (values nil nil))))
        (t (let ((v (ignore-errors (%kw-keys (json-decode (%strip-fences raw))))))
             (if v (values v t) (values nil nil))))))

(defun read-sexpr-safe (s read-package)
  "READ S as one s-expression with read-time eval DISABLED (no #. injection),
   using the ailisp readtable so [] / {} parse. Symbols intern in READ-PACKAGE
   so they match the tool symbols passed to safe-eval."
  (let ((*read-eval* nil)
        (*readtable* *ailisp-readtable*)
        (*package* (cond ((packagep read-package) read-package)
                         (read-package (find-package read-package))
                         (t (find-package :ailisp)))))
    (values (read-from-string (%strip-fences s)))))

(defun %kw-keys (x)
  "Convert (%map \"k\" v ..) string keys to keywords, recursively, so JSON-decoded
   model output matches ailisp's keyword-keyed %map convention."
  (cond ((and (consp x) (sym= (car x) "%MAP"))
         (cons '%map (loop for (k v) on (cdr x) by #'cddr
                           append (list (if (stringp k)
                                            (intern (string-upcase k) :keyword) k)
                                        (%kw-keys v)))))
        ((consp x) (mapcar #'%kw-keys x))
        (t x)))

(defun %strip-fences (s)
  "Drop ```json ... ``` fences some models wrap JSON in."
  (let* ((s (string-trim '(#\Space #\Newline #\Tab #\Return) s)))
    (if (and (>= (length s) 3) (string= (subseq s 0 3) "```"))
        (let* ((nl (position #\Newline s))
               (body (subseq s (if nl (1+ nl) 3)))
               (end (search "```" body :from-end t)))
          (string-trim '(#\Space #\Newline #\Tab #\Return)
                       (if end (subseq body 0 end) body)))
        s)))

(defparameter *creative-markers*
  '("写" "创意" "诗" "故事" "story" "poem" "brainstorm" "imagine" "creative")
  "Prompt substrings that bias :params :auto toward a higher temperature.")

(defun creative-prompt-p (prompt)
  (and (stringp prompt)
       (some (lambda (m) (search m prompt :test #'char-equal)) *creative-markers*)))

(defun resolve-params (params &key into tools prompt)
  "Turn :auto into a concrete params plist, derived from intent (overridable).
   schema/tools => deterministic (temp 0); creative prompt => 0.7; else 0.2."
  (if (eq params :auto)
      (list :temp (cond (into 0) (tools 0) ((creative-prompt-p prompt) 0.7) (t 0.2)))
      params))

(defun ai (prompt &key model system into (params :auto) (max-retries 1)
                       (format :json) read-package skills tools)
  (let ((m (or model *model*))
        (rp (resolve-params params :into into :tools tools :prompt prompt))
        (sys (let ((base (apply-skills system skills)))
               (if (and into (eq format :json))
                   (format nil "~@[~A~%~%~]Respond with ONLY JSON matching this schema (use EXACTLY these keys):~%~A"
                           base (render-schema into))
                   base))))
    (unless m (error 'ai-error :reason :no-model))
    (dotimes (i (max 1 max-retries))
      (let ((raw (call-model m prompt :system sys :params rp :into into)))
        (multiple-value-bind (val okp) (parse-output raw into format read-package)
          (when okp
            (if into
                (when (validate into val) (return-from ai (values val)))
                (return-from ai (values val)))))))
    (error 'ai-error :reason :schema-violation)))
