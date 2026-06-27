;;;; ailisp agent patterns -- each is a THIN composition of the cell (b2s∘llm∘s2b).
;;;; Demonstrates the synthesis: the "agent zoo" = compose / iterate / fan-out /
;;;; recurse the same cell. (See three-primitives memo.)
(in-package :ailisp)

;;; ---- reflection: iterate (fixpoint) -- draft, then improve N rounds ----
(defun reflect (prompt &key (rounds 2) model system into)
  "Draft once, then improve ROUNDS times (each pass feeds the prior answer back as
   context). = iterating the cell with output->input."
  (let ((draft (ai prompt :model model :system system :into into)))
    (dotimes (i rounds draft)
      (setf draft (ai "Improve the previous answer; output ONLY the improved version."
                      :model model :system (or system "You are a critical editor.")
                      :context draft :into into)))))

;;; ---- self-consistency: fan-out + reduce -- sample N, take the majority ----
(defun %majority (xs)
  (let ((best nil) (bestn 0))
    (dolist (x (remove-duplicates xs :test #'equal) best)
      (let ((c (count x xs :test #'equal)))
        (when (> c bestn) (setf best x bestn c))))))

(defun vote (prompt &key (n 5) model system into (temp 0.8))
  "Sample the cell N times (temp>0) and return the most common answer. = map(cell) +
   symbolic reduce (majority)."
  (%majority (loop repeat n
                   collect (ai prompt :model model :system system :into into
                              :params (list :temp temp)))))

;;; ---- llm-as-tool: the enabler for multi-agent / recursive decomposition ----
;;; A tool whose fn IS an ai-call. Now a program / react / build can call a SUB-LLM
;;; by name -> llm calling llm. "Multi-agent" = several llm-tools; "orchestrator/
;;; hierarchical" = a synthesized program that calls them (recursively). safe-eval's
;;; budget/timeout is the recursion guard.
;;; ---- recursive divide & conquer: llm calling llm, depth-bounded ----
(defun %get (m k) (and (consp m) (loop for (kk v) on (cdr m) by #'cddr when (eq kk k) return v)))

(defun solve (task &key (model *model*) (max-depth 2) (depth 0) verbose)
  "Recursive top-down decomposition: the model either answers TASK directly or splits
   it into subtasks; recurse on each (llm calls llm), then the model combines the
   sub-answers. Depth-bounded (the recursion guard). Returns an answer string."
  (flet ((say (s) (when verbose (format t "~&~v@T~A~%" (* 2 depth) s))))
    (say (format nil "▸ ~A" task))
    (if (>= depth max-depth)
        (%get (ai task :model model :system "Answer concisely in one line."
                  :into '(%map :answer string)) :answer)                       ; forced base case
        (let ((plan (ai (format nil "Task: ~A" task) :model model
                        :system "Decide whether to decompose. If the task has 2+ distinct parts/sub-questions, PREFER split=true with 2-4 independent `subtasks` (answer=\"\"). Only set split=false (answer in `answer`, subtasks=[]) for a single atomic question."
                        :into '(%map :split bool :subtasks (string) :answer string))))
          (if (%get plan :split)
              (let ((results (mapcar (lambda (s)                                 ; recurse: llm -> llm
                                       (solve s :model model :max-depth max-depth
                                                :depth (1+ depth) :verbose verbose))
                                     (%get plan :subtasks))))
                (%get (ai (format nil "Task: ~A~%Sub-answers:~%~{- ~A~%~}Combine into one concise final answer."
                                  task results)
                          :model model :system "Combine the sub-answers." :into '(%map :answer string))
                      :answer))
              (%get plan :answer))))))

(defun llm-tool (name &key model system into doc)
  (make-tool :name name
             :fn (lambda (input) (ai (if (stringp input) input (s2b input))
                                     :model model :system system :into into))
             :doc (or doc (format nil "consult the ~(~A~) sub-agent (pass a question string)" name))))
