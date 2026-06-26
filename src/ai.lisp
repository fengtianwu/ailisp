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

(defun %normalize-py-strings (s)
  "Recovery: turn paired single-quoted tokens 'X' into \"X\" (Python-style string
   args LLMs emit, e.g. ('G' 'C')). Lisp quote 'sym / '(..) has no closing ' so it
   is left untouched. Applied ONLY as a fallback when the normal read fails."
  (with-output-to-string (out)
    (let ((i 0) (n (length s)))
      (loop while (< i n)
            for c = (char s i)
            do (let ((j (and (char= c #\') (position #\' s :start (1+ i)))))
                 (if j
                     (progn (write-char #\" out) (write-string (subseq s (1+ i) j) out)
                            (write-char #\" out) (setf i (1+ j)))
                     (progn (write-char c out) (incf i))))))))

(defun %normalize-empty-calls (s)
  "Rewrite Python-style no-arg calls `foo()` -> `foo` (Lisp wants (foo)). Only
   touches `()` immediately following an identifier char, so a real empty list `()`
   or `(f ())` is untouched."
  (with-output-to-string (out)
    (let ((i 0) (n (length s)))
      (loop while (< i n) do
        (if (and (char= (char s i) #\() (< (1+ i) n) (char= (char s (1+ i)) #\))
                 (> i 0) (let ((p (char s (1- i))))
                           (or (alphanumericp p) (member p '(#\_ #\- #\? #\. #\/ #\*)))))
            (incf i 2)
            (progn (write-char (char s i) out) (incf i)))))))

(defun read-sexpr-safe (s &optional read-package)
  "READ S as one s-expression with read-time eval DISABLED (no #. injection),
   using the ailisp readtable so [] / {} parse. Symbols intern in READ-PACKAGE
   so they match the tool symbols passed to safe-eval. On read failure, retry once
   with Python-style single-quote strings normalized."
  (let ((*read-eval* nil)
        (*readtable* *ailisp-readtable*)
        (*package* (cond ((packagep read-package) read-package)
                         (read-package (find-package read-package))
                         (t (find-package :ailisp))))
        (body (%normalize-empty-calls (%strip-fences s))))
    (handler-case (values (read-from-string body))
      (error ()
        (handler-case (values (read-from-string (%normalize-py-strings body)))
          (error () nil))))))

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
