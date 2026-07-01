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

.PHONY: test test-live bench record replay ci nl repel fallback parallel sql intent mcp skill

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

# `intent`: compile-time LLM code synthesis (固化), frozen to a disk cache. Run twice.
intent:
	$(SBCL) --script run-intent.lisp

# Self-heal (pillar 4 / 条件恢复): a runtime error -> restartable condition -> model repair.
repel:
	$(SBCL) --script run-repel.lisp

# Symbolic fallback (DESIGN §7 L3): an undefined fn -> synthesize via LLM -> CONTINUE.
fallback:
	$(SBCL) --script run-fallback.lisp

# AST dependency-graph auto-parallel: layer helpers, synthesize independent ones concurrently.
parallel:
	$(SBCL) --script run-parallel.lisp

# NL reader macro: #L"natural language" -> a Lisp form synthesized at read time, cached.
nl:
	$(SBCL) --script run-nl.lisp

# Record live agent flows into tests/fixtures/ (needs hiai-core).
record:
	$(SBCL) --script run-record.lisp

# Replay the recorded flows OFFLINE and assert each reproduces (CI-able; no model).
replay:
	$(SBCL) --script run-replay.lisp

# MCP as an external tool source: connect a stdio server, wrap its tools, use via react.
mcp:
	$(SBCL) --script run-mcp.lisp

# A real agent: authors Cadence SKILL (Cadence's Lisp dialect), verified in an in-CL SKILL
# sandbox (write -> lint -> run examples -> self-heal). Offline self-check + live section.
skill:
	$(SBCL) --script run-skill.lisp

# The full offline gate for CI: deterministic suite + replayed live flows. No network.
ci: test replay

# Full guided tour of all the patterns (edit/comment sections inside).
showcase:
	$(SBCL) --script showcase.lisp
