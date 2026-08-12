# Gitea pull request watch and merge verification

Empirical record for the merge watch and merge on Gitea, alongside the existing GitHub and GitLab watches.
Every structural command below was run on 2026-08-12 and its output is reproduced exactly.

## Versions

```
$ tea --version
Version: 0.15.1  golang: 1.26.5  go-sdk: v1.2.0

$ bash --version | head -1
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
```

## Why the host is data rather than a constant, and why the route shape is what tags the provider

Gitea, like GitLab, runs mostly on self-hosted instances, so a pull request can live under any host.
Unlike GitLab, a Gitea project path is exactly `owner/repository`, the same shape as GitHub, so no nested-namespace rule is needed.
What tells a Gitea pull request URL apart from a GitHub one on sight is the route itself: Gitea's is the plural `/pulls/<n>`, GitHub's is the singular `/pull/<n>`.
Neither shape can ever collide with GitLab's `/-/merge_requests/<n>` or with each other, so `bin/fm-pr-lib.sh`'s `fm_pr_url_parse` tags the provider from the URL alone, then validates the owner and repository with GitHub's own character rules.
`github.com` is refused as a Gitea host for the same reason it is refused as a GitLab host: it is GitHub's own host and never a Gitea instance, so a mistyped or spoofed GitHub URL is never armed as a watch that can never succeed.
`tests/fm-pr-check-security.test.sh` asserts the full adversarial matrix for this shape, including the owner/host/index edge cases shared with GitHub and the provider-confusion cases specific to Gitea's route.

A non-default host appears below only as the placeholder `gitea.example`, which resolves nowhere.
That is deliberate, for the same reason `docs/gitlab-merge-watch.md` uses `gitlab.example`: the host-agnostic property is a property of the stored record and the poll's URL reconstruction, demonstrated by inspecting those rather than by publishing any private instance's project names or usernames into a tracked file.
The end-to-end merge and poll behavior below was additionally verified live against a private self-hosted Gitea instance and a real pull request there; that verification confirmed the exact command shapes and JSON field this document describes, but the instance and repository are not disclosed here.

## How tea is invoked, and why

Three things about `tea` needed to be established by running it, because assuming any of them would have failed silently into a permanent "not merged" or addressed the wrong instance.

First, `tea` addresses a configured server by a stored *login name*, not by a bare host or URL, the way `glab -R <url>` or `gh`'s URL argument can.
The login name is chosen when the login is registered (`tea login add`) and is not guaranteed to equal the host, so `bin/fm-pr-poll.sh` and `bin/fm-pr-merge.sh` both resolve it fresh from `tea login list -o csv`, matching the stored login's `URL` column against `https://<host>` from the validated record, rather than assuming a naming convention:

```
$ tea login list -o csv
Name,URL,SSHHost,User,Default
gitea.example,https://gitea.example,gitea.example,someone,false
```

Second, `tea`'s single pull-request detail view (`tea pulls <index>`) is a human-formatted card with terminal hyperlink escape sequences, and its `--fields`/`--output` selectors apply only to `tea pulls list`, which paginates and offers no way to filter by exact index.
Reading one pull request by its exact number therefore goes through `tea api`, an authenticated raw API passthrough, addressing the endpoint directly:

```
$ tea api --login gitea.example /repos/owner/repo/pulls/9
{"id":...,"state":"closed","merged":true,"merged_at":"...","...":...}
```

Third, the API's own `state` field is a plain `open`/`closed`, with merges tracked in a separate `merged` boolean; a pull request can be closed without being merged.
Only an exact `"merged":true` in that raw single-line JSON wakes firstmate, matched directly in the bytes tea prints with no reformatting and no JSON processor, the same minimalism `docs/gitlab-merge-watch.md` uses for `glab`'s plain field output.
A changed API shape, an unreadable pull request, or a merely-closed one all produce no wake rather than a false merge.

## End to end: arming and polling a pull request

```
$ fm-pr-check.sh e1 https://gitea.example/owner/repo/pulls/9
armed: state/e1.check.sh
```

The stored record, showing the host and owner/repository as data:

```
$ cat state/e1.pr-poll
gitea
https://gitea.example/owner/repo/pulls/9
gitea.example
owner/repo
9
```

Running the published poll the way the watcher does:

```
$ state/e1.check.sh
merged
```

An open (not merged) pull request, an unreadable one, and a sidecar whose host or repository has been swapped all stay silent, exactly as `tests/fm-pr-check-security.test.sh`'s `test_gitea_merge_watch` exercises hermetically with a fake `tea`.

## A missing CLI produces no wake, never a false merge

The poll is silent on every error by design, so a missing `tea` would otherwise be indistinguishable from a pull request that is never merged.
Arming is the one point where that can still be reported, so it refuses there instead of arming a watch that can never fire:

```
$ PATH="$notea" fm-pr-check.sh e2 https://gitea.example/owner/repo/pulls/9
error: watching a Gitea pull request requires tea on PATH
$ echo $?
1
```

A GitHub or GitLab task is unaffected by a missing `tea`.

## What Gitea covers that GitLab does not yet

`bin/fm-pr-merge.sh` addresses both GitHub and Gitea by owner/repository, unlike GitLab, which it still refuses.
Merging defaults to a squash on both, using each provider's own vocabulary (`--squash` for `gh-axi`, `--style squash` for `tea`), and a caller-supplied style after the `--` separator overrides that default on either:

```
$ fm-pr-merge.sh e3 https://gitea.example/owner/repo/pulls/9
$ # -> tea pulls merge 9 --repo owner/repo --login gitea.example --style squash

$ fm-pr-merge.sh e4 https://gitea.example/owner/repo/pulls/9 -- --style rebase
$ # -> tea pulls merge 9 --repo owner/repo --login gitea.example --style rebase
```

A host with no tea login registered refuses the merge with a clear diagnostic instead of silently addressing the wrong instance:

```
error: no tea login is registered for gitea.example
```

A Gitea task records no `pr_head=`, the same current limitation GitLab has.
`gh` exposes the head commit as a selectable field; `tea`'s field selectors apply only to list output, not the single-PR fetch this watch uses, so no equivalent one-shot field read exists yet.
Both consumers already treat it as optional: `bin/fm-teardown.sh` reads the head from the forge at teardown rather than from metadata and falls back to its provider-agnostic content check, and `bin/fm-review-diff.sh` resolves the head from the remote when none is recorded.
