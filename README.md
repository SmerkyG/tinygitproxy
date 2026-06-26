# tinygitproxy

`tinygitproxy` creates small SSH-accessible bare Git proxies for upstream repositories and agent keys. Each setup run configures one repository/agent pair, and you can run it repeatedly to support multiple repositories, multiple agents, or multiple policies. Agents can fetch through the proxy and push only the branch names allowed by their configured policy. Accepted pushes are forwarded to the real origin.

## Problem

LLM agents often need to hand off code through Git, but they should not be trusted with broad repository credentials. A normal deploy key or user SSH key can let an agent push to arbitrary branches, update protected names by mistake, delete refs, or rewrite history with a force push.

`tinygitproxy` narrows that authority. Agents connect with their own SSH keys, and the proxy only allows branch updates that match the configured policy. It rejects non-branch refs, branch deletion, and non-fast-forward updates before forwarding accepted pushes to origin.

## Setup

Install proxies under a dedicated low-privilege Unix user, ideally named something like `git`. Create this user specifically for proxy access, give it only the SSH credentials needed to read and push the intended upstream repositories, and run setup as that user. Avoid installing proxies under a personal admin account or a broadly privileged service account.

Run setup as that dedicated user on the SSH host that will receive agent Git connections:

```bash
bash setup-git-proxy.sh \
  <repo-name> \
  <origin-url> \
  <agent-id> \
  <agent-public-key-file> \
  <push-allow-branch-globs> \
  [push-deny-branch-globs] \
  [pull-allow-branch-globs] \
  [pull-deny-branch-globs]
```

Example:

```bash
bash setup-git-proxy.sh repo-name \
  git@github.com:GITHUB-USERNAME/repo-name.git \
  my-agent \
  ~/my-agent.pub \
  'agents/my-agent/*' \
  '' \
  '*'
```

By default, setup verifies that the current SSH user can read the origin with `git ls-remote --heads`. If origin auth is not ready but you still want to install the proxy files, opt in explicitly:

```bash
ALLOW_UNREACHABLE_ORIGIN=1 bash setup-git-proxy.sh ...
```

Setup prints the SSH remote URL agents should use. It detects the host with `hostname -f`; if that is not the address agents should connect to, set `PROXY_HOST`:

```bash
PROXY_HOST=dev-shared-research.example.com bash setup-git-proxy.sh ...
```

## Multiple Agents And Repositories

Run setup once for each repository/agent pair you want to allow. The script is idempotent for the same `repo-name` and `agent-id`: rerunning updates that agent's key, branch policy, hooks, and origin URL.

Examples:

```bash
# Same repo, two different agents.
bash setup-git-proxy.sh repo-name git@github.com:ORG/repo-name.git alice-agent ~/alice.pub 'agent/alice-agent/*' '' '*'
bash setup-git-proxy.sh repo-name git@github.com:ORG/repo-name.git bob-agent ~/bob.pub 'agent/bob-agent/*' '' '*'

# Same agent, another repo.
bash setup-git-proxy.sh other-repo git@github.com:ORG/other-repo.git alice-agent ~/alice.pub 'agent/alice-agent/*' '' '*'
```

For each agent id, setup maintains one marked block in `authorized_keys`. For each repo, it stores policy under:

```text
$BASE_DIR/<repo-name>.git/proxy-policy/agents/<agent-id>/
```

## Branch Policies

Policies use comma-separated branch globs, not regular expressions. They match branch names such as `main` or `agents/my-agent/work`, not full refs such as `refs/heads/main`.

Pull/clone and push policies are separate. If pull globs are omitted, pull/clone defaults to `*`. A common agent policy is:

```bash
bash setup-git-proxy.sh repo-name git@github.com:ORG/repo-name.git my-agent ~/my-agent.pub 'agents/my-agent/*' '' '*'
```

That allows the agent to clone and pull every branch, but only push branches under `agents/my-agent/`.

Common examples:

```text
*                         allow every branch
agents/my-agent/*         allow only one agent namespace
main,master                deny exact branches
release/*,stable           deny release branches and stable
```

Deny globs win over allow globs within the same policy. The proxy only accepts branch refs for pushes; tags and other non-branch refs are rejected.

## Cloning Through The Proxy

After setup finishes, it prints an agent remote URL like:

```text
git@example-host:repo-name.git
```

The usual workflow is to clone from the proxy URL directly:

```bash
git clone git@example-host:repo-name.git
cd repo-name
```

To clone a specific branch that is listed by setup as available through the proxy:

```bash
git clone --branch dev git@example-host:repo-name.git
```

This makes the proxy the clone's `origin`, so ordinary Git behavior works as expected. `git fetch`, `git pull`, and branch upstream tracking all go through the proxy.

Setup prints the branch names currently synced into the proxy. If a branch exists on the real upstream repository but is not listed by setup or by `git fetch origin` from a proxy clone, the proxy has not seen that branch from its own upstream credentials yet. Rerun setup after confirming the dedicated proxy user can see the branch on origin.

If a branch only exists locally in an agent's working clone, publish it to an allowed branch through the proxy:

```bash
git push -u origin HEAD:agents/my-agent/dev
```

That creates the remote branch and sets the local branch's upstream to it.

Push the current commit to an allowed branch name on `origin`:

```bash
git push origin HEAD:agents/my-agent/my-branch
```

If the push passes the proxy policy, the proxy forwards that update to the upstream origin configured during setup. In effect, a successful push to the clone's `origin` becomes a push to the real upstream repository, but only after the proxy rejects disallowed branch names, non-branch refs, branch deletion, and non-fast-forward history rewrites.

If the agent uses a specific private key, configure SSH for the proxy host, for example:

```sshconfig
Host git-proxy
  HostName example-host
  User git
  IdentityFile ~/.ssh/my-agent
  IdentitiesOnly yes
```

Then use the alias in the remote URL:

```bash
git clone git-proxy:repo-name.git
```

If you already have a clone from the real upstream repository, you can still add the proxy as a separate remote:

```bash
git remote add handoff git@example-host:repo-name.git
git fetch handoff
```

Or replace the existing `origin` with the proxy so the clone behaves like it was cloned through the proxy:

```bash
git remote rename origin upstream
git remote add origin git@example-host:repo-name.git
git fetch origin
```

If your current branch already exists on the proxy, set it to track the matching proxy branch:

```bash
branch=$(git branch --show-current)
git branch --set-upstream-to=origin/$branch
```

If it does not exist yet, either track an existing base branch:

```bash
git branch --set-upstream-to=origin/main
```

or push your current branch to an allowed agent branch and set upstream as part of that push:

```bash
branch=$(git branch --show-current)
git push -u origin HEAD:agents/my-agent/$branch
```

After this, plain `git pull` uses the proxy. The old direct remote is still available as `upstream` for inspection or manual fetches. If you do not want to keep it, remove it:

```bash
git remote remove upstream
```

## What Setup Installs

Setup creates or updates:

```text
$BASE_DIR/<repo-name>.git
$BIN_DIR/git-proxy-shell
$HOME/.ssh/authorized_keys
```

`BASE_DIR`, `BIN_DIR`, and `SSH_DIR` can be overridden with environment variables. The forced commands in `authorized_keys` restrict agent keys to Git fetch and push operations for configured proxy repositories.

## Removing Access Or A Proxy

To remove one agent's access to one proxy repo:

```bash
bash remove-git-proxy.sh repo-name my-agent
```

This removes:

```text
$BASE_DIR/<repo-name>.git/proxy-policy/agents/<agent-id>/
```

If that agent has no policies left for any repo under `$BASE_DIR`, the script also removes that agent's marked block from `authorized_keys`.

To also remove the bare proxy repo when no agents remain on it:

```bash
bash remove-git-proxy.sh repo-name my-agent --remove-empty-repo
```

The repo is not deleted if other agent policies still exist.

Manual cleanup is possible too:

```bash
rm -rf "$BASE_DIR/repo-name.git/proxy-policy/agents/my-agent"
```

Then remove the matching marked block from `$HOME/.ssh/authorized_keys` only if that agent should no longer access any proxy:

```text
# git-proxy-agent:my-agent start
...
# git-proxy-agent:my-agent end
```

## Troubleshooting

If setup fails with `Permission denied (publickey)` for the origin, the SSH user running setup cannot authenticate to the upstream repository. Fix that user's GitHub deploy key, SSH key, or repository access, then rerun setup.

If a push is rejected with `denied branch`, the branch matched the deny globs. If it is rejected with `may not update branch`, it did not match the allow globs.
