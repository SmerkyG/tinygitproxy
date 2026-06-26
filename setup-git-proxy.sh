#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <repo-name> <origin-url> <agent-id> <agent-public-key-file> <push-allow-branch-globs> [push-deny-branch-globs] [pull-allow-branch-globs] [pull-deny-branch-globs]" >&2
}

die() {
  echo "Error: $*" >&2
  exit 1
}

if [[ $# -lt 5 || $# -gt 8 ]]; then
  usage
  exit 2
fi

REPO_NAME="$1"
ORIGIN_URL="$2"
AGENT_ID="$3"
AGENT_KEY_FILE="$4"
PUSH_ALLOW_BRANCH_GLOBS="$5"
PUSH_DENY_BRANCH_GLOBS="${6:-}"
PULL_ALLOW_BRANCH_GLOBS="${7:-*}"
PULL_DENY_BRANCH_GLOBS="${8:-}"

BASE_DIR="${BASE_DIR:-$HOME/git-proxies}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

REPO_DIR="$BASE_DIR/$REPO_NAME.git"
WRAPPER="$BIN_DIR/git-proxy-shell"

case "$REPO_NAME" in
  ""|*/*|*\\*|.|..)
    die "repo name must be a single directory name, for example: my-repo"
    ;;
esac

case "$AGENT_ID" in
  ""|*/*|*\\*|.|..)
    die "agent id must be a single path-safe name, for example: my-agent"
    ;;
esac

if [[ ! -f "$AGENT_KEY_FILE" ]]; then
  die "agent public key file does not exist: $AGENT_KEY_FILE"
fi

if [[ ! -r "$AGENT_KEY_FILE" ]]; then
  die "agent public key file is not readable: $AGENT_KEY_FILE"
fi

AGENT_KEY="$(grep -vE '^[[:space:]]*(#|$)' "$AGENT_KEY_FILE" | head -n1)"

if [[ -z "$AGENT_KEY" ]]; then
  die "no public key found in $AGENT_KEY_FILE"
fi

if [[ -z "$PUSH_ALLOW_BRANCH_GLOBS" ]]; then
  die "push-allow-branch-globs must not be empty; use '*' to allow all branches"
fi

if [[ -z "$PULL_ALLOW_BRANCH_GLOBS" ]]; then
  die "pull-allow-branch-globs must not be empty; use '*' to allow all branches"
fi

check_origin() {
  GIT_TERMINAL_PROMPT=0 git ls-remote --heads --tags "$ORIGIN_URL" >/dev/null
}

if ! check_origin; then
  if [[ "${ALLOW_UNREACHABLE_ORIGIN:-}" == "1" ]]; then
    cat >&2 <<EOF
Warning: origin could not be reached, but ALLOW_UNREACHABLE_ORIGIN=1 is set.
  Origin: $ORIGIN_URL

The proxy will be configured without verifying that fetches and forwarded pushes can reach origin.
EOF
  else
    die "origin could not be reached or authenticated: $ORIGIN_URL
Fix this user's SSH access to origin, verify the repository exists, or rerun with ALLOW_UNREACHABLE_ORIGIN=1 to configure anyway."
  fi
fi

mkdir -p "$BASE_DIR" "$BIN_DIR" "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

shell_quote() {
  printf "%q" "$1"
}

detect_host() {
  if [[ -n "${PROXY_HOST:-}" ]]; then
    printf '%s\n' "$PROXY_HOST"
    return 0
  fi

  hostname -f 2>/dev/null || hostname
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

trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

glob_list_matches() {
  local value="$1"
  local glob_list="$2"
  local glob

  IFS=',' read -r -a globs <<< "$glob_list"

  for glob in "${globs[@]}"; do
    glob="$(trim_space "$glob")"
    [[ -z "$glob" ]] && continue

    case "$value" in
      $glob) return 0 ;;
    esac
  done

  return 1
}

upload_pack_with_policy() {
  local pull_allow_file="$policy_dir/pull-allow-branch-globs"
  local pull_deny_file="$policy_dir/pull-deny-branch-globs"
  local pull_allow_globs="*"
  local pull_deny_globs=""
  local branch
  local hide_args=()

  if [[ -f "$pull_allow_file" ]]; then
    pull_allow_globs="$(cat "$pull_allow_file")"
  fi

  if [[ -f "$pull_deny_file" ]]; then
    pull_deny_globs="$(cat "$pull_deny_file")"
  fi

  while IFS= read -r branch; do
    if [[ -n "$pull_deny_globs" ]] && glob_list_matches "$branch" "$pull_deny_globs"; then
      hide_args+=("-c" "uploadpack.hideRefs=refs/heads/$branch")
      continue
    fi

    if ! glob_list_matches "$branch" "$pull_allow_globs"; then
      hide_args+=("-c" "uploadpack.hideRefs=refs/heads/$branch")
    fi
  done < <(git -C "$repo_abs" for-each-ref --format='%(refname:strip=2)' refs/heads)

  exec git "${hide_args[@]}" upload-pack "$repo_abs"
}

case "$op" in
  git-receive-pack)
    exec git-receive-pack "$repo_abs"
    ;;

  git-upload-pack)
    # Best-effort refresh so pulls/fetches see latest upstream branches and tags.
    # If origin is unavailable, still allow serving the local bare repo.
    git -C "$repo_abs" fetch origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' >/dev/null 2>&1 || true
    upload_pack_with_policy
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

# Initial sync from origin into local branch and tag refs.
# This makes pulls from the proxy useful immediately.
if ! GIT_TERMINAL_PROMPT=0 git -C "$REPO_DIR" fetch origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'; then
  if [[ "${ALLOW_UNREACHABLE_ORIGIN:-}" == "1" ]]; then
    cat >&2 <<EOF
Warning: initial fetch from origin failed, so the proxy repo was not synced.
  Origin: $ORIGIN_URL

Check that this user can authenticate to the origin and that the repository exists.
Continuing because pushes through the proxy may still be valid once origin access is fixed.
EOF
  else
    die "initial fetch from origin failed: $ORIGIN_URL
The proxy was not fully configured. Fix origin access and rerun setup."
  fi
fi

SYNCED_BRANCHES="$(git -C "$REPO_DIR" for-each-ref --format='%(refname:short)' refs/heads)"
SYNCED_TAGS="$(git -C "$REPO_DIR" for-each-ref --format='%(refname:short)' refs/tags)"

# --------------------------------------------------------------------
# 3. Install/update per-repo, per-agent policy.
# --------------------------------------------------------------------
mkdir -p "$REPO_DIR/proxy-policy/agents/$AGENT_ID"
printf '%s\n' "$PUSH_ALLOW_BRANCH_GLOBS" > "$REPO_DIR/proxy-policy/agents/$AGENT_ID/push-allow-branch-globs"
printf '%s\n' "$PUSH_DENY_BRANCH_GLOBS" > "$REPO_DIR/proxy-policy/agents/$AGENT_ID/push-deny-branch-globs"
printf '%s\n' "$PULL_ALLOW_BRANCH_GLOBS" > "$REPO_DIR/proxy-policy/agents/$AGENT_ID/pull-allow-branch-globs"
printf '%s\n' "$PULL_DENY_BRANCH_GLOBS" > "$REPO_DIR/proxy-policy/agents/$AGENT_ID/pull-deny-branch-globs"

# Backward-compatible copies for older generated hooks and local inspection.
printf '%s\n' "$PUSH_ALLOW_BRANCH_GLOBS" > "$REPO_DIR/proxy-policy/agents/$AGENT_ID/allow-branch-globs"
printf '%s\n' "$PUSH_DENY_BRANCH_GLOBS" > "$REPO_DIR/proxy-policy/agents/$AGENT_ID/deny-branch-globs"

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
PUSH_ALLOW_GLOBS_FILE="$REPO_DIR/proxy-policy/agents/$AGENT_ID/push-allow-branch-globs"
PUSH_DENY_GLOBS_FILE="$REPO_DIR/proxy-policy/agents/$AGENT_ID/push-deny-branch-globs"
LEGACY_ALLOW_GLOBS_FILE="$REPO_DIR/proxy-policy/agents/$AGENT_ID/allow-branch-globs"
LEGACY_DENY_GLOBS_FILE="$REPO_DIR/proxy-policy/agents/$AGENT_ID/deny-branch-globs"
LEGACY_ALLOW_REGEX_FILE="$REPO_DIR/proxy-policy/agents/$AGENT_ID/allow-ref-regex"
LEGACY_DENY_REGEX_FILE="$REPO_DIR/proxy-policy/agents/$AGENT_ID/deny-ref-regex"
LEGACY_REF_REGEX_FILE="$REPO_DIR/proxy-policy/agents/$AGENT_ID/ref-regex"

trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

glob_list_matches() {
  local value="$1"
  local glob_list="$2"
  local glob

  IFS=',' read -r -a globs <<< "$glob_list"

  for glob in "${globs[@]}"; do
    glob="$(trim_space "$glob")"
    [[ -z "$glob" ]] && continue

    case "$value" in
      $glob) return 0 ;;
    esac
  done

  return 1
}

POLICY_MODE="glob"
PUSH_ALLOW_BRANCH_GLOBS=""
PUSH_DENY_BRANCH_GLOBS=""
ALLOW_REF_REGEX=""
DENY_REF_REGEX=""

if [[ -f "$PUSH_ALLOW_GLOBS_FILE" ]]; then
  PUSH_ALLOW_BRANCH_GLOBS="$(cat "$PUSH_ALLOW_GLOBS_FILE")"

  if [[ -f "$PUSH_DENY_GLOBS_FILE" ]]; then
    PUSH_DENY_BRANCH_GLOBS="$(cat "$PUSH_DENY_GLOBS_FILE")"
  fi
elif [[ -f "$LEGACY_ALLOW_GLOBS_FILE" ]]; then
  PUSH_ALLOW_BRANCH_GLOBS="$(cat "$LEGACY_ALLOW_GLOBS_FILE")"

  if [[ -f "$LEGACY_DENY_GLOBS_FILE" ]]; then
    PUSH_DENY_BRANCH_GLOBS="$(cat "$LEGACY_DENY_GLOBS_FILE")"
  fi
elif [[ -f "$LEGACY_ALLOW_REGEX_FILE" || -f "$LEGACY_REF_REGEX_FILE" ]]; then
  POLICY_MODE="regex"
  if [[ -f "$LEGACY_ALLOW_REGEX_FILE" ]]; then
    ALLOW_REF_REGEX="$(cat "$LEGACY_ALLOW_REGEX_FILE")"
  else
    ALLOW_REF_REGEX="$(cat "$LEGACY_REF_REGEX_FILE")"
  fi

  if [[ -f "$LEGACY_DENY_REGEX_FILE" ]]; then
    DENY_REF_REGEX="$(cat "$LEGACY_DENY_REGEX_FILE")"
  fi
else
  echo "No policy for agent: $AGENT_ID" >&2
  exit 1
fi

zero="0000000000000000000000000000000000000000"

while read -r old new ref; do
  case "$ref" in
    refs/heads/*)
      ref_type="branch"
      branch="${ref#refs/heads/}"
      ;;
    refs/tags/*)
      ref_type="tag"
      tag="${ref#refs/tags/}"
      ;;
    *)
      echo "Rejected: only branch and tag refs are allowed: $ref" >&2
      exit 1
      ;;
  esac

  if [[ "$ref_type" == "tag" ]]; then
    if [[ "$new" == "$zero" ]]; then
      echo "Rejected: tag deletion is not allowed: $tag" >&2
      exit 1
    fi

    if [[ "$old" != "$zero" ]]; then
      echo "Rejected: moving an existing tag is not allowed: $tag" >&2
      exit 1
    fi

    continue
  fi

  if [[ "$POLICY_MODE" == "glob" ]]; then
    if [[ -n "$PUSH_DENY_BRANCH_GLOBS" ]] && glob_list_matches "$branch" "$PUSH_DENY_BRANCH_GLOBS"; then
      echo "Rejected: agent '$AGENT_ID' may not update denied branch: $branch" >&2
      echo "Denied push branch globs: $PUSH_DENY_BRANCH_GLOBS" >&2
      exit 1
    fi

    if ! glob_list_matches "$branch" "$PUSH_ALLOW_BRANCH_GLOBS"; then
      echo "Rejected: agent '$AGENT_ID' may not update branch: $branch" >&2
      echo "Allowed push branch globs: $PUSH_ALLOW_BRANCH_GLOBS" >&2
      exit 1
    fi
  else
    if [[ -n "$DENY_REF_REGEX" && "$ref" =~ $DENY_REF_REGEX ]]; then
      echo "Rejected: agent '$AGENT_ID' may not update denied ref: $ref" >&2
      echo "Denied pattern: $DENY_REF_REGEX" >&2
      exit 1
    fi

    if [[ ! "$ref" =~ $ALLOW_REF_REGEX ]]; then
      echo "Rejected: agent '$AGENT_ID' may not update ref: $ref" >&2
      echo "Allowed pattern: $ALLOW_REF_REGEX" >&2
      exit 1
    fi
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
    refs/heads/*|refs/tags/*)
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

SSH_USER="$(whoami)"
SSH_HOST="$(detect_host)"
AGENT_REMOTE_URL="$SSH_USER@$SSH_HOST:$REPO_NAME.git"
EXAMPLE_BRANCH="agents/$AGENT_ID/my-branch"

echo "Configured Git proxy repo:"
echo "  $REPO_DIR"
echo
echo "Forwarding origin:"
echo "  $ORIGIN_URL"
echo
echo "Branches currently synced into proxy:"
if [[ -n "$SYNCED_BRANCHES" ]]; then
  while IFS= read -r branch; do
    echo "  $branch"
  done <<< "$SYNCED_BRANCHES"
else
  echo "  (none)"
fi
echo
echo "Tags currently synced into proxy:"
if [[ -n "$SYNCED_TAGS" ]]; then
  while IFS= read -r tag; do
    echo "  $tag"
  done <<< "$SYNCED_TAGS"
else
  echo "  (none)"
fi
echo
echo "Agent:"
echo "  $AGENT_ID"
echo
echo "Allowed pull/clone branches:"
echo "  $PULL_ALLOW_BRANCH_GLOBS"
if [[ -n "$PULL_DENY_BRANCH_GLOBS" ]]; then
  echo
  echo "Denied pull/clone branches:"
  echo "  $PULL_DENY_BRANCH_GLOBS"
fi
echo
echo "Allowed push branches:"
echo "  $PUSH_ALLOW_BRANCH_GLOBS"
if [[ -n "$PUSH_DENY_BRANCH_GLOBS" ]]; then
  echo
  echo "Denied push branches:"
  echo "  $PUSH_DENY_BRANCH_GLOBS"
fi
echo
echo "SSH endpoint:"
echo "  User: $SSH_USER"
echo "  Host: $SSH_HOST"
echo "  Repo path: $REPO_NAME.git"
echo
echo "Agent remote URL:"
echo "  $AGENT_REMOTE_URL"
echo
echo "Agent clone command:"
echo "  git clone $AGENT_REMOTE_URL"
echo "  git clone --branch <listed-branch> $AGENT_REMOTE_URL"
echo
echo "Agent push example:"
echo "  git push origin HEAD:$EXAMPLE_BRANCH"
echo "  git tag my-tag"
echo "  git push origin my-tag"
echo
echo "Notes:"
echo "  The agent must connect with the private key matching: $AGENT_KEY_FILE"
echo "  Cloning from the proxy makes it the clone's origin, so normal git pull/fetch behavior works through the proxy."
echo "  Only synced branches allowed by the pull/clone policy can be cloned by name from the proxy."
echo "  Tags are visible and creatable by default; deleting or moving existing tags is rejected."
echo "  Pull/clone and push branch names are checked against their separate branch globs above."
