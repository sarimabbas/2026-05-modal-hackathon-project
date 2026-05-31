.PHONY: install install-pi install-autoresearch check-node human-trace human-trace-no-screenshots human-trace-menu human-trace-open-workshop replay-search replay-plan-recent replay-prune-demo replay-bench replay-server replay-register rewind-api rewind-web rewind-dev

PI_PACKAGE := @earendil-works/pi-coding-agent
AUTORESEARCH_PACKAGE := npm:pi-autoresearch

install: install-pi install-autoresearch
	@echo "✅ pi and autoresearch are installed. Run 'pi' to start."

check-node:
	@command -v npm >/dev/null 2>&1 || { echo "npm is required. Install Node.js 22+ first." >&2; exit 1; }

install-pi: check-node
	@echo "Installing pi..."
	npm install -g --ignore-scripts $(PI_PACKAGE)

install-autoresearch: install-pi
	@echo "Installing autoresearch pi package..."
	pi install $(AUTORESEARCH_PACKAGE)

human-trace:
	@echo "Starting local-only human computer usage trace. Press Ctrl-C to finish."
	swift scripts/human-trace.swift

human-trace-no-screenshots:
	@echo "Starting local-only human trace with screenshots disabled. Press Ctrl-C to finish."
	HUMAN_TRACE_SCREENSHOTS=0 swift scripts/human-trace.swift

human-trace-menu:
	@echo "Launching Human Trace menu bar app. Look for HT in the menu bar."
	swift scripts/HumanTraceMenuBar.swift

human-trace-open-workshop:
	open http://localhost:5899/runs

replay-search:
	node scripts/replay.mjs search "$(q)"

replay-plan-recent:
	node scripts/replay.mjs plan latest --since-minutes 10

replay-prune-demo:
	node scripts/replay.mjs prune --since-minutes 15

replay-bench:
	node scripts/replay.mjs bench-suite "$(run)" $(if $(native_ms),--native-ms $(native_ms),) $(if $(q),--query "$(q)",) $(if $(since_minutes),--since-minutes $(since_minutes),)

replay-server:
	npm run replay:server

replay-register:
	raindrop replay register

rewind-api:
	node server/api.mjs

rewind-web:
	npm run web

rewind-dev:
	npm run dev
