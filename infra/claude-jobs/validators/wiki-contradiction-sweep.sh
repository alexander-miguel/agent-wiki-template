#!/usr/bin/env bash
# Reject a sweep that lost its structure. Reads the output on stdin.
set -euo pipefail

findings="$(cat)"

for heading in "## Contradictions" "## Superseded claims" "## Missing concept pages" "## Summary"; do
    if [[ "$findings" != *"$heading"* ]]; then
        echo "Sweep output is missing required heading: $heading" >&2
        exit 1
    fi
done
