#!/usr/bin/env bash
# =============================================================================
# Add a reaction to an issue comment
# =============================================================================
#
# USAGE
#   .github/scripts/react.sh <comment_id> <reaction>
#
# Where <reaction> is one of the GitHub reaction content values:
#   +1 | -1 | laugh | confused | heart | hooray | rocket | eyes
#
# CONVENTIONS (this project)
#   eyes       — workflow started, working on it
#   +1         — workflow finished successfully
#   confused   — workflow failed
#
# Silent when comment_id is empty or zero (e.g. workflow_dispatch runs with
# no trigger comment). Failures to post are logged as notices, never errors —
# a missing reaction shouldn't fail a whole workflow.
#
# REQUIRED ENV
#   GH_TOKEN             A GitHub token with issues:write
#   GITHUB_REPOSITORY    owner/name (automatically set in GitHub Actions)
# =============================================================================

set -euo pipefail

COMMENT_ID="${1:-}"
REACTION="${2:-eyes}"

if [[ -z "$COMMENT_ID" ]] || [[ "$COMMENT_ID" == "0" ]]; then
  echo "::notice::No comment_id provided — skipping '$REACTION' reaction" >&2
  exit 0
fi

if gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/comments/${COMMENT_ID}/reactions" \
    -f "content=${REACTION}" --silent 2>/dev/null; then
  echo "Added '$REACTION' reaction to comment $COMMENT_ID"
else
  echo "::notice::Failed to add '$REACTION' reaction to comment $COMMENT_ID" >&2
fi
