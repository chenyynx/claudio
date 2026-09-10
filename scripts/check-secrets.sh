#!/usr/bin/env bash
# Pre-commit secret detection (restored 2026-09-10; pattern-splitting bug
# fixed 2026-09-10 — labels and regexes were being concatenated into one
# broken alternation that matched bare words like "token").
# Scans staged added/changed lines; blocks commit on hit.
set -uo pipefail

STAGED=$(git diff --cached --diff-filter=ACM --unified=0 2>/dev/null)

if [ -z "$STAGED" ]; then
  echo "✓ 干净, 放行"
  exit 0
fi

FAIL=0

# Each entry: "label|regex" — split on the FIRST pipe.
PATTERNS=(
  "OpenAI key|sk-[a-zA-Z0-9]{20,}"
  "Anthropic key|sk-ant-[a-zA-Z0-9]{20,}"
  "AWS access key|AKIA[0-9A-Z]{16}"
  "Private key|-----BEGIN (RSA |EC |OPENSSH |PGP |DSA )?PRIVATE KEY-----"
  "Bearer token|Bearer [a-zA-Z0-9_.-]{25,}"
  "Tencent SecretId|AKID[a-zA-Z0-9]{30,}"
  "Assignment with quoted 16+ char value|(secret|token|password|passwd|api[_-]?key)[[:space:]]*[:=][[:space:]]*[\"'][a-zA-Z0-9_-]{16,}[\"']"
)

for entry in "${PATTERNS[@]}"; do
  label="${entry%%|*}"
  regex="${entry#*|}"
  if echo "$STAGED" | grep -iE "$regex" > /dev/null 2>&1; then
    echo "🔴 疑似 $label 泄漏 (staged diff 命中)"
    FAIL=1
  fi
done

if [ "$FAIL" -eq 1 ]; then
  echo "提交被拦截：请移除敏感信息或确认误报后使用 git commit --no-verify"
  exit 1
fi

echo "✓ 干净, 放行"
exit 0
