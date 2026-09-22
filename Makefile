# Developer entry point. `make check` runs the macOS half of CI. CI also runs
# ruff and the Python 3.9 floor, which need tools this file does not assume.

.DEFAULT_GOAL := check
.PHONY: test desktop mcp check

test:
	python3 -m py_compile bin/frk
	python3 -m unittest discover -s tests -v
	ruby -c fastlane/Fastfile
	ruby -c templates/app_Fastfile
	ruby tests/ruby/test_release_kit.rb
	bash -n desktop/ReleaseKitApp/scripts/build_app.sh
	git diff --check

desktop:
	swift test --package-path desktop/ReleaseKitApp

mcp:
	uv run --project integrations/mcp --locked python -m unittest discover -s integrations/mcp/tests -v

check: test desktop
