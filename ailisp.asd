;;;; ailisp -- a homoiconic Lisp that treats LLMs as first-class functions.
;;;; (M0 loads via run-tests.lisp without ASDF/Quicklisp; this system is for later.)
(asdf:defsystem "ailisp"
  :description "LLM-as-function Lisp (embedded in Common Lisp). See DESIGN.md."
  :serial t
  :components ((:module "src"
                :components ((:file "package")
                             (:file "reader")
                             (:file "schema")
                             (:file "model")
                             (:file "ai")
                             (:file "safe-eval")))))
