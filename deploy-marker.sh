#!/usr/bin/env bash
# Records a deployment marker in AAA Sentinel. Shared logic of the GitHub Action; the GitLab component inlines the same steps.
# A marker must never take a deployment down: every failure is a warning unless FAIL_ON_ERROR=true.
set -uo pipefail

api_url="${API_URL:-https://api.aaa-sentinel.com}"
api_url="${api_url%/}"
fail_on_error="$(printf '%s' "${FAIL_ON_ERROR:-false}" | tr '[:upper:]' '[:lower:]')"
in_github="${GITHUB_ACTIONS:-false}"

log_error() { if [ "$in_github" = "true" ]; then echo "::error title=AAA Sentinel deploy marker::$1"; else echo "ERROR: $1" >&2; fi; }
log_warning() { if [ "$in_github" = "true" ]; then echo "::warning title=AAA Sentinel deploy marker::$1"; else echo "WARNING: $1" >&2; fi; }

# No failure of the marker fails the job unless the caller asked for it: a billing change or a revoked app must not stop deployments.
transient() {
  if [ "$fail_on_error" = "true" ]; then log_error "$1"; exit 1; fi
  log_warning "$1 The deployment continues without a marker."
  exit 0
}

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required on the runner."; exit 1; }
done

for name in SENTINEL_CLIENT_ID SENTINEL_CLIENT_SECRET SERVICE ENVIRONMENT VERSION; do
  if [ -z "${!name:-}" ]; then log_error "missing input: $name"; exit 1; fi
done

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Prints the HTTP status ("000" when the request never got an answer); the body lands in $workdir/body.
request() {
  curl -sS --max-time 20 --retry 2 --retry-delay 2 --retry-connrefused \
    -o "$workdir/body" -w '%{http_code}' "$@" 2>"$workdir/curl.err" || true
}

error_detail() {
  jq -r '[.code // empty, .error // empty, .message // empty] | join(": ")' "$workdir/body" 2>/dev/null | head -c 300
}

token_request="$(jq -n --arg id "$SENTINEL_CLIENT_ID" --arg secret "$SENTINEL_CLIENT_SECRET" \
  '{grant_type: "client_credentials", client_id: $id, client_secret: $secret, scope: "deployments:write"}')"
status="$(printf '%s' "$token_request" | request -X POST "$api_url/v1/oauth/token" -H 'content-type: application/json' --data-binary @-)"

case "$status" in
  200) ;;
  000) transient "could not reach $api_url ($(tail -n 1 "$workdir/curl.err" | head -c 200))." ;;
  429 | 5??) transient "the token request answered HTTP $status." ;;
  *) transient "the token request was rejected (HTTP $status $(error_detail)). Check the client id, the secret and that the app has the deployments:write scope." ;;
esac

token="$(jq -r '.access_token // empty' "$workdir/body")"
[ -n "$token" ] || transient "the token response carried no access_token."
[ "$in_github" = "true" ] && echo "::add-mask::$token"

# Empty optional inputs are left out, so the API applies its own defaults.
payload="$(jq -n \
  --arg service "$SERVICE" --arg environment "$ENVIRONMENT" --arg version "$VERSION" \
  --arg commitSha "${COMMIT_SHA:-}" --arg accountId "${ACCOUNT_ID:-}" --arg runId "${RUN_ID:-}" \
  --arg monitoringServiceId "${MONITORING_SERVICE_ID:-}" --arg url "${DEPLOY_URL:-}" \
  --arg startedAt "${STARTED_AT:-}" --arg finishedAt "${FINISHED_AT:-}" \
  '{service: $service, environment: $environment, version: $version, runId: $runId, commitSha: $commitSha, accountId: $accountId,
    monitoringServiceId: $monitoringServiceId, url: $url, startedAt: $startedAt, finishedAt: $finishedAt}
   | with_entries(select(.value != ""))')"

status="$(printf '%s' "$payload" | request -X POST "$api_url/v1/deployments" \
  -H "authorization: Bearer $token" -H 'content-type: application/json' --data-binary @-)"

case "$status" in
  200 | 201) ;;
  000) transient "could not reach $api_url ($(tail -n 1 "$workdir/curl.err" | head -c 200))." ;;
  429 | 5??) transient "recording the deployment answered HTTP $status." ;;
  *) transient "the deployment was rejected (HTTP $status $(error_detail))." ;;
esac

deployment_id="$(jq -r '.deployment.deploymentId // empty' "$workdir/body")"
duplicate="$(jq -r '.duplicate // false' "$workdir/body")"
if [ "$duplicate" = "true" ]; then
  echo "Deployment marker already recorded: $deployment_id ($SERVICE $VERSION on $ENVIRONMENT)."
else
  echo "Deployment marker recorded: $deployment_id ($SERVICE $VERSION on $ENVIRONMENT)."
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "deployment-id=$deployment_id"; echo "duplicate=$duplicate"; } >>"$GITHUB_OUTPUT"
fi
