#!/usr/bin/env bash

# ----------------------------------------------------------------------------
# M3BO: Munich Monarchs Mergo-BOt
#
# "THE SWEET-WARE LICENSE" (Revision 17):
# You can do whatever you want with this. If we meet some day, and you think
# this stuff is worth it, you can buy me candy in return. I love Kinder Bueno
# and sweets with coconut.
# This software comes with ABSOLUTELY NO WARRANTY and NO SUPPORT. Use it at
# YOUR OWN RISK.
#
# rafal.swierzynski@jambit.com
# ----------------------------------------------------------------------------

# Requirements:
# - BASH
# - cURL (for issuing HTTP requests)
# - jq (for JSON processing)
# - BMW_GITHUB_TOKEN env variable (for auth)

# Purpose: a PR can be merged once approved, successfully built and, in some
# repositories, if it incorporates latest changes from upstream (which is master
# most of the time). This may be an issue if upstream changes very often and the
# PR needs to be updated and built again, which may take a lot of time during
# which it is possible for upstream to change yet again, requiring the whole
# process to start over. This race condition makes merges in some repositories
# really hard, frustrating and requires checking PR state and updating it very
# often, sometimes even 20 or more times.
#
# This bot attempts to alleviate the pain. It is put into action once a PR has
# the necessary approvals and can actually be merged, just needs to be updated.
# At this point, the bot is started with the necessary arguments, repeatedly
# checks the PR state, and takes action based on it:
# 1. If the build is still ongoing but the PR still has all changes from
# upstream, it waits for a period of time and re-checks the state later.
# 2. If the build is still ongoing but upstream changed in the meantime, the
# time remaining for the build to finish is wasted as the PR must be updated
# again anyway. The bot detects this and updates the PR, causing a new build to
# start, waits for a period of time and re-checks the state later.
# 3. If the PR can be merged, it merges it using the 'squash' merging strategy
# and terminates.
# 4. An informatinve line is logged for each iteration, prefixed with date/time.
#
# As such, this bot doesn't fix the race conditions among PRs, but it does let
# humans to focus on other tasks.

# Recommendations:
# - GitHub has a limit of 5000 requests per minute
# - It is frowned upon to issue parallel requests
#
# As a result, it would be best to run only one bot locally at any given time,
# an not configure the sleep period to be less than 1 second. Failing to do so
# may result in temporary suspension of the account whose token the bot uses.

ARG_COUNT=3
if [ $# -lt "$ARG_COUNT" ]; then
  echo "I need $ARG_COUNT arguments"
  echo "Usage: $0 <repository name> <PR number> <sleep period in seconds>"
  exit 1
fi

if [ -z "$BMW_GITHUB_TOKEN" ]; then
  echo 'BMW_GITHUB_TOKEN env variable must be set'
  exit 2
fi

REPO="$1"
PR="$2"
SLEEP_PERIOD="$3"

BASE_URL="https://code.connected.bmw/api/v3/repos/mobile20/$REPO/pulls/$PR"
AUTH="Authorization: token $BMW_GITHUB_TOKEN"

echo "BASE_URL='$BASE_URL'"
echo "SLEEP_PERIOD='$SLEEP_PERIOD'"
echo

while true; do
  data="$(curl -s -H "$AUTH" "$BASE_URL")"
  mergeable_state="$(echo "$data" | jq -r .mergeable_state)"
  echo -n "[$(date)] State '$mergeable_state'"

  # mergeable_state (possibly incomplete list):
  # - behind: needs update
  # - blocked: building or not enough reviews
  # - clean: merge, quick!
  # - dirty: has conflict
  # - draft: draft
  # - null: something wrong
  # - unknown: merged or GitHub hiccup
  case "$mergeable_state" in
  behind)
    # https://developer.github.com/v3/pulls/#update-a-pull-request-branch
    echo -n ', will update branch'
    curl -f -s -X PUT \
      -H "$AUTH" \
      -H 'Accept: application/vnd.github.lydian-preview+json' \
      "$BASE_URL/update-branch"

    if [ $? -eq 0 ]; then
      echo -n ' ... done'
    else
      echo -n ' ... some error'
    fi
    echo ', will wait some more'
    ;;

  blocked)
    echo ', will wait some more'
    ;;

  clean)
    # https://developer.github.com/v3/pulls/#merge-a-pull-request-merge-button
    echo -n ', will merge'
    curl -f -s -X PUT \
      -H "$AUTH" \
      -H "Content-Type: application/json" \
      -d '{"merge_method": "squash"}' \
      "$BASE_URL/merge"

    if [ $? -eq 0 ]; then
      echo ' ... MERGED'
      exit
    fi
    echo ' ... some error, will wait some more'
    ;;

  unknown)
    # may already be merged or something else, so check
    merged="$(echo "$data" | jq -r .merged)"
    if [ "$merged" == true ]; then
      echo ', already MERGED, nothing more to do'
      exit
    fi
    echo ', state unsupported, will wait some more'
    ;;

  *)
    echo ', state unsupported, will wait some more'
    ;;
  esac

  sleep "$SLEEP_PERIOD"
done
