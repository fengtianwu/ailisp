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

# Benchmark (M7): Berkeley FCL subset + custom agent tasks vs JSON tool-calling baseline.
bench:
	@echo "TODO(M7): success rate / token cost / latency vs baseline"

.PHONY: test test-live bench
