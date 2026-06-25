;;;; ailisp schema validator (pillar 3)
;;;; schema grammar (s-expr):
;;;;   base : string | int | num | bool | form(=any)
;;;;   map  : (%map :k TYPE ...)        ; strict: no missing, no extra
;;;;   list : (TYPE)                    ; e.g. (int) = list of int
;;;;   union: (either (TAG TYPE) ...)   ; value (TAG payload)
;;;; (validate schema value) => (values pass-p reason field)
(in-package :ailisp)

(defun %plist->alist (pl)
  (loop for (k v) on pl by #'cddr collect (cons k v)))

(defun validate (schema value)
  (cond
    ((symbolp schema) (validate-base schema value))
    ((and (consp schema) (sym= (car schema) "%MAP")) (validate-map schema value))
    ((and (consp schema) (sym= (car schema) "EITHER")) (validate-either schema value))
    ((and (consp schema) (null (cdr schema))) (validate-list (car schema) value))
    (t (values nil :bad-schema nil))))

(defun validate-base (schema value)
  (cond
    ((sym= schema "STRING") (if (stringp value) t (values nil :type-mismatch nil)))
    ((or (sym= schema "INT") (sym= schema "INTEGER"))
     (if (integerp value) t (values nil :type-mismatch nil)))
    ((or (sym= schema "NUM") (sym= schema "NUMBER"))
     (if (numberp value) t (values nil :type-mismatch nil)))
    ((sym= schema "BOOL")
     (if (or (eq value t) (eq value nil)) t (values nil :type-mismatch nil)))
    ((sym= schema "FORM") t)                ; accept any s-expr
    (t (values nil :bad-schema nil))))

(defun validate-map (schema value)
  (unless (and (consp value) (sym= (car value) "%MAP"))
    (return-from validate-map (values nil :type-mismatch nil)))
  (let ((spec (%plist->alist (cdr schema)))
        (vals (%plist->alist (cdr value))))
    ;; required + typed
    (dolist (pair spec)
      (let* ((k (car pair)) (ty (cdr pair)) (cell (assoc k vals)))
        (unless cell (return-from validate-map (values nil :missing-field k)))
        (multiple-value-bind (ok r) (validate ty (cdr cell))
          (declare (ignore r))
          (unless ok (return-from validate-map (values nil :type-mismatch k))))))
    ;; strict: reject extras
    (dolist (pair vals)
      (unless (assoc (car pair) spec)
        (return-from validate-map (values nil :extra-field (car pair)))))
    t))

(defun validate-either (schema value)
  (let ((options (cdr schema)))
    (unless (and (consp value) (symbolp (car value)))
      (return-from validate-either (values nil :bad-tag nil)))
    (let ((opt (find (car value) options
                     :key #'car :test (lambda (a b) (string-equal (symbol-name a)
                                                                  (symbol-name b))))))
      (if opt
          (validate (second opt) (second value))
          (values nil :bad-tag nil)))))

(defun render-schema (s)
  "Render a schema as a compact JSON-shaped hint so the model uses the exact keys."
  (cond
    ((symbolp s) (format nil "<~(~A~)>" s))
    ((and (consp s) (sym= (car s) "%MAP"))
     (format nil "{~{~A~^, ~}}"
             (loop for (k v) on (cdr s) by #'cddr
                   collect (format nil "~S: ~A" (string-downcase (symbol-name k))
                                   (render-schema v)))))
    ((and (consp s) (sym= (car s) "EITHER"))
     (format nil "one of: ~{~A~^ | ~}"
             (mapcar (lambda (o) (format nil "(~(~A~) ...)" (car o))) (cdr s))))
    ((and (consp s) (null (cdr s))) (format nil "[~A]" (render-schema (car s))))
    (t "<value>")))

(defun validate-list (elem-type value)
  (unless (listp value)
    (return-from validate-list (values nil :type-mismatch nil)))
  (dolist (e value)
    (multiple-value-bind (ok r) (validate elem-type e)
      (declare (ignore r))
      (unless ok (return-from validate-list (values nil :type-mismatch nil)))))
  t)
