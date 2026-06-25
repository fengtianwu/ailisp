;;;; ailisp model layer -- model-agnostic provider abstraction.
;;;; A model is a value; CALL-MODEL is the protocol. Two adapters:
;;;;   - mock-model   : scripted responses (for deterministic tests; no network)
;;;;   - ollama-model : local model via curl HTTP (untested until ollama is installed)
;;;; CALL-MODEL returns raw model output: a string (to be parsed) OR an already
;;;; structured value (mock convenience). PARSE-OUTPUT (in ai.lisp) normalizes it.
(in-package :ailisp)

(defvar *model* nil "Default model used by AI when :model is omitted.")
(defvar *last-usage* nil "Total tokens reported by the most recent model call, or NIL.")

(defgeneric call-model (model prompt &key system params into))

;;; ---- mock ----
(defstruct mock-model (responses nil) (idx 0) (calls 0))

(defmethod call-model ((m mock-model) prompt &key system params into)
  (declare (ignore prompt system params into))
  (incf (mock-model-calls m))
  (prog1 (nth (mock-model-idx m) (mock-model-responses m))
    (incf (mock-model-idx m))))

;;; ---- OpenAI-compatible chat (hiai-core's local MLX/llama server on :8080) ----
;;; Talks to {url}/chat/completions. This is the recommended live adapter: hiai-core
;;; (../hiai-core) already manages the chat model, embeddings + KB vector search
;;; (/kb/search = pillar 2), skills (/skills) and tools (/web/search, /wolfram).
(defstruct openai-model (url "http://127.0.0.1:8080/v1") (id "default") (max-tokens 2048))

(defun %dig (map &rest keys)
  "Walk a json-decoded structure: %map by string key, list by 0-based index."
  (dolist (k keys map)
    (setf map (cond ((integerp k) (nth k map))
                    (t (%mget map k))))))

(defmethod call-model ((m openai-model) prompt &key system params into)
  (declare (ignore into))
  (let* ((msgs (append (when system
                         (list (list (cons "role" "system") (cons "content" system))))
                       (list (list (cons "role" "user") (cons "content" prompt)))))
         (req (json-encode
               (list (cons "model" (openai-model-id m))
                     (cons "messages" msgs)
                     (cons "max_tokens" (or (getf params :max-tokens) (openai-model-max-tokens m)))
                     (cons "temperature" (or (getf params :temp) 0))
                     (cons "stream" :false))))
         (resp (%curl-json (concatenate 'string (openai-model-url m) "/chat/completions") req))
         (parsed (json-decode resp)))
    (setf *last-usage* (%dig parsed "usage" "total_tokens"))
    ;; return the assistant content string; parse-output (ai.lisp) decodes it if :into
    (%dig parsed "choices" 0 "message" "content")))

;;; ---- ollama (local) ----
;;; NOTE: M0 ships this but it is UNVERIFIED (ollama not installed in dev env).
(defstruct ollama-model (url "http://localhost:11434") (id "qwen2.5"))

(defun %curl-json (url body)
  "POST BODY (a json string) to URL via curl; return response body string."
  (with-output-to-string (out)
    (sb-ext:run-program
     "curl" (list "-s" "-X" "POST" url
                  "-H" "Content-Type: application/json"
                  "--data-binary" body)
     :search t :output out :error nil)))

(defun %curl-get (url)
  "GET URL via curl; return response body string."
  (with-output-to-string (out)
    (sb-ext:run-program "curl" (list "-s" url) :search t :output out :error nil)))

(defun %curl-get-q (url &rest params)
  "GET URL with query PARAMS (plist of name value), url-encoded by curl -G."
  (with-output-to-string (out)
    (sb-ext:run-program
     "curl" (append (list "-s" "-G" url)
                    (loop for (k v) on params by #'cddr
                          append (list "--data-urlencode" (format nil "~A=~A" k v))))
     :search t :output out :error nil)))

(defmethod call-model ((m ollama-model) prompt &key system params into)
  (declare (ignore params))
  (let* ((msgs (append (when system
                         (list (list (cons "role" "system") (cons "content" system))))
                       (list (list (cons "role" "user") (cons "content" prompt)))))
         (req (json-encode
               (list (cons "model" (ollama-model-id m))
                     (cons "messages" msgs)
                     (cons "stream" :false)
                     ;; ask for JSON when a schema is expected
                     (cons "format" (if into "json" :null)))))
         (resp (%curl-json (concatenate 'string (ollama-model-url m) "/api/chat") req))
         (parsed (ignore-errors (json-decode resp)))
         (content (and parsed (%mget (%mget parsed "message") "content"))))
    (if (and into content)
        (ignore-errors (json-decode content))   ; structured -> lisp (%map/list/...)
        content)))

(defun %mget (map key)
  "Get KEY (string) from a (%map ...) form produced by json-decode."
  (when (and (consp map) (sym= (car map) "%MAP"))
    (loop for (k v) on (cdr map) by #'cddr
          when (equal k key) return v)))

;;; ---- minimal JSON (for ollama path only) ----
(defun json-encode (x)
  (with-output-to-string (s) (%jenc x s)))

(defun %jenc (x s)
  (cond
    ((eq x :false) (write-string "false" s))
    ((eq x :true)  (write-string "true" s))
    ((eq x :null)  (write-string "null" s))
    ((null x) (write-string "null" s))
    ((stringp x) (%jenc-str x s))
    ((integerp x) (format s "~D" x))
    ((numberp x) (format s "~F" x))
    ((and (consp x) (consp (car x)) (stringp (caar x)))   ; alist object
     (write-char #\{ s)
     (loop for (k . v) in x for first = t then nil
           do (unless first (write-char #\, s))
              (%jenc-str k s) (write-char #\: s) (%jenc v s))
     (write-char #\} s))
    ((listp x)                                            ; array
     (write-char #\[ s)
     (loop for e in x for first = t then nil
           do (unless first (write-char #\, s)) (%jenc e s))
     (write-char #\] s))
    (t (%jenc-str (princ-to-string x) s))))

(defun %jenc-str (str s)
  (write-char #\" s)
  (loop for ch across str do
    (case ch
      (#\" (write-string "\\\"" s))
      (#\\ (write-string "\\\\" s))
      (#\Newline (write-string "\\n" s))
      (t (write-char ch s))))
  (write-char #\" s))

(defun json-decode (string)
  (let ((i 0) (n (length string)))
    (labels ((peek () (when (< i n) (char string i)))
             (next () (prog1 (char string i) (incf i)))
             (ws () (loop while (and (< i n) (member (peek) '(#\Space #\Tab #\Newline #\Return)))
                          do (incf i)))
             (val ()
               (ws)
               (let ((c (peek)))
                 (cond ((char= c #\{) (obj))
                       ((char= c #\[) (arr))
                       ((char= c #\") (str))
                       ((or (digit-char-p c) (char= c #\-)) (num))
                       ((char= c #\t) (incf i 4) t)
                       ((char= c #\f) (incf i 5) :false)
                       ((char= c #\n) (incf i 4) :null)
                       (t (error "json: bad char ~A" c)))))
             (obj ()
               (next) (ws)
               (let ((acc nil))
                 (unless (char= (peek) #\})
                   (loop
                     (ws) (let ((k (str))) (ws) (next) ; key then ':'
                            (push k acc) (push (val) acc))
                     (ws) (if (char= (peek) #\,) (next) (return))))
                 (ws) (next)                            ; consume }
                 (cons '%map (nreverse acc))))
             (arr ()
               (next) (ws)
               (let ((acc nil))
                 (unless (char= (peek) #\])
                   (loop (push (val) acc) (ws)
                         (if (char= (peek) #\,) (next) (return))))
                 (ws) (next)
                 (nreverse acc)))
             (str ()
               (next)
               (with-output-to-string (o)
                 (loop for c = (next) until (char= c #\")
                       do (if (char= c #\\)
                              (let ((e (next)))
                                (case e (#\n (write-char #\Newline o))
                                        (#\t (write-char #\Tab o))
                                        (t (write-char e o))))
                              (write-char c o)))))
             (num ()
               (let ((start i))
                 (loop while (and (< i n) (or (digit-char-p (peek))
                                              (member (peek) '(#\- #\+ #\. #\e #\E))))
                       do (incf i))
                 (let ((tok (subseq string start i)))
                   (if (find #\. tok) (read-from-string tok) (parse-integer tok))))))
      (prog1 (val) (ws)))))
