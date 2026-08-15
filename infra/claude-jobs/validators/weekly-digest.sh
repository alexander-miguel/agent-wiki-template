#!/usr/bin/env bash
# Reject a digest that lost its closing line or came back as Markdown.
# Reads the digest on stdin.
set -euo pipefail

digest="$(cat)"

if ! grep -q '^Open:' <<<"$digest"; then
    echo "Digest is missing its final 'Open:' line" >&2
    exit 1
fi

if grep -q '^#' <<<"$digest"; then
    echo "Digest contains Markdown headings; plain text was requested" >&2
    exit 1
fi
