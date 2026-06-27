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

(defun %read-all-sexprs (s &optional read-package)
  "READ every s-expression in S (a model turn may contain several), safely
   (*read-eval* nil, ailisp readtable, foo()->foo). Stops at the first unreadable
   form, keeping what parsed."
  (let ((*read-eval* nil)
        (*readtable* *ailisp-readtable*)
        (*package* (cond ((packagep read-package) read-package)
                         (read-package (find-package read-package))
                         (t (find-package :ailisp))))
        (body (%normalize-empty-calls (%strip-fences s)))
        (forms '()) (i 0))
    (handler-case
        (loop (multiple-value-bind (form next) (read-from-string body nil :eof :start i)
                (when (eq form :eof) (return))
                (push form forms) (setf i next)))
      (error () nil))
    (nreverse forms)))

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

;;; ---- settings: a global default profile, per-call overrides merge over it ----
(defvar *settings* nil
  "Default ai/llm settings (plist): :model :system :params :into :max-retries :format
   :read-package :context :history :skills. Per-call keywords override; :params deep-merges.")

(defun %merge-plist (base over)
  (let ((r (copy-list base)))
    (loop for (k v) on over by #'cddr do (setf (getf r k) v)) r))

(defun %merge-params (base over)
  "Deep-merge sampling params: keys in OVER win; :auto / non-plist / :unset replaces/keeps."
  (cond ((eq over :unset) base)
        ((or (eq over :auto) (eq base :auto) (not (listp base)) (not (listp over))) over)
        (t (%merge-plist base over))))

(defun %setting (settings key explicit default)
  "Per-call EXPLICIT (unless :unset) wins, else SETTINGS, else DEFAULT."
  (if (eq explicit :unset) (getf settings key default) explicit))

(defmacro with-settings ((&rest overrides) &body body)
  "Run BODY with *settings* = current *settings* overlaid with OVERRIDES (a plist)."
  `(let ((*settings* (%merge-plist *settings* (list ,@overrides)))) ,@body))

;;; ---- the symbolic<->probabilistic boundary: s2b (into LLM) / b2s (out of LLM) ----
(defun s2b (x)
  "symbolic -> bayesian: encode a symbolic value into prompt text (into the LLM).
   Strings pass through; other values are printed readably."
  (if (stringp x) x (princ-to-string x)))

(defun b2s (raw &key into (format :json) read-package)
  "bayesian -> symbolic: project model text onto a CONSTRAINED symbolic value (out of
   the LLM). => (values value ok reason). ok=nil (+reason :unparseable | a validate
   reason) if it doesn't parse or fails the :into schema. For CODE: :format :sexpr,
   then safe-eval the returned form. (Retry = resample: compose llm+b2s in a loop.)"
  (multiple-value-bind (val okp) (parse-output raw into format read-package)
    (cond ((not okp) (values nil nil :unparseable))
          ((null into) (values val t nil))
          (t (multiple-value-bind (pass reason) (validate into val)
               (if pass (values val t nil) (values nil nil (or reason :invalid))))))))

;;; ---- assembly + the two layers (llm raw text / ai typed value) ----

(defun assemble-messages (prompt &key system context history skills)
  "Build the messages array from convenience inputs: SYSTEM (+ SKILLS playbooks) ->
   a system message; HISTORY -> prior (role . content) turns; CONTEXT -> grounding
   data prepended to the user message; PROMPT -> the user message."
  (let ((sys (apply-skills system skills))
        (user (if context
                  (format nil "参考资料:~%~A~%~%~A" (s2b context) prompt)
                  prompt)))
    (append (when sys (list (%msg "system" sys)))
            (loop for h in history collect (%msg (string-downcase (string (car h))) (cdr h)))
            (list (%msg "user" user)))))

(defun llm (prompt &key (model :unset) (system :unset) (params :unset)
                        (context :unset) (history :unset) (skills :unset) (settings *settings*))
  "Raw layer: assemble messages, resolve params, return the model's TEXT.
   No schema / validation / retry -- that is AI. Inputs default from *settings* then *model*."
  (let ((m (or (%setting settings :model model nil) *model*)))
    (unless m (error 'ai-error :reason :no-model))
    (chat m (assemble-messages prompt
                               :system  (%setting settings :system system nil)
                               :context (%setting settings :context context nil)
                               :history (%setting settings :history history nil)
                               :skills  (%setting settings :skills skills nil))
          :params (resolve-params (%merge-params (getf settings :params :auto) params) :prompt prompt))))

(defun ai (prompt &key (model :unset) (system :unset) (into :unset) (params :unset)
                       (max-retries :unset) (format :unset) (read-package :unset)
                       (context :unset) (history :unset) (skills :unset) (settings *settings*))
  "Typed layer = b2s ∘ llm ∘ s2b, with resampling: s2b inputs into messages, chat,
   then b2s onto the :into schema; on failure feed the reason back and resample (retry).
   Returns a validated value. All inputs default from *settings*; :params deep-merges.
   Tool use is agentic -> see REACT / plan-execute, not here."
  (let* ((m       (or (%setting settings :model model nil) *model*))
         (into*   (%setting settings :into into nil))
         (rp      (resolve-params (%merge-params (getf settings :params :auto) params)
                                  :into into* :prompt prompt))
         (retries (%setting settings :max-retries max-retries 1))
         (fmt     (%setting settings :format format :json))
         (rpk     (%setting settings :read-package read-package nil))
         (ctx     (%setting settings :context context nil))
         (hist    (%setting settings :history history nil))
         (sysbase (apply-skills (%setting settings :system system nil)
                                (%setting settings :skills skills nil)))
         (sysprompt (if (and into* (eq fmt :json))
                        (format nil "~@[~A~%~%~]Respond with ONLY JSON matching this schema (use EXACTLY these keys):~%~A"
                                sysbase (render-schema into*))
                        sysbase))
         (feedback nil))
    (unless m (error 'ai-error :reason :no-model))
    (dotimes (i (max 1 retries))
      (let* ((msgs (assemble-messages prompt :system sysprompt :context ctx :history hist))  ; s2b
             (msgs (if feedback (append msgs (list (%msg "user" feedback))) msgs))
             (raw (chat m msgs :params rp)))                                                  ; llm
        (multiple-value-bind (val okp reason) (b2s raw :into into* :format fmt :read-package rpk) ; b2s
          (if okp
              (return-from ai (values val))
              (setf feedback                                                                  ; resample w/ feedback
                    (if (eq reason :unparseable)
                        "Your previous output could not be parsed. Re-output ONLY the required format, nothing else."
                        (format nil "Your previous output failed validation: ~A. Fix it and re-output ONLY the JSON." reason)))))))
    (error 'ai-error :reason :schema-violation)))
