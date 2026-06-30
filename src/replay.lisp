;;;; ailisp record/replay -- let LIVE agent flows run OFFLINE in CI. The `chat` boundary is the
;;;; one place a flow touches the model, so we intercept there: a RECORD model wraps a real model
;;;; and captures every (request -> response); a REPLAY model serves those captured responses with
;;;; NO network. A flow replayed from its fixtures is fully deterministic, so react/build/solve
;;;; etc. become CI-able regression tests. Fixtures are keyed by the REQUEST (messages + sampling
;;;; params), so replay is order-independent across distinct calls and reproduces retries / repeats
;;;; (same key -> the recorded responses in order). This is the general form of intent's cache.
(in-package :ailisp)

(defun %request-key (messages params)
  "A stable string key for a chat request = its assembled MESSAGES + sampling PARAMS. Two calls
   collide iff they would send the identical request (which at temp 0 means the same response)."
  (let ((*print-readably* nil) (*print-pretty* nil) (*print-case* :downcase)
        (*package* (find-package :ailisp)))
    (format nil "~S" (list messages params))))

;;; ---- record: wrap an inner model, capture request -> responses (in call order per key) ----

(defstruct record-model
  inner
  (log (make-hash-table :test 'equal :synchronized t))
  (order '()))

(defmethod chat ((m record-model) messages &key params)
  (multiple-value-bind (content tokens) (chat (record-model-inner m) messages :params params)
    (let ((key (%request-key messages params)))
      (sb-ext:with-locked-hash-table ((record-model-log m))
        (setf (gethash key (record-model-log m))
              (cons content (gethash key (record-model-log m))))
        (pushnew key (record-model-order m) :test #'equal)))
    (values content tokens)))

(defun record-model-fixtures (m)
  "The captured fixtures as an alist (request-key . (responses in call order)), first-seen order."
  (mapcar (lambda (key) (cons key (reverse (gethash key (record-model-log m)))))
          (reverse (record-model-order m))))

;;; ---- replay: serve recorded responses, no network ----

(defstruct replay-model
  (table (make-hash-table :test 'equal :synchronized t))
  (strict t)        ; a missing fixture is an ERROR (tells CI to re-record), not a silent NIL
  (misses 0))

(defun make-replay-from-fixtures (alist &key (strict t))
  "Build a replay-model from an ALIST (key . (responses...)); response lists are copied so
   consuming them doesn't mutate the source."
  (let ((m (make-replay-model :strict strict)))
    (dolist (pair alist m)
      (setf (gethash (car pair) (replay-model-table m)) (copy-list (cdr pair))))))

(defmethod chat ((m replay-model) messages &key params)
  (let ((key (%request-key messages params)))
    (sb-ext:with-locked-hash-table ((replay-model-table m))
      (let ((remaining (gethash key (replay-model-table m))))
        (cond
          (remaining
           (setf (gethash key (replay-model-table m)) (rest remaining))
           (values (first remaining) nil))
          ((replay-model-strict m)
           (error "replay: no recorded fixture for this request (re-run `make record`):~%~A" key))
          (t (incf (replay-model-misses m)) (values nil nil)))))))

;;; ---- fixture files (a flow's recorded result + its chat fixtures) ----

(defun write-fixtures (path result fixtures)
  "Freeze a flow's recorded RESULT and its chat FIXTURES (alist) to PATH, re-readably."
  (with-open-file (s path :direction :output :if-exists :supersede :if-does-not-exist :create
                          :external-format :utf-8)
    (write-line ";;;; ailisp record/replay fixtures -- captured chat (request -> responses) + result." s)
    (write-line ";;;; Regenerate with `make record` (needs hiai-core); replayed offline by `make replay`." s)
    (let ((*print-readably* t) (*print-pretty* t) (*print-case* :downcase)
          (*package* (find-package :ailisp)))
      (print (list :result result :chats fixtures) s))))

(defun read-fixture-file (path)
  "Read a fixture file written by WRITE-FIXTURES -> a plist (:result ... :chats alist)."
  (with-open-file (s path :external-format :utf-8)
    (let ((*read-eval* nil) (*package* (find-package :ailisp))) (read s))))

(defun replay-model-from-file (path &key (strict t))
  (make-replay-from-fixtures (getf (read-fixture-file path) :chats) :strict strict))
