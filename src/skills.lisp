;;;; ailisp skills -- reuse hiai-core's shared skill store (/skills).
;;;; A skill is a reusable playbook (system-prompt-level guidance). `:skills` on
;;;; AI fetches each by name from hiai-core and prepends their bodies to :system.
(in-package :ailisp)

(defvar *hiai-url* "http://127.0.0.1:8100"
  "Base URL of the hiai-core service (knowledge base, models, skills, tools).")

(defun fetch-skill (name)
  "Return the playbook body string for skill NAME from hiai-core, or NIL."
  (let* ((resp (%curl-get (format nil "~A/skills/~A" *hiai-url* name)))
         (m (ignore-errors (json-decode resp))))
    (and m (or (%mget m "body") (%mget m "description")))))

(defun apply-skills (system skills)
  "Compose SYSTEM prompt with the bodies of SKILLS (a list of skill names)."
  (if (null skills)
      system
      (let ((bodies (remove nil (mapcar #'fetch-skill skills))))
        (format nil "~@[~A~%~%~]~{~A~^~%~%~}" system bodies))))
