SBCL ?= sbcl

# Deterministic suite (no model, no network). CI default.
test:
	$(SBCL) --script run-tests.lisp

# Live model path: drives ../hiai-core's chat server (OpenAI-compatible, :8080).
# Needs hiai-core running: (cd ../hiai-core && python -m hiai_core) with a chat model loaded.
test-live:
	$(SBCL) --script run-live.lisp

# Live ReAct agent demo (tool-use = eval) against hiai-core's chat model.
agent:
	$(SBCL) --script run-agent.lisp

# Live RAG demo (retrieve from hiai-core KB, answer grounded + cited).
rag:
	$(SBCL) --script run-rag.lisp

# Benchmark (M7): ailisp s-expr tool calls vs JSON function-calling, same model.
bench:
	$(SBCL) --script run-bench.lisp

# Real Berkeley FCL (v3 simple). Needs ./bfcl-data/. Optional: make bfcl N=80
bfcl:
	$(SBCL) --script run-bfcl.lisp $(N)

.PHONY: test test-live bench

# Composability bench: plan-execute (1 s-expr program) vs JSON tool-chaining.
compose:
	$(SBCL) --script run-compose.lisp

# Scripted demos (edit prompts in demo.lisp).
demo:
	$(SBCL) --script demo.lisp

# Interactive ailisp REPL.
repl:
	$(SBCL) --load repl.lisp

# Incremental-construction agent demo (model builds helpers bottom-up).
build:
	$(SBCL) --script run-build.lisp

# Agent patterns as cell compositions (reflect / vote / multi-agent).
patterns:
	$(SBCL) --script run-patterns.lisp

# SQL as a third eval language (declarative): self-check + live react with a SQL tool.
sql:
	$(SBCL) --script run-sql.lisp

# Full guided tour of all the patterns (edit/comment sections inside).
showcase:
	$(SBCL) --script showcase.lisp
