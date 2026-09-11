# Self-hosted runner operations

The repository runner is named `Harleys-Mac-WHOOP` and has the custom label
`whoop-ci` in addition to GitHub's automatic `self-hosted`, `macOS`, and `ARM64`
labels. It is installed as a per-user macOS LaunchAgent from
`~/.local/share/whoop-actions-runner`, so it starts for the signed-in user and
the runner updates itself.

Check local and GitHub-visible status with:

```bash
cd ~/.local/share/whoop-actions-runner
./svc.sh status
gh api repos/harleyhzhang/whoop-ios/actions/runners
```

The runner must remain repository-scoped. Do not share its label with another
repository, grant workflow write permissions, add secrets to the job, or switch
the pull-request trigger away from `pull_request_target`. The trusted workflow
definition checks the actor before it checks out proposed code and checkout does
not persist GitHub credentials.

If the runner is intentionally removed, first stop and uninstall its service,
then remove it in the repository's Actions settings. Registration tokens are
short-lived secrets: obtain one only during registration and never save or log
it.

Self-hosted runner use does not consume GitHub-hosted Actions minutes. The
manual `iOS CI` workflow is the only path that can consume paid hosted macOS
minutes.
