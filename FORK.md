# Zuko flterm fork

This fork started from `flterm 0.0.4`, published on pub.dev by the libghostty
project. Its upstream license is preserved in `LICENSE`.

The fork fixes Kitty image replacement, pointer fidelity, pixel resize
reporting, and browser behavior for Zuko while the changes are prepared for
upstream review.

Keep changes focused and covered by package tests. Binary test fonts and golden
fixtures are intentionally not committed; `tool/fetch-test-assets.sh` restores
them from the checksum-pinned immutable `flterm 0.0.4` pub archive before tests
run.
