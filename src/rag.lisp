;;;; ailisp RAG -- pillar 2 (retrieval) via hiai-core's knowledge base.
;;;; hiai-core owns embeddings + vector search (/kb/*), so RAG in ailisp is just
;;;; retrieve |> stuff |> ai (DESIGN.md §12 ②). No numeric infra to build here.
(in-package :ailisp)

(defun kb-parse-hits (decoded)
  "Turn a json-decoded /kb/search response into a list of keyword-keyed %maps."
  (mapcar (lambda (hit)
            (list '%map
                  :id     (%dig hit "entry" "id")
                  :score  (%mget hit "score")
                  :source (%dig hit "entry" "source")
                  :body   (%dig hit "entry" "body")))
          (%mget decoded "hits")))

(defun kb-search (query &key (k 3))
  "Vector-search the hiai-core KB. Returns a list of %map hits (:id :score :source :body)."
  (kb-parse-hits
   (json-decode (%curl-get-q (format nil "~A/kb/search" *hiai-url*) "q" query "k" k))))

(defun kb-context (query &key (k 4) (max-chars 600))
  "Return hiai-core's ready-to-inject context block string for QUERY (or \"\")."
  (let ((m (ignore-errors
            (json-decode (%curl-get-q (format nil "~A/kb/context" *hiai-url*)
                                      "q" query "k" k "max_chars" max-chars)))))
    (or (and m (%mget m "block")) "")))

(defun rag (question &key (k 4) (model *model*))
  "Retrieve from the KB, then answer grounded in it with citations.
   Returns a (%map :answer string :cites (id ...)). RAG = retrieve |> stuff |> ai."
  (let ((ctx (kb-context question :k k)))
    (ai (format nil "Question: ~A" question)
        :model model
        :system (format nil "Answer ONLY from the notes below. Cite the entry ids you used. Output compact JSON.~%~%~A" ctx)
        :into '(%map :answer string :cites (string))
        :max-retries 3)))

(defun kb-tool (&key (k 3))
  "A TOOL wrapping kb-search for use inside a ReAct loop."
  (make-tool :name 'kb-search
             :fn (lambda (q) (mapcar (lambda (h) (%mget h :id)) (kb-search q :k k)))
             :doc "搜索知识库,返回相关条目 id 列表;参数是查询字符串。例: (kb-search \"lessp\")"))
