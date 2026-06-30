;;;; AST dependency-graph auto-parallel demo (DESIGN §7): layer a batch of helpers by their
;;;; inter-dependencies and run each layer's independent nodes CONCURRENTLY. The cost worth
;;;; overlapping in ailisp is the LLM call, so the payoff is `synth-graph`: independent helper
;;;; functions synthesize at the same time. Offline self-check needs no model; the live section
;;;; needs hiai-core.
;;;;   sbcl --script run-parallel.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/repel" "src/agent" "src/build"
               "src/intent" "src/fallback" "src/parallel"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

(defun %ms (start) (round (* 1000 (/ (- (get-internal-real-time) start)
                                     internal-time-units-per-second))))

;;; ---- deterministic self-check (no model) ----
(format t "~&[auto-parallel self-check]~%")
;; 1. dependencies inferred from the defun ASTs, then layered.
(multiple-value-bind (layers deps)
    (defun-layers '((defun total (xs) (reduce #'+ (mapcar #'sq xs)))
                    (defun sq (x) (* x x))
                    (defun avg (xs) (/ (total xs) (length xs)))))
  (format t "  ~A AST deps   = ~S~%" (if (equal deps '((total sq) (sq) (avg total))) "ok  " "FAIL") deps)
  (format t "  ~A layers     = ~S~%" (if (equal layers '((sq) (total) (avg))) "ok  " "FAIL") layers))
;; 2. the layer executor overlaps independent work: 3 nodes x 0.2s.
(flet ((work (n) (sleep 0.2) n))
  (let* ((s1 (get-internal-real-time))
         (seq (run-graph '(a b c) '((a) (b) (c)) #'work :parallel nil)) (t1 (%ms s1))
         (s2 (get-internal-real-time))
         (par (run-graph '(a b c) '((a) (b) (c)) #'work :parallel t)) (t2 (%ms s2)))
    (format t "  ~A run-graph parallel==sequential result; wall seq=~Dms par=~Dms (~,1Fx)~%"
            (if (equal (mapcar #'car seq) (mapcar #'car par)) "ok  " "FAIL")
            t1 t2 (/ t1 (max 1 t2)))))
;; 3. synth-graph (sequential, mock model): independent leaves then a dependent combiner.
(let* ((m (make-mock-model :responses '("(* x x)" "(* 2 x)" "(+ (sq x) (dbl x))"))))
  (synth-graph '((sq (x) "square of x" :examples (((3) 9)))
                 (dbl (x) "double x" :examples (((4) 8)))
                 (combine (x) "sq(x) plus dbl(x)" :deps (sq dbl) :examples (((3) 15))))
               :parallel nil :model m :read-package (find-package :ailisp))
  (format t "  ~A synth-graph installed: (combine 3) = ~S (expect 15)~%"
          (if (eql (combine 3) 15) "ok  " "FAIL") (combine 3)))

;;; ---- live: synthesize 3 independent helpers CONCURRENTLY, then a combiner ----
(setf *model* (make-openai-model))
(format t "~%[live synth-graph: independent helpers synthesize in parallel]~%")
(let ((specs '((sq    (x) "the square of x"        :examples (((3) 9)))
               (cube  (x) "the cube of x"          :examples (((2) 8)))
               (neg   (x) "the negation of x"      :examples (((5) -5)))
               (combo (x) "sq(x) + cube(x) + neg(x)" :deps (sq cube neg) :examples (((2) 10))))))
  ;; layer 1 = {sq cube neg} (independent -> parallel), layer 2 = {combo}.
  (dolist (par '(nil t))
    (fmakunbound 'sq) (fmakunbound 'cube) (fmakunbound 'neg) (ignore-errors (fmakunbound 'combo))
    (let* ((start (get-internal-real-time))
           (res (nth-value 1 (synth-graph specs :parallel par :verbose nil)))
           (ms (%ms start)))
      (declare (ignore res))
      (format t "  parallel=~A  wall=~5Dms   (combo 2) = ~S  (expect 10)~%"
              par ms (ignore-errors (combo 2))))))
(format t "~&~%(layer 1's 3 model calls overlap when parallel -> ~~1 call's latency, not 3.)~%")
