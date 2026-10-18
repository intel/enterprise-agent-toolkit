# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""GitHub MCP server: issue, branch, commit and pull-request tools for agents.

Calls use the agent's own PAT when its identity proxy attaches one (spec.githubTokenSecretRef),
else the server's shared GITHUB_TOKEN; the agent never sees either. Pull requests always open
as drafts: only mark_pr_ready, a separate call, makes one ready for review. Every call is
audited with the caller's client id.
"""
import base64
import logging
import os
import re
import urllib.parse

import requests
from fastmcp import FastMCP
from fastmcp.server.dependencies import get_http_headers

import auth

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("mcp-github")

API_URL = os.environ.get("GITHUB_API_BASE_URL", "https://api.github.com").rstrip("/")
SHARED_TOKEN = os.environ.get("GITHUB_TOKEN", "")
PAT_HEADER = "x-agent-github-token"
SCOPE_READ, SCOPE_WRITE = "tools:github.read", "tools:github.write"
_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")
_REF_RE = re.compile(r"^[A-Za-z0-9_./-]{1,250}$")
_session = requests.Session()
_session.headers.update({"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
_default_branches = {}

mcp = FastMCP("github")


def _repo(owner, repo):
    """`owner/repo`, validated so an argument cannot reach another API path."""
    for value in (owner, repo):
        if not _NAME_RE.match(value or "") or value in (".", ".."):
            raise ValueError(f"invalid owner or repository name '{value}'")
    return f"{owner}/{repo}"


def _ref(ref):
    if not _REF_RE.match(ref or "") or ".." in ref:
        raise ValueError(f"invalid branch or ref '{ref}'")
    return ref


def _headers():
    """The caller's own PAT from its identity proxy, else the shared token."""
    token = get_http_headers(include={PAT_HEADER}).get(PAT_HEADER) or SHARED_TOKEN
    if not token:
        raise RuntimeError("no GitHub token: set the agent's githubTokenSecretRef or the server's GITHUB_TOKEN")
    return {"Authorization": f"Bearer {token}"}


def _api(method, path, **kwargs):
    """GitHub REST call; errors carry the status and body, never the token."""
    resp = _session.request(method, f"{API_URL}{path}", headers=_headers(), timeout=30, **kwargs)
    if resp.status_code >= 400:
        raise RuntimeError(f"GitHub API {method} {path} -> {resp.status_code}: {resp.text[:500]}")
    return resp.json() if resp.content and resp.status_code != 204 else {}


def _default_branch(repo):
    if repo not in _default_branches:
        _default_branches[repo] = _api("GET", f"/repos/{repo}")["default_branch"]
    return _default_branches[repo]


def _tool(scope, action):
    """Run `action(azp)` for a caller holding `scope`; any failure is returned as text."""
    try:
        return action(auth.caller(scope)["azp"])
    except Exception as e:
        logger.warning(f"github tool failed: {e}")
        msg = str(e)
        # Agents misread a bare 404 for a wrong ref as a network failure; name the right one.
        if "No commit found for the ref" in msg:
            msg += " (the ref does not exist; omit it to use the repository's default branch)"
        return f"Error: {msg}"


def _audit(azp, tool, **fields):
    logger.info(f"AUDIT {tool} azp={azp} " + " ".join(f"{k}={v}" for k, v in fields.items()))


@mcp.tool(description="List issues in a repository, optionally filtered by state and labels")
def list_issues(owner: str, repo: str, state: str = "open", labels: str = "") -> str:
    def run(azp):
        r = _repo(owner, repo)
        issues = _api("GET", f"/repos/{r}/issues", params={"state": state, **({"labels": labels} if labels else {})})
        _audit(azp, "list_issues", repo=r)
        return "\n".join(f"#{i['number']}: {i['title']} [{i['state']}]" for i in issues) or "No issues found"
    return _tool(SCOPE_READ, run)


@mcp.tool(description="Get one issue by number: title, body, state and comment count")
def get_issue(owner: str, repo: str, issue_number: int) -> str:
    def run(azp):
        r = _repo(owner, repo)
        i = _api("GET", f"/repos/{r}/issues/{int(issue_number)}")
        _audit(azp, "get_issue", repo=r, issue=i["number"])
        return (f"#{i['number']}: {i['title']} [{i['state']}]\ncomments: {i.get('comments', 0)}\n\n"
                f"{i.get('body') or '(no description)'}")
    return _tool(SCOPE_READ, run)


@mcp.tool(description="Create an issue in a repository")
def create_issue(owner: str, repo: str, title: str, body: str = "", labels: str = "") -> str:
    def run(azp):
        r = _repo(owner, repo)
        payload = {"title": title, "body": body}
        if labels:
            payload["labels"] = [x.strip() for x in labels.split(",") if x.strip()]
        i = _api("POST", f"/repos/{r}/issues", json=payload)
        _audit(azp, "create_issue", repo=r, issue=i["number"])
        return f"Created issue #{i['number']}: {i['html_url']}"
    return _tool(SCOPE_WRITE, run)


@mcp.tool(description="Comment on an issue or pull request")
def add_issue_comment(owner: str, repo: str, issue_number: int, body: str) -> str:
    def run(azp):
        r = _repo(owner, repo)
        c = _api("POST", f"/repos/{r}/issues/{int(issue_number)}/comments", json={"body": body})
        _audit(azp, "add_issue_comment", repo=r, issue=int(issue_number))
        return f"Commented on #{issue_number}: {c['html_url']}"
    return _tool(SCOPE_WRITE, run)


@mcp.tool(description="List the files of a repository at a branch or SHA (default branch if omitted)")
def list_repo_tree(owner: str, repo: str, ref: str = "") -> str:
    def run(azp):
        r = _repo(owner, repo)
        at = _ref(ref or _default_branch(r))
        tree = _api("GET", f"/repos/{r}/git/trees/{at}", params={"recursive": "1"})
        _audit(azp, "list_repo_tree", repo=r, ref=at)
        return "\n".join(t["path"] for t in tree.get("tree", []) if t.get("type") == "blob") or "Empty tree"
    return _tool(SCOPE_READ, run)


@mcp.tool(description="Read a file from a repository at a branch or SHA (default branch if omitted)")
def get_file_contents(owner: str, repo: str, path: str, ref: str = "") -> str:
    def run(azp):
        r = _repo(owner, repo)
        at = _ref(ref or _default_branch(r))
        data = _api("GET", f"/repos/{r}/contents/{urllib.parse.quote(path.lstrip('/'))}", params={"ref": at})
        _audit(azp, "get_file_contents", repo=r, path=path, ref=at)
        if data.get("encoding") != "base64":
            return f"Error: '{path}' is not a file"
        return base64.b64decode(data["content"]).decode("utf-8", errors="replace")
    return _tool(SCOPE_READ, run)


@mcp.tool(description="Create a branch from a ref (default branch if omitted). Use your fork as owner/repo")
def create_branch(owner: str, repo: str, branch: str, from_ref: str = "") -> str:
    def run(azp):
        r, new = _repo(owner, repo), _ref(branch)
        base = _ref(from_ref or _default_branch(r))
        sha = _api("GET", f"/repos/{r}/git/ref/heads/{base}")["object"]["sha"]
        _api("POST", f"/repos/{r}/git/refs", json={"ref": f"refs/heads/{new}", "sha": sha})
        _audit(azp, "create_branch", repo=r, branch=branch, base=base)
        return f"Created branch '{branch}' from '{base}' ({sha[:7]})"
    return _tool(SCOPE_WRITE, run)


@mcp.tool(description="Create or update a file on a branch. Use your fork as owner/repo")
def commit_file(owner: str, repo: str, branch: str, path: str, content: str, message: str) -> str:
    def run(azp):
        r, b = _repo(owner, repo), _ref(branch)
        url = f"/repos/{r}/contents/{urllib.parse.quote(path.lstrip('/'))}"
        payload = {"message": message, "branch": b, "content": base64.b64encode(content.encode()).decode()}
        try:
            payload["sha"] = _api("GET", url, params={"ref": b})["sha"]
        except RuntimeError:
            pass  # a new file
        commit = _api("PUT", url, json=payload).get("commit", {}).get("sha", "")
        _audit(azp, "commit_file", repo=r, branch=b, path=path)
        return f"Committed '{path}' to '{b}' ({commit[:7]})"
    return _tool(SCOPE_WRITE, run)


@mcp.tool(description=(
    "Open a pull request, always as a draft (mark_pr_ready undrafts it). owner/repo is the target "
    "repository; head is 'branch', or 'fork-owner:branch' from a fork. Default base: its default branch"))
def create_pull_request(owner: str, repo: str, title: str, body: str, head: str, base: str = "") -> str:
    def run(azp):
        r = _repo(owner, repo)
        target = _ref(base or _default_branch(r))
        pr = _api("POST", f"/repos/{r}/pulls",
                  json={"title": title, "body": body, "head": head, "base": target, "draft": True})
        _audit(azp, "create_pull_request", repo=r, pr=pr["number"], draft="true")
        return f"Opened DRAFT PR #{pr['number']}: {pr['html_url']} (call mark_pr_ready to undraft)"
    return _tool(SCOPE_WRITE, run)


@mcp.tool(description="Mark a draft pull request ready for review. Call only after explicit approval")
def mark_pr_ready(owner: str, repo: str, pr_number: int) -> str:
    def run(azp):
        r = _repo(owner, repo)
        node = _api("GET", f"/repos/{r}/pulls/{int(pr_number)}")["node_id"]
        query = ("mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) "
                 "{ pullRequest { number isDraft } } }")
        data = _api("POST", "/graphql", json={"query": query, "variables": {"id": node}})
        if data.get("errors"):
            raise RuntimeError(f"GraphQL errors: {data['errors']}")
        _audit(azp, "mark_pr_ready", repo=r, pr=int(pr_number))
        return f"PR #{pr_number} marked ready for review"
    return _tool(SCOPE_WRITE, run)


@mcp.tool(description="Get a pull request's status: state, draft, mergeable")
def get_pull_request(owner: str, repo: str, pr_number: int) -> str:
    def run(azp):
        r = _repo(owner, repo)
        pr = _api("GET", f"/repos/{r}/pulls/{int(pr_number)}")
        _audit(azp, "get_pull_request", repo=r, pr=int(pr_number))
        return (f"#{pr['number']} '{pr['title']}' state={pr['state']} draft={pr['draft']} "
                f"mergeable={pr.get('mergeable')} url={pr['html_url']}")
    return _tool(SCOPE_READ, run)


if __name__ == "__main__":
    if not SHARED_TOKEN:
        logger.warning("GITHUB_TOKEN is not set: only agents with their own githubTokenSecretRef "
                       "can call GitHub. Set the Secret named in mcp_servers_github_token_secret.")
    mcp.run(transport="sse", host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))  # nosec B104
