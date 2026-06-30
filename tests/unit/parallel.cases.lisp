;;;; PARALLEL testset -- AST dependency-graph auto-parallel (DESIGN §7). Deterministic: the
;;;; novel/risky parts are the pure dependency analysis + layering + the layer executor's
;;;; result-equivalence (parallel must equal sequential). synth-graph's LLM use is exercised
;;;; offline in run-parallel.lisp, not here (it's run-graph + already-tested synth-fn-form).
;;;;   :forms ...           -> assert (defun-layers forms) layers (deps inferred from the AST)
;;;;   :names :deps :expect-layers -> assert (dep-layers names deps)
;;;;   :names :deps :expect :cycle -> assert a cycle is signalled
;;;;   :names :deps :expect-order  -> run-graph: parallel result must equal sequential, in order
(in-package :ailisp/tests)

(deftestset parallel

  ;; dependencies inferred from defun ASTs: sq is a leaf, total calls sq, avg calls total.
  (:name "ast-layers"
   :forms ((defun total (xs) (reduce #'+ (mapcar #'sq xs)))
           (defun sq (x) (* x x))
           (defun avg (xs) (/ (total xs) (length xs))))
   :expect-layers ((sq) (total) (avg)))

  ;; fully independent -> one parallel layer.
  (:name "independent-one-layer"
   :names (a b c) :deps ((a) (b) (c)) :expect-layers ((a b c)))

  ;; a chain serializes into one node per layer.
  (:name "chain-layers"
   :names (a b c) :deps ((a) (b a) (c b)) :expect-layers ((a) (b) (c)))

  ;; diamond: b and c both depend on a and are independent of each other -> they share a layer.
  (:name "diamond-layers"
   :names (a b c d) :deps ((a) (b a) (c a) (d b c)) :expect-layers ((a) (b c) (d)))

  ;; deps outside the batch are ignored (x is not a node).
  (:name "external-deps-ignored"
   :names (a b) :deps ((a x) (b a)) :expect-layers ((a) (b)))

  ;; a cycle is detected and named, not run forever.
  (:name "cycle-detected"
   :names (a b) :deps ((a b) (b a)) :expect :cycle)

  ;; the layer executor: parallel result must equal sequential, in layer-flattened order.
  (:name "run-parallel-equals-sequential"
   :names (a b c d) :deps ((a) (b a) (c a) (d b c)) :expect-order (a b c d)))
