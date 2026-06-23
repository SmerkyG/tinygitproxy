#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <repo-name> <agent-id> [--remove-empty-repo]" >&2
}

die() {
  echo "Error: $*" >&2
  exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 2
fi

REPO_NAME="$1"
AGENT_ID="$2"
REMOVE_EMPTY_REPO="${3:-}"

if [[ -n "$REMOVE_EMPTY_REPO" && "$REMOVE_EMPTY_REPO" != "--remove-empty-repo" ]]; then
  usage
  exit 2
fi

BASE_DIR="${BASE_DIR:-$HOME/git-proxies}"
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
REPO_DIR="$BASE_DIR/$REPO_NAME.git"

case "$REPO_NAME" in
  ""|*/*|*\\*|.|..)
    die "repo name must be a single directory name, for example: my-repo"
    ;;
esac

case "$AGENT_ID" in
  ""|*/*|*\\*|.|..)
    die "agent id must be a single path-safe name, for example: dan-agent"
    ;;
esac

base_abs="$(realpath -m "$BASE_DIR")"
repo_abs="$(realpath -m "$REPO_DIR")"

case "$repo_abs" in
  "$base_abs"/*.git) ;;
  *)
    die "resolved repo path is outside BASE_DIR: $repo_abs"
    ;;
esac

policy_dir="$repo_abs/proxy-policy/agents/$AGENT_ID"

if [[ ! -d "$policy_dir" ]]; then
  die "agent '$AGENT_ID' has no policy for repo '$REPO_NAME'"
fi

rm -rf "$policy_dir"
echo "Removed agent policy:"
echo "  $policy_dir"

remaining_agent_policies="$(
  find "$base_abs" -path "*/proxy-policy/agents/$AGENT_ID" -type d -print -quit 2>/dev/null || true
)"

if [[ -z "$remaining_agent_policies" && -f "$AUTHORIZED_KEYS" ]]; then
  START_MARKER="# git-proxy-agent:$AGENT_ID start"
  END_MARKER="# git-proxy-agent:$AGENT_ID end"
  tmp="$(mktemp)"

  awk -v start="$START_MARKER" -v end="$END_MARKER" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$AUTHORIZED_KEYS" > "$tmp"

  mv "$tmp" "$AUTHORIZED_KEYS"
  chmod 600 "$AUTHORIZED_KEYS"

  echo
  echo "Removed authorized_keys block for agent:"
  echo "  $AGENT_ID"
fi

remaining_repo_agents=""
if [[ -d "$repo_abs/proxy-policy/agents" ]]; then
  remaining_repo_agents="$(
    find "$repo_abs/proxy-policy/agents" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true
  )"
fi

if [[ "$REMOVE_EMPTY_REPO" == "--remove-empty-repo" ]]; then
  if [[ -n "$remaining_repo_agents" ]]; then
    die "repo still has other agent policies; not removing repo: $repo_abs"
  fi

  rm -rf "$repo_abs"
  echo
  echo "Removed empty proxy repo:"
  echo "  $repo_abs"
else
  echo
  echo "Proxy repo left in place:"
  echo "  $repo_abs"
  echo
  echo "To remove the bare proxy repo when no agents remain, rerun with:"
  echo "  $0 $REPO_NAME $AGENT_ID --remove-empty-repo"
fi
