---
name: Implementation task
about: Dispatch an implementation task to Claude Code
title: ""
labels: ["automation"]
assignees: ""
---

## What to implement

<!-- Describe the change in plain English. Be specific about which files,
     which behavior, and what the end state looks like. -->


## Acceptance criteria

<!-- Checklist of what "done" looks like. Claude Code uses this to verify. -->

- [ ] 

## Constraints

<!-- Anything Claude Code should NOT do, or boundaries to stay within. -->

- Do not add dependencies beyond bash, docker, curl, redis-cli, ssh
- Do not hardcode secrets — use environment variables via .env
- All persistent files must live under /home/pi/.firewalla/config/
- Keep RAM budget under ~50 MB for the pipeline
- Do not modify unrelated code

## Auto-merge

When implementation is complete:
1. Run `shellcheck --severity=warning --shell=bash` on all modified `.sh` scripts
2. Create a PR with a clear title and description referencing this issue
3. Enable auto-merge: `gh pr merge --auto --squash`

@claude implement this
