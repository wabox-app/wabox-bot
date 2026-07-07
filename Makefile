# wabox-bot has no build step — this Makefile just wraps the lint, test, and
# release workflows so they're one command each and can't be half-remembered.

.PHONY: lint test check release

# Mirror CI exactly (see .github/workflows/ci.yml). -x follows the sourced core
# from the entrypoint; backends/installer/scripts are checked standalone.
lint:
	shellcheck -x bin/wabox-bot
	shellcheck lib/backends/*.sh install.sh examples/aider.sh scripts/release.sh
	shellcheck plugins/*/transcribe.sh config.example

test:
	bats test/bats/

check: lint test

# Cut a release: bump VERSION, promote the CHANGELOG, commit + tag — all in
# lockstep. Runs the checks first; does not push (it prints the command).
#   make release VERSION=X.Y.Z
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=X.Y.Z"; exit 1; }
	@scripts/release.sh "$(VERSION)"
