#!/bin/bash
# Builds a fake home folder for user "alex" with sample Claude files, scans it, and writes
# docs/demo.json (paths rewritten to /Users/alex). Used only to make README screenshots,
# so no real user's files ever end up in the repository. Needs python3 (dev only).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="dist/Claude Config Map.app/Contents/MacOS/ClaudeConfigMap"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
H="$W/alex"; M="$W/managed"
mkdir -p "$H/.claude/skills/commit-helper" "$H/.claude/agents" "$H/.claude/rules" "$M"

cat > "$M/CLAUDE.md" <<'EOF'
# Company policy
- Never paste customer data into prompts.
- Use the internal package registry for all dependencies.
EOF
echo '{ "permissions": { "deny": ["Bash(curl:*)"] } }' > "$M/managed-settings.json"

cat > "$H/.claude/CLAUDE.md" <<'EOF'
# My global instructions
- Answer briefly; show code before explanations.
- Prefer TypeScript and small pure functions.
- Explain token cost when adding new customizations.

@~/.claude/style.md
EOF
cat > "$H/.claude/style.md" <<'EOF'
# Writing style
Use plain language, short sentences, and American spelling.
EOF
cat > "$H/.claude/rules/security.md" <<'EOF'
# Security
Never commit secrets. Use environment variables for keys.
EOF
echo '{ "model": "opus", "permissions": { "allow": ["Bash(npm test:*)"] } }' > "$H/.claude/settings.json"
cat > "$H/.claude/skills/commit-helper/SKILL.md" <<'EOF'
---
name: commit-helper
description: Write conventional commit messages from the staged diff.
---
# Commit helper
1. Read `git diff --staged`.
2. Write a one-line summary in the imperative mood, then a short body.
EOF
cat > "$H/.claude/agents/reviewer.md" <<'EOF'
---
name: reviewer
description: Reviews a diff for bugs and missing tests.
---
You are a careful code reviewer. List real bugs first, then missing tests.
EOF
cat > "$H/.claude/catalog.md" <<'EOF'
# Customization Catalog
## 1 · Account (claude.ai)
| What | Type | Status | How to control |
|---|---|---|---|
| **team-style** – house writing style | Skill | On | claude.ai → Settings → Skills |
| **Google Drive** – read docs | Connector | On | claude.ai → Settings → Connectors |
## 2 · This Mac
EOF
printf '# Change Log\n\n## 2026-11-01 · Added commit-helper skill\n' > "$H/.claude/change-log.md"

P="$H/Developer/shop-api"; mkdir -p "$P/.git" "$P/.claude/skills/deploy" "$P/.claude/rules" "$P/services/payments" "$P/src"
cat > "$P/CLAUDE.md" <<'EOF'
# shop-api
Node + Postgres REST API.

## Commands
- `npm run dev` – start locally
- `npm test` – run tests (must pass before commit)

## Conventions
- Routes live in `src/routes`, one file per resource.
- Use the `db` helper, never raw SQL in handlers.
EOF
printf '# My notes (not committed)\n- Local DB runs on port 5433.\n' > "$P/CLAUDE.local.md"
echo '{ "permissions": { "allow": ["Bash(npm run *)"] } }' > "$P/.claude/settings.json"
echo '{ "env": { "DEBUG": "shop:*" } }' > "$P/.claude/settings.local.json"
printf -- '---\nname: deploy\ndescription: Deploy shop-api to staging with the release checklist.\n---\n# Deploy\nRun the checklist, then `npm run deploy:staging`.\n' > "$P/.claude/skills/deploy/SKILL.md"
printf -- '---\npaths: src/routes/**\n---\n# API rules\nEvery route needs input validation and a test.\n' > "$P/.claude/rules/api.md"
printf '# Payments service\nPCI scope: never log card data. Amounts are integers in cents.\n' > "$P/services/payments/CLAUDE.md"

Q="$H/Developer/mobile-app"; mkdir -p "$Q/.git" "$Q/.claude" "$Q/docs"
printf '# mobile-app\nKotlin + Jetpack Compose. Use the design system in `ui/theme`.\n' > "$Q/.claude/CLAUDE.md"
printf '# Docs folder\nWrite docs for non-developers; add a screenshot per feature.\n' > "$Q/docs/CLAUDE.md"
mkdir -p "$H/Developer/notes-site/.git"

ENC=$(python3 -c 'import re,sys;print(re.sub(r"[^A-Za-z0-9]","-",sys.argv[1]))' "$P")
mkdir -p "$H/.claude/projects/$ENC/memory"
printf '# Memory index\n- [Deploys](deploys.md) — staging deploys need VPN\n- [Test DB](test-db.md) — reset with npm run db:reset\n' > "$H/.claude/projects/$ENC/memory/MEMORY.md"
printf -- '---\nname: deploys\ndescription: staging deploys need VPN\n---\nStaging deploys fail without the office VPN.\n' > "$H/.claude/projects/$ENC/memory/deploys.md"

export CCM_HOME="$H" CCM_MANAGED_DIR="$M" CCM_ROOTS="$H/Developer" CCM_CONFIG_DIR="$W/cfg"
"$BIN" --dump-scan > "$W/scan.json"
"$BIN" --dump-stack "$P/services/payments" > "$W/s1.json"
"$BIN" --dump-stack "$P" > "$W/s2.json"
"$BIN" --dump-stack "$Q" > "$W/s3.json"
python3 - "$W" "$H" "$M" <<'PY'
import json, sys, re
w, h, m = sys.argv[1:4]
fix = lambda s: s.replace(m, "/Library/Application Support/ClaudeCode").replace(h, "/Users/alex")
load = lambda p: json.loads(fix(json.dumps(json.load(open(p)))))
scan = load(f"{w}/scan.json")
enc = lambda p: re.sub(r"[^A-Za-z0-9]", "-", p)
stacks = {}
for n in ("s1", "s2", "s3"):
    st = load(f"{w}/{n}.json")
    stacks[st["folder"]] = st
out = json.dumps({"scan": scan, "stacks": stacks}, indent=1)
out = out.replace(enc(h), enc("/Users/alex"))
import getpass
for bad in (getpass.getuser(), w):
    if bad in out: i = out.index(bad); sys.exit("leak: " + out[max(0,i-200):i+80])
open("docs/demo.json", "w").write(out)
print("wrote docs/demo.json")
PY
