#!/usr/bin/env bash
set -euo pipefail

REPO_NAME="${1:?Usage: $0 <repo-name> <origin-url> <agent-id> <agent-public-key-file> <allow-ref-regex>}"
ORIGIN_URL="${2:?Usage: $0 <repo-name> <origin-url> <agent-id> <agent-public-key-file> <allow-ref-regex>}"
AGENT_ID="${3:?Usage: $0 <repo-name> <origin-url> <agent-id> <agent-public-key-file> <allow-ref-regex>}"
AGENT_KEY_FILE="${4:?Usage: $0 <repo-name> <origin-url> <agent-id> <agent-public-key-file> <allow-ref-regex>}"
ALLOW_REF_REGEX="${5:?Usage: $0 <repo-name> <origin-url> <agent-id> <agent-public-key-file> <allow-ref-regex>}"

BASE_DIR="${BASE_DIR:-$HOME/git-proxies}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

REPO_DIR="$BASE_DIR/$REPO_NAME.git"
WRAPPER="$BIN_DIR/git-proxy-shell"

mkdir -p "$BASE_DIR" "$BIN_DIR" "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

shell_quote() {
  printf "%q" "$1"
}

# --------------------------------------------------------------------
# 1. Install/update shared forced-command wrapper.
# --------------------------------------------------------------------
cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="${1:?missing agent id}"
BASE_DIR="${2:?missing base dir}"

cmd="${SSH_ORIGINAL_COMMAND:-}"

case "$cmd" in
  git-receive-pack\ *|git-upload-pack\ *)
    op="${cmd%% *}"
    repo_req="${cmd#* }"
    ;;
  *)
    echo "Only git push/fetch over SSH is allowed." >&2
    exit 1
    ;;
esac

# Strip common Git SSH quoting:
#   git-receive-pack 'repo.git'
#   git-upload-pack "repo.git"
repo_req="${repo_req#\'}"
repo_req="${repo_req%\'}"
repo_req="${repo_req#\"}"
repo_req="${repo_req%\"}"

case "$repo_req" in
  *$'\n'*|*$'\r'*|"")
    echo "Invalid repo path." >&2
    exit 1
    ;;
esac

base_abs="$(realpath -m "$BASE_DIR")"

if [[ "$repo_req" = /* ]]; then
  repo_abs="$(realpath -m "$repo_req")"
else
  repo_abs="$(realpath -m "$BASE_DIR/$repo_req")"
fi

case "$repo_abs" in
  "$base_abs"/*.git) ;;
  *)
    echo "Repo not allowed: $repo_req" >&2
    exit 1
    ;;
esac

if [[ ! -d "$repo_abs" ]]; then
  echo "Repo does not exist: $repo_req" >&2
  exit 1
fi

policy_dir="$repo_abs/proxy-policy/agents/$AGENT_ID"

if [[ ! -d "$policy_dir" ]]; then
  echo "Agent '$AGENT_ID' is not allowed for repo: $repo_req" >&2
  exit 1
fi

export GIT_PROXY_AGENT_ID="$AGENT_ID"

case "$op" in
  git-receive-pack)
    exec git-receive-pack "$repo_abs"
    ;;

  git-upload-pack)
    # Best-effort refresh so pulls/fetches see latest upstream branches.
    # If origin is unavailable, still allow serving the local bare repo.
    git -C "$repo_abs" fetch origin '+refs/heads/*:refs/heads/*' >/dev/null 2>&1 || true
    exec git-upload-pack "$repo_abs"
    ;;

  *)
    echo "Unsupported Git operation: $op" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$WRAPPER"

# --------------------------------------------------------------------
# 2. Create/update bare proxy repo.
# --------------------------------------------------------------------
if [[ ! -d "$REPO_DIR" ]]; then
  git init --bare "$REPO_DIR"
fi

git -C "$REPO_DIR" remote remove origin 2>/dev/null || true
git -C "$REPO_DIR" remote add origin "$ORIGIN_URL"

# Initial/best-effort sync from origin into local branch refs.
# This makes pulls from the proxy useful immediately.
git -C "$REPO_DIR" fetch origin '+refs/heads/*:refs/heads/*' || true

# --------------------------------------------------------------------
# 3. Install/update per-repo, per-agent policy.
# --------------------------------------------------------------------
mkdir -p "$REPO_DIR/proxy-policy/agents/$AGENT_ID"
printf '%s\n' "$ALLOW_REF_REGEX" > "$REPO_DIR/proxy-policy/agents/$AGENT_ID/ref-regex"

# --------------------------------------------------------------------
# 4. Install/update pre-receive hook.
# --------------------------------------------------------------------
cat > "$REPO_DIR/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="${GIT_PROXY_AGENT_ID:-}"

if [[ -z "$AGENT_ID" ]]; then
  echo "Missing GIT_PROXY_AGENT_ID; pushes must go through git-proxy-shell." >&2
  exit 1
fi

REPO_DIR="$(pwd)"
POLICY_FILE="$REPO_DIR/proxy-policy/agents/$AGENT_ID/ref-regex"

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "No policy for agent: $AGENT_ID" >&2
  exit 1
fi

ALLOW_REF_REGEX="$(cat "$POLICY_FILE")"
zero="0000000000000000000000000000000000000000"

while read -r old new ref; do
  case "$ref" in
    refs/heads/*) ;;
    *)
      echo "Rejected: only branch refs are allowed: $ref" >&2
      exit 1
      ;;
  esac

  if [[ ! "$ref" =~ $ALLOW_REF_REGEX ]]; then
    echo "Rejected: agent '$AGENT_ID' may not update ref: $ref" >&2
    echo "Allowed pattern: $ALLOW_REF_REGEX" >&2
    exit 1
  fi

  if [[ "$new" == "$zero" ]]; then
    echo "Rejected: branch deletion is not allowed: $ref" >&2
    exit 1
  fi

  if [[ "$old" != "$zero" ]]; then
    if ! git merge-base --is-ancestor "$old" "$new"; then
      echo "Rejected: non-fast-forward update is not allowed: $ref" >&2
      exit 1
    fi
  fi
done
EOF

chmod +x "$REPO_DIR/hooks/pre-receive"

# --------------------------------------------------------------------
# 5. Install/update post-receive hook.
# --------------------------------------------------------------------
cat > "$REPO_DIR/hooks/post-receive" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while read -r old new ref; do
  case "$ref" in
    refs/heads/*)
      echo "Forwarding $ref to origin..."
      git push origin "$new:$ref"
      ;;
  esac
done
EOF

chmod +x "$REPO_DIR/hooks/post-receive"

# --------------------------------------------------------------------
# 6. Add/update exactly one authorized_keys block for this agent.
#    This is scoped by AGENT_ID, so rerunning for another repo with
#    the same agent updates the same agent block, not all proxy blocks.
# --------------------------------------------------------------------
AGENT_KEY="$(grep -vE '^[[:space:]]*(#|$)' "$AGENT_KEY_FILE" | head -n1)"

if [[ -z "$AGENT_KEY" ]]; then
  echo "No public key found in $AGENT_KEY_FILE" >&2
  exit 1
fi

START_MARKER="# git-proxy-agent:$AGENT_ID start"
END_MARKER="# git-proxy-agent:$AGENT_ID end"

quoted_wrapper="$(shell_quote "$WRAPPER")"
quoted_agent="$(shell_quote "$AGENT_ID")"
quoted_base="$(shell_quote "$BASE_DIR")"

tmp="$(mktemp)"

awk -v start="$START_MARKER" -v end="$END_MARKER" '
  $0 == start { skip = 1; next }
  $0 == end { skip = 0; next }
  !skip { print }
' "$AUTHORIZED_KEYS" > "$tmp"

cat >> "$tmp" <<EOF
$START_MARKER
command="$quoted_wrapper $quoted_agent $quoted_base",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $AGENT_KEY
$END_MARKER
EOF

mv "$tmp" "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

echo "Configured Git proxy repo:"
echo "  $REPO_DIR"
echo
echo "Forwarding origin:"
echo "  $ORIGIN_URL"
echo
echo "Agent:"
echo "  $AGENT_ID"
echo
echo "Allowed pushed refs:"
echo "  $ALLOW_REF_REGEX"
echo
echo "Agent remote URL:"
echo "  $(whoami)@HOST:$REPO_NAME.git"
echo
echo "Agent examples:"
echo "  git remote add handoff $(whoami)@HOST:$REPO_NAME.git"
echo "  git fetch handoff"
echo "  git push handoff agent/$AGENT_ID/my-branch"