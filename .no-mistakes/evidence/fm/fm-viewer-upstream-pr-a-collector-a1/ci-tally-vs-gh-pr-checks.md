# fm-flow-snapshot.sh check tally vs the real `gh pr checks`, PR cli/cli#14640

## Collector (bin/fm-flow-snapshot.sh --task ship-live, real gh, disposable FM_HOME)
total=20 passed=11 failed=1 pending=0 skipped=8 head=6ea10e3fa9998797e9ccea325272b9d9c02e0993 pr_state=OPEN

## gh pr checks 14640 --repo cli/cli
fail=1
pass=11
skipping=8
total=20

## per-check agreement (collector verdict | gh status | name)
IDENTICAL: every check name carries the same class in both tools

  failed|failed|govulncheck
  passed|passed|CodeQL
  passed|passed|CodeQL-Build (actions, none, security-and-quality)
  passed|passed|CodeQL-Build (go, manual, ./.github/codeql/codeql-config.yml)
  passed|passed|build (macos-latest)
  passed|passed|build (ubuntu-latest)
  passed|passed|build (windows-latest)
  passed|passed|integration-tests (macos-latest)
  passed|passed|integration-tests (ubuntu-latest)
  passed|passed|integration-tests (windows-latest)
  passed|passed|label-external / label_issues
  passed|passed|lint
  skipped|skipped|check-requirements / check-requirements
  skipped|skipped|check-requirements / close-unmet-requirements
  skipped|skipped|close-from-default-branch
  skipped|skipped|close-from-default-branch / close-from-default-branch
  skipped|skipped|close-no-help-wanted
  skipped|skipped|close-unmet-requirements
  skipped|skipped|label-external
  skipped|skipped|ready-for-review
