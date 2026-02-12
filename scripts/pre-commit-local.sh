#!/usr/bin/env bash
# Repository-specific pre-commit hooks for f5xc-marketplace
# Called by the universal .pre-commit-config.yaml local-hooks entry
set -euo pipefail

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM)

# --- Generate plugin documentation ---
echo "[local] Generating plugin documentation..."
python scripts/generate-plugin-docs.py 2>/dev/null || echo "[local] docs generation failed or not configured"

# --- Python linting (ruff) ---
PY_FILES=$(echo "$STAGED_FILES" | grep '\.py$' || true)
if [ -n "$PY_FILES" ]; then
  if command -v ruff &>/dev/null; then
    echo "[local] Linting Python files with ruff..."
    echo "$PY_FILES" | xargs ruff check --fix --exit-non-zero-on-fix
    echo "$PY_FILES" | xargs ruff format
  else
    echo "[local] ruff not installed, skipping Python lint"
  fi
fi

# --- Python type checking (mypy) ---
SCRIPT_PY_FILES=$(echo "$STAGED_FILES" | grep '^scripts/.*\.py$' || true)
if [ -n "$SCRIPT_PY_FILES" ]; then
  if command -v mypy &>/dev/null; then
    echo "[local] Running mypy type checking..."
    mypy --strict scripts/ 2>/dev/null || true
  fi
fi

# --- JSON schema validation for marketplace.json ---
if echo "$STAGED_FILES" | grep -q '\.claude-plugin/marketplace\.json'; then
  if command -v check-jsonschema &>/dev/null && [ -f schemas/marketplace.schema.json ]; then
    echo "[local] Validating marketplace.json against schema..."
    check-jsonschema --schemafile schemas/marketplace.schema.json .claude-plugin/marketplace.json
  fi
fi

# --- Cleanup generated docs ---
echo "[local] Cleaning up generated docs..."
rm -rf site/ 2>/dev/null || true
git checkout docs/plugins/*.md 2>/dev/null || true

echo "[local] All repo-specific checks passed."