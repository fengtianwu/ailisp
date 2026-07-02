;;;; ailisp packages
(defpackage :ailisp
  (:use :cl)
  (:export
   ;; reader / syntax
   #:%map #:*ailisp-readtable* #:sym=
   ;; schema
   #:validate #:render-schema
   ;; safe-eval
   #:safe-eval #:charge #:budget-exceeded #:*budget-remaining*
   ;; condition recovery (pillar 4): restartable eval-error + self-heal loop
   #:eval-error #:eval-error-form #:eval-error-cause #:eval-with-restarts
   #:retry-with #:skip #:repair-eval #:repel
   ;; model layer
   #:*model* #:chat #:call-model #:%msg
   #:make-mock-model #:mock-model #:mock-model-calls
   #:make-openai-model #:openai-model
   ;; ai
   #:ai #:llm #:s2b #:b2s #:assemble-messages #:ai-error #:ai-error-reason #:read-sexpr-safe #:resolve-params
   #:*settings* #:with-settings #:%merge-params #:%merge-plist
   ;; skills
   #:*hiai-url* #:fetch-skill #:apply-skills
   ;; agent
   #:tool #:make-tool #:tool-name #:tool-fn #:tool-doc #:react #:build-agent
   ;; build-agent workspace as a checkpointable value (mutable-state teleport)
   #:build-ws #:make-build-ws #:workspace-checkpoint #:workspace-restore
   ;; patterns (compositions of the cell)
   #:reflect #:vote #:%majority #:llm-tool #:solve
   ;; rag (pillar 2 via hiai-core KB)
   #:kb-search #:kb-context #:rag #:kb-parse-hits #:kb-tool
   ;; wolfram (a second eval-language target via hiai-core)
   #:wolfram-eval #:wolfram-tool #:%wolfram-result
   #:sql-eval #:sql-tool #:%sql-guard
   #:intent #:define-intent #:synth-fn-form #:intent-expand
   ;; symbolic fallback (DESIGN §7 L3): synthesize an undefined fn on demand
   #:*fallback-descriptions* #:synth-missing-fn #:call-with-symbol-fallback #:with-symbol-fallback
   ;; AST dependency-graph auto-parallel: layer independent defuns, synthesize concurrently
   #:defun-deps #:dep-layers #:defun-layers #:run-graph #:synth-graph
   ;; NL reader macro: #L"natural language" -> synthesized form at read time
   #:synth-nl-form #:nl-expand #:nl-reader
   ;; record/replay: capture live chat fixtures, replay offline in CI
   #:record-model #:make-record-model #:record-model-fixtures #:record-model-inner
   #:replay-model #:make-replay-from-fixtures #:replay-model-from-file #:replay-model-misses
   #:write-fixtures #:read-fixture-file #:%request-key
   ;; MCP as an external tool source: connect a server, wrap its tools as ailisp tools
   #:mcp-connect #:mcp-close #:mcp-list-tools #:mcp-call #:mcp-tool #:mcp-tools #:mcp-p
   ;; Cadence SKILL sublanguage + a SKILL-writing agent (write -> lint -> run -> self-heal)
   #:skill-run #:skill-lint #:skill-defs #:skill-read-all #:skill-error #:skill-intern
   #:skill-verify #:write-skill #:skill-lint-tool #:skill-run-tool
   ;; search: promote the trajectory to a navigable search graph (verifier = score)
   #:tree-search #:snode #:make-snode #:snode-state #:snode-score #:snode-parent #:snode-depth
   #:snode-path #:skill-score #:search-skill #:mcts #:search-build
   #:llm-judge #:search-answer
   ;; bench (M7)
   #:*last-usage* #:*bench-tasks* #:run-bench #:run-task
   #:parse-call-sexpr #:parse-call-json #:grade-call #:arg=
   ;; bfcl (real Berkeley FCL)
   #:*bfcl-dir* #:run-bfcl #:parse-named-sexpr #:parse-named-json #:grade-bfcl
   ;; json (for ollama)
   #:json-decode #:json-encode))

(defpackage :ailisp/tests
  (:use :cl :ailisp)
  (:export #:run-all #:read-cases-file))
