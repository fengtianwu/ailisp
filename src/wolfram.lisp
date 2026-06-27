;;;; ailisp Wolfram eval target -- a SECOND eval language, proving the boundary
;;;; generalizes: b2s code-mode eval is language-specific (swap eval_X). Here eval_X
;;;; = wolframscript via hiai-core's /wolfram (with its side-effect-approval gate).
;;;; Framing: Wolfram is an eval-TOOL called from Lisp orchestration -- the model
;;;; writes Lisp that calls (wolfram "Integrate[...]"); Lisp glues, Wolfram computes.
(in-package :ailisp)

(defun %wolfram-result (resp)
  "Interpret a /wolfram json-decoded response -> result text, or (:needs-approval)
   / (:error text)."
  (cond ((null resp) (list :error "no response"))
        ((eq (%mget resp "needs_approval") t) (list :needs-approval))
        ((and (%mget resp "ran") (eql (%mget resp "exit_code") 0))
         (string-trim '(#\Space #\Newline #\Tab #\Return) (or (%mget resp "text") "")))
        (t (list :error (string-trim '(#\Space #\Newline) (or (%mget resp "text") "error"))))))

(defun wolfram-eval (expr &key approved (timeout 60))
  "Evaluate a Wolfram Language expression string via hiai-core /wolfram.
   => result text, or (:needs-approval) for a gated side-effecting expr, or (:error t)."
  (let* ((req (json-encode (list (cons "expr" expr) (cons "timeout" timeout)
                                 (cons "approved" (if approved :true :false)))))
         (resp (ignore-errors
                 (json-decode (%curl-json (concatenate 'string *hiai-url* "/wolfram") req)))))
    (%wolfram-result resp)))

(defun wolfram-tool (&key approved)
  "A TOOL wrapping Wolfram eval, usable from react / build / plan-execute. The model
   writes (wolfram \"<Wolfram Language>\"); Lisp orchestrates, Wolfram computes."
  (make-tool :name 'wolfram
             :fn (lambda (expr) (wolfram-eval expr :approved approved))
             :doc "Evaluate a Wolfram Language expression string, e.g. (wolfram \"Integrate[Sin[x]^2, x]\")"))
