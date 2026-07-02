;;;; The search-graph layer (src/search.lisp): promote the agent trajectory to a navigable SEARCH
;;;; and let a VERIFIER be the score. Head-to-head with the linear agent on the SAME task/model:
;;;;   write-skill         = linear rising-temp retry chain (one path, extend from "here")
;;;;   search-skill :best-first = best-first/beam TREE search; teleport to the best branch so far
;;;;   search-skill :mcts       = MCTS with UCT selection (explore/exploit; escapes a local optimum)
;;;; The offline self-check needs no model; the live section needs hiai-core (a code model is best;
;;;; see run-skill.lisp). We count model calls per approach so the cost/benefit is explicit.
;;;;   sbcl --script run-search.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/build" "src/skill" "src/skill-agent"
               "src/search"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

;;; A model wrapper that counts chat calls (so the comparison is apples-to-apples on cost).
(defstruct count-model inner (n 0))
(defmethod chat ((m count-model) messages &key params)
  (incf (count-model-n m))
  (chat (count-model-inner m) messages :params params))

;;; ---- deterministic self-check (no model): the combinator + verifier-scored search ----
(format t "~&[search self-check]~%")
(flet ((chk (label got want)
         (format t "  ~A ~A => ~S~%" (if (equal got want) "ok  " "FAIL") label got)))
  ;; the pure combinator: best-first climbs -(|x-target|) from 1 to 10 over expand=(x-1 x+1 2x)
  (multiple-value-bind (node goal)
      (tree-search 1
                   :expand (lambda (x) (remove-if-not (lambda (y) (<= 0 y 64))
                                                      (list (1- x) (1+ x) (* 2 x))))
                   :score (lambda (x) (- (abs (- x 10))))
                   :goalp (lambda (x) (= x 10))
                   :test 'eql)
    (chk "tree-search reaches the target" (and goal (snode-state node)) 10)
    (format t "      path: ~A~%" (snode-path node)))
  ;; search-skill with a mock model: round 1 gives 0.5 and 0.0 (no goal), then teleport to the
  ;; 0.5 node and round 2 produces the correct program (the verifier score picks the winner).
  (multiple-value-bind (src ok score)
      (search-skill "square of x" :name "sq" :params '(x) :examples '(((5) 25) ((3) 9))
        :branch 2 :beam 2 :budget 6
        :model (make-mock-model :responses
                 (list "(defun sq (x) (plus x 20))"   ; 25,23 -> 0.5
                       "(defun sq (x) (plus x 1))"    ; 6,4   -> 0.0
                       "(defun sq (x) (times x x))"   ; 25,9  -> 1.0 GOAL
                       "(defun sq (x) 0)")))          ; filler
    (chk "search-skill teleports to the winner" (and ok (= score 1.0)) t)
    (format t "      final SKILL: ~A~%" src)))

;;; ---- live: write-skill (linear) vs search-skill (tree), same task, same model ----
(setf *model* (make-openai-model))
(format t "~%[live: linear retry vs best-first tree search -- same model, counting calls]~%")
(let ((rows '()))
  (dolist (task
            ;; (description name params (examples...))
            '(("the factorial of a non-negative integer n"
               "fact" (n) (((5) 120) ((0) 1) ((6) 720)))
              ("sum of the integers from 1 to n inclusive"
               "gauss" (n) (((10) 55) ((1) 1) ((100) 5050)))
              ("given a net base name and a bus width w, return the SKILL list of bus-bit net names
                base<0> base<1> ... base<w-1> as strings, e.g. (busNets \"D\" 3) => (\"D<0>\" \"D<1>\" \"D<2>\")"
               "busNets" (base w) ((("D" 3) ("D<0>" "D<1>" "D<2>")) (("A" 1) ("A<0>"))))))
    (destructuring-bind (desc name params examples) task
      (format t "~&~%--- ~A~%" name)
      (let ((cw (make-count-model :inner *model*))
            (cb (make-count-model :inner *model*))
            (cm (make-count-model :inner *model*)))
        (multiple-value-bind (wsrc wok) (write-skill desc :name name :params params
                                                     :examples examples :model cw :max-tries 4)
          (multiple-value-bind (bsrc bok bscore)
              (search-skill desc :name name :params params :examples examples :model cb
                            :policy :best-first :branch 2 :beam 2 :budget 8 :max-depth 4)
            (multiple-value-bind (msrc mok mscore)
                (search-skill desc :name name :params params :examples examples :model cm
                              :policy :mcts :branch 2 :budget 8 :max-depth 4)
              (format t "  write-skill      : ~A in ~A call(s)~%      ~A~%"
                      (if wok "OK  " "FAIL") (count-model-n cw) wsrc)
              (format t "  search (best-1st): ~A (score ~,2F) in ~A call(s)~%      ~A~%"
                      (if bok "OK  " "FAIL") bscore (count-model-n cb) bsrc)
              (format t "  search (mcts/uct): ~A (score ~,2F) in ~A call(s)~%      ~A~%"
                      (if mok "OK  " "FAIL") mscore (count-model-n cm) msrc)
              (push (list name wok (count-model-n cw)
                          bok bscore (count-model-n cb) mok mscore (count-model-n cm)) rows)))))))
  ;; a compact scoreboard so the trade-off (linear cost vs search robustness) is explicit
  (format t "~%~%===================================== scoreboard =====================================~%")
  (format t "~12@A | ~6A ~5A | ~9A ~5A ~5A | ~9A ~5A ~5A~%"
          "task" "write" "calls" "best-first" "score" "calls" "mcts/uct" "score" "calls")
  (format t "--------------------------------------------------------------------------------------~%")
  (dolist (r (nreverse rows))
    (destructuring-bind (name wok wcalls bok bscore bcalls mok mscore mcalls) r
      (format t "~12@A | ~6A ~5A | ~9A ~5,2F ~5A | ~9A ~5,2F ~5A~%"
              name (if wok "OK" "fail") wcalls
              (if bok "OK" "fail") bscore bcalls (if mok "OK" "fail") mscore mcalls))))
