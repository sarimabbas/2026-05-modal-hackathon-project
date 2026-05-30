.PHONY: install install-pi install-autoresearch check-node

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
