;;;; ailisp pipe / threading (DESIGN.md §4 sugar).
;;;; (~> x (f _) (g _ 2) h) threads x left-to-right; `_` marks the injection slot,
;;;; default = first arg, a bare symbol step = call it on the accumulator.
;;;;   (~> 5 (- _ 100))     => (- 5 100)  => -95
;;;;   (~> 5 (- 100 _))     => (- 100 5)  => 95
;;;;   (~> 3 (+ _ 4) (* _ 2)) => 14
;;;; NOTE: infix `|>` is deferred -- `|` is CL's multiple-escape reader char.
(in-package :ailisp)

(defun %has-underscore (form)
  (cond ((and (symbolp form) (string= (symbol-name form) "_")) t)
        ((consp form) (or (%has-underscore (car form)) (%has-underscore (cdr form))))
        (t nil)))

(defun %subst-underscore (form val)
  (cond ((and (symbolp form) (string= (symbol-name form) "_")) val)
        ((consp form) (cons (%subst-underscore (car form) val)
                            (%subst-underscore (cdr form) val)))
        (t form)))

(defmacro ~> (init &rest steps)
  (reduce (lambda (acc step)
            (cond
              ((symbolp step) (list step acc))                 ; (~> x f) => (f x)
              ((%has-underscore step)                          ; inject at the _ slot(s)
               (let ((g (gensym "PIPE")))
                 `(let ((,g ,acc)) ,(%subst-underscore step g))))
              (t (list* (car step) acc (cdr step)))))          ; default: first arg
          steps :initial-value init))
