;;;; ailisp AST dependency-graph auto-parallel (DESIGN §7). Homoiconicity makes dependency
;;;; analysis clean: walk a batch of defun ASTs, collect which batch-names each body calls,
;;;; topologically LAYER them, and run each layer's nodes CONCURRENTLY (layers in sequence).
;;;; The cost worth parallelizing in ailisp is the LLM call, so the payoff is `synth-graph`:
;;;; independent helper functions synthesize at the same time instead of one after another.
;;;; (Pure eval is cheap; the win is overlapping the model round-trips.)
(in-package :ailisp)

;;; ---- dependency analysis (pure, from the AST) ----

(defun %called-names (form names acc)
  "Collect every symbol in NAMES that appears in CALL position (car of a cons) anywhere in
   FORM. Over-approximates (a quoted (a b) counts) -- safe for a dep graph (only adds edges)."
  (cond ((consp form)
         (let ((acc (if (and (symbolp (car form)) (member (car form) names))
                        (adjoin (car form) acc)
                        acc)))
           (%called-names (cdr form) names (%called-names (car form) names acc))))
        (t acc)))

(defun defun-deps (defun-form names)
  "The names in NAMES (excluding DEFUN-FORM's own name) that its body calls -- its
   intra-batch dependencies. DEFUN-FORM = (defun name (params) body...)."
  (let* ((self (second defun-form))
         (others (remove self names)))
    (reverse (%called-names (cdddr defun-form) others '()))))

(defun dep-layers (names deps)
  "Topologically LAYER NAMES (input order preserved within each layer). DEPS = alist
   (name . (dep-names...)); deps outside NAMES are ignored. Layer k depends only on layers <k.
   Returns the list of layers. Signals an error naming the nodes left in a dependency CYCLE."
  (let ((remaining (copy-list names))
        (done '())
        (layers '()))
    (loop while remaining do
      (let ((ready (remove-if-not
                    (lambda (n)
                      (every (lambda (d) (member d done))
                             (intersection (cdr (assoc n deps :test #'eq)) names :test #'eq)))
                    remaining)))
        (when (null ready)
          (error "dependency cycle among ~{~(~A~)~^ ~}" remaining))
        (push ready layers)
        (setf done (append ready done))
        (setf remaining (remove-if (lambda (n) (member n ready)) remaining))))
    (nreverse layers)))

(defun defun-layers (defun-forms)
  "Layer a batch of DEFUN-FORMS by their inter-defun call dependencies (AST-derived).
   Returns (values LAYERS-OF-NAMES DEPS-ALIST)."
  (let* ((names (mapcar #'second defun-forms))
         (deps (mapcar (lambda (f) (cons (second f) (defun-deps f names))) defun-forms)))
    (values (dep-layers names deps) deps)))

;;; ---- parallel layer executor ----

(defun %run-layer (layer fn parallel)
  "Apply FN to each node in LAYER. When PARALLEL, run them in one thread each and join;
   else sequentially. Returns a list of (node . result) in LAYER order."
  (if (and parallel (cdr layer))                 ; only spin threads if >1 node
      (let ((threads (mapcar (lambda (node)      ; mapcar gives each thread its own NODE
                               (sb-thread:make-thread
                                (lambda () (cons node (funcall fn node)))
                                :name (format nil "ailisp-graph-~(~A~)" node)))
                             layer)))
        (mapcar #'sb-thread:join-thread threads))
      (mapcar (lambda (node) (cons node (funcall fn node))) layer)))

(defun run-graph (names deps fn &key parallel verbose)
  "Layer NAMES by DEPS (alist name->dep-names) and run FN on each, LAYER BY LAYER, the nodes
   within a layer CONCURRENTLY when PARALLEL. Each layer completes before the next starts, so
   FN for a node may rely on its dependencies' side effects (e.g. earlier layers' installed
   fns). Returns (values RESULTS-ALIST LAYERS)."
  (let ((layers (dep-layers names deps))
        (results '()))
    (dolist (layer layers (values (nreverse results) layers))
      (when verbose
        (format t "~&[graph] layer (~A node~:p, ~A): ~{~(~A~)~^ ~}~%"
                (length layer) (if parallel "parallel" "sequential") layer))
      (dolist (pair (%run-layer layer fn parallel))
        (push pair results)))))

;;; ---- LLM-facing payoff: synthesize a dependency graph of helpers concurrently ----

(defun synth-graph (specs &key parallel (model *model*) (read-package *package*) verbose)
  "SPECS = list of (NAME PARAMS DESCRIPTION &key EXAMPLES DEPS TOOLS). Synthesize each function
   body via the model (reusing intent's synth-fn-form), INSTALL it, in dependency order; the
   independent specs within a layer synthesize CONCURRENTLY when PARALLEL -- overlapping the
   model round-trips. A spec's DEPS (other spec names it calls) are whitelisted for its body and
   are installed before it (so example-verification can call them). Returns (values RESULTS
   LAYERS) where RESULTS is an alist (name . (params body ok)); installs persist (like
   define-intent). Synthesis happens once per name."
  (let* ((byname (mapcar (lambda (s) (cons (first s) s)) specs))
         (names (mapcar #'first specs))
         (deps (mapcar (lambda (s) (cons (first s) (getf (cdddr s) :deps))) specs)))
    (flet ((build (name)
             (destructuring-bind (nm params description &rest opts) (cdr (assoc name byname :test #'eq))
               (declare (ignore nm))
               (multiple-value-bind (body ok reason)
                   (synth-fn-form description params
                                  :examples (getf opts :examples)
                                  :tools (append (getf opts :deps) (getf opts :tools))
                                  :self name :model model :read-package read-package)
                 (when verbose
                   (format t "~&  [synth ~(~A~)] ~:[FAILED: ~A~;ok~*~] ~S~%" name ok reason (and ok body)))
                 (when (and ok body)
                   (let ((fn (ignore-errors (eval (list* 'lambda params (list body))))))
                     (when fn (setf (symbol-function name) fn))))
                 (list params body ok)))))
      (run-graph names deps #'build :parallel parallel :verbose verbose))))
