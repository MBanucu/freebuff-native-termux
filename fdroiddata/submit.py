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
                   {"name": "fdroiddata", "path": "fdroiddata"}, ok=(200, 201, 400))
    fork_id = fork.get("id")
    if not fork_id and not args.dry_run:
        target = gl.call("GET", "/projects/%s" % project(username + "/fdroiddata"))
        fork_id = target.get("id")
    if not fork_id and not args.dry_run:
        raise SystemExit("could not find or create the fork")

    if not args.dry_run:
        for _ in range(30):
            branch = gl.call("GET", "/projects/%s/repository/branches/master" % fork_id,
                             ok=(200, 404))
            if branch.get("name") == "master":
                break
            time.sleep(2)
        else:
            raise SystemExit("the fork has no master branch yet; try again in a minute")

    print("branch   " + BRANCH)
    gl.call("POST", "/projects/%s/repository/branches" % fork_id,
            {"branch": BRANCH, "ref": "master"}, ok=(201, 400))

    print("file     " + FILE)
    gl.call("POST", "/projects/%s/repository/files/%s" % (fork_id, project(FILE)),
            {"branch": BRANCH, "content": metadata,
             "commit_message": "New app: freebuff-native"}, ok=(201, 400))

    print("merge request")
    mr = gl.call("POST", "/projects/%s/merge_requests" % fork_id,
                 {"source_branch": BRANCH, "target_branch": "master",
                  "title": TITLE, "description": description,
                  "remove_source_branch": True}, ok=(201, 409))
    if mr.get("web_url"):
        print("\nmerge request: " + mr["web_url"])
    else:
        print("\nthe merge request may already exist; open it in the GitLab UI")

    if args.rfp:
        print("\nrequest for packaging")
        issue = gl.call("POST", "/projects/%s/issues" % project(RFP),
                        {"title": TITLE,
                         "description": description + "\n\nMetadata: " + FILE})
        if issue.get("web_url"):
            print("issue: " + issue["web_url"])


if __name__ == "__main__":
    sys.exit(main())
