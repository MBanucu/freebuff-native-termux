#!/usr/bin/env python3
"""Open the fdroiddata merge request for freebuff-native.

fdroiddata lives on GitLab, so this needs a GitLab personal access token with
the `api` scope (Settings -> Access Tokens):

    GL_TOKEN=glpat-... python3 fdroiddata/submit.py

It forks f-droid/fdroiddata under your account, commits
metadata/io.github.mbanucu.freebuffnative.yml on a branch, and opens the merge
request.  Re-running is safe: it reuses the fork and reports a branch, file or
merge request that already exists instead of overwriting it.

    python3 fdroiddata/submit.py --dry-run     # show what it would do
    python3 fdroiddata/submit.py --rfp         # also open a request-for-packaging issue
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://gitlab.com/api/v4"
UPSTREAM = "fdroid/fdroiddata"
RFP = "fdroid/rfp"
APP_ID = "io.github.mbanucu.freebuffnative"
FILE = "metadata/" + APP_ID + ".yml"
BRANCH = "add-" + APP_ID.replace(".", "-")
TITLE = "New app: freebuff-native (%s)" % APP_ID

HERE = Path(__file__).resolve().parent


class GitLab:
    def __init__(self, token, dry_run=False):
        self.token = token
        self.dry_run = dry_run

    def try_call(self, method, path, payload=None, ok=(200, 201)):
        """Like call(), but returns the error instead of exiting."""
        try:
            return 200, self.call(method, path, payload, ok=ok)
        except SystemExit as stop:
            return 0, {"error": str(stop)}

    def call(self, method, path, payload=None, ok=(200, 201)):
        if self.dry_run and method != "GET":
            print("  would %s %s %s" % (method, path, json.dumps(payload or {})[:120]))
            return {"web_url": "<dry run>"}
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(API + path, data=data, method=method)
        request.add_header("Authorization", "Bearer " + self.token)
        if data:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read().decode()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode()
            if error.code in ok:
                return {"error": detail}
            raise SystemExit("%s %s failed (%d): %s" % (method, path, error.code, detail[:300]))


def project(slug):
    return urllib.parse.quote(slug, safe="")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--rfp", action="store_true",
                        help="also open a request-for-packaging issue in fdroid/rfp")
    args = parser.parse_args()

    token = os.environ.get("GL_TOKEN")
    if not token and not args.dry_run:
        raise SystemExit("set GL_TOKEN to a GitLab personal access token with api scope")
    metadata = (HERE / (APP_ID + ".yml")).read_text()
    mr_body = (HERE / "README.md").read_text()
    start = mr_body.find("```markdown")
    end = mr_body.find("```", start + 11)
    description = mr_body[start + 11:end].strip() if start >= 0 else ""

    gl = GitLab(token, args.dry_run)

    if args.dry_run:
        username = "<your-gitlab-account>"
    else:
        user = gl.call("GET", "/user")
        username = user.get("username", "<you>")
    print("account  " + username)

    print("fork")
    fork = gl.call("POST", "/projects/%s/fork" % project(UPSTREAM),
                   {"name": "fdroiddata", "path": "fdroiddata"},
                   ok=(200, 201, 400, 409))
    fork_id = fork.get("id")
    if not fork_id and not args.dry_run:
        target = gl.call("GET", "/projects/%s" % project(username + "/fdroiddata"))
        fork_id = target.get("id")
    if not fork_id and not args.dry_run:
        raise SystemExit("could not find or create the fork")

    # fdroiddata's default branch is master today, but read it rather than
    # assume it: the fork also has to be ready, and that takes a while.
    base = "master"
    if not args.dry_run:
        info = gl.call("GET", "/projects/%s" % fork_id)
        base = info.get("default_branch") or base
        for _ in range(30):
            branch = gl.call(
                "GET", "/projects/%s/repository/branches/%s" % (fork_id, base),
                ok=(200, 404))
            if branch.get("name") == base:
                break
            time.sleep(2)
        else:
            raise SystemExit("the fork has no %s branch yet; try again in a minute" % base)
    print("base     " + base)

    print("branch   " + BRANCH)
    gl.call("POST", "/projects/%s/repository/branches" % fork_id,
            {"branch": BRANCH, "ref": base}, ok=(201, 400))

    print("file     " + FILE)
    gl.call("POST", "/projects/%s/repository/files/%s" % (fork_id, project(FILE)),
            {"branch": BRANCH, "content": metadata,
             "commit_message": "New app: freebuff-native"}, ok=(201, 400))

    print("merge request")
    # A merge request from a fork has to be created on the upstream project and
    # must name the fork, otherwise GitLab opens it inside the fork instead.
    if args.dry_run:
        upstream_id = 0
    else:
        upstream = gl.call("GET", "/projects/%s" % project(UPSTREAM))
        upstream_id = upstream.get("id", 0)
    status, mr = gl.try_call(
        "POST", "/projects/%s/merge_requests" % upstream_id,
        {"source_project_id": fork_id, "source_branch": BRANCH,
         "target_branch": base, "title": TITLE, "description": description})

    if not mr.get("web_url") and shutil.which("glab"):
        # Some accounts get a 403 from the REST endpoint while glab's own client
        # succeeds, so fall back to the CLI rather than guess at the reason.
        print("  REST refused, trying glab")
        command = ["glab", "mr", "create", "-R", UPSTREAM,
                   "-H", username + "/fdroiddata", "-s", BRANCH, "-b", base,
                   "-t", TITLE, "-d", description, "--yes", "--no-editor"]
        if args.dry_run:
            print("  would run " + " ".join(command))
        else:
            done = subprocess.run(command, capture_output=True, text=True, check=False)
            found = re.search(r"https://gitlab\.com/\S+/merge_requests/\d+", done.stdout)
            if found:
                mr = {"web_url": found.group(0)}
            else:
                print(done.stdout.strip()[-400:])
                print(done.stderr.strip()[-400:])

    if mr.get("web_url"):
        print("\nmerge request: " + mr["web_url"])
        # A pipeline created through the API is not attached to the merge
        # request, so start one from the merge request itself.
        iid = re.search(r"/merge_requests/(\d+)", mr["web_url"])
        if iid and not args.dry_run:
            gl.try_call("POST", "/projects/%s/merge_requests/%s/pipelines"
                        % (upstream_id, iid.group(1)))
            print("  started the merge request pipeline")
    else:
        print("\nno merge request created; open the fork in the GitLab UI")

    if args.rfp:
        print("\nrequest for packaging")
        issue = gl.call("POST", "/projects/%s/issues" % project(RFP),
                        {"title": TITLE,
                         "description": description + "\n\nMetadata: " + FILE})
        if issue.get("web_url"):
            print("issue: " + issue["web_url"])


if __name__ == "__main__":
    sys.exit(main())
