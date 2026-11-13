# AAA Sentinel deploy marker

Records each deployment in AAA Sentinel. A cost anomaly then lists the deployments to that cloud
account on the day of the jump and the day before, and a monitoring incident lists the deployments
of its service in the 60 minutes before it opened.

Cost data is daily, so the cost side tells you *which day's* deployments to look at, not the
minute. Monitoring incidents are per minute.

## Usage

```yaml
- name: Deploy
  run: ./deploy.sh

- name: Record the deployment in AAA Sentinel
  uses: aaa-sentinel/deploy-marker@v1
  with:
    client-id: ${{ secrets.SENTINEL_CLIENT_ID }}
    client-secret: ${{ secrets.SENTINEL_CLIENT_SECRET }}
    service: checkout-api
    environment: production
    account-id: ${{ vars.SENTINEL_ACCOUNT_ID }}            # optional
    monitoring-service-id: ${{ vars.SENTINEL_SERVICE_ID }} # optional
```

Create an OAuth app in the AAA Sentinel developer portal with the `deployments:write` scope only,
and store its client id and secret as repository or environment secrets.

## Inputs

| Input | Required | Default | |
| --- | --- | --- | --- |
| `client-id` | yes | | API app client id |
| `client-secret` | yes | | API app client secret |
| `service` | yes | | `^[a-z0-9][a-z0-9._-]{0,63}$`, e.g. `checkout-api` |
| `environment` | yes | | Same format, e.g. `production` |
| `version` | no | `github.sha` | Up to 128 characters: letters, digits and `._+-/:` |
| `commit-sha` | no | `github.sha` | 7-40 hex characters |
| `account-id` | no | | AAA Sentinel cloud account, to link cost anomalies |
| `monitoring-service-id` | no | | AAA Sentinel monitoring service, to link incidents |
| `url` | no | this workflow run | `https://` link shown next to the marker |
| `started-at` | no | time received | ISO 8601 |
| `finished-at` | no | | ISO 8601 |
| `api-url` | no | `https://api.aaa-sentinel.com` | |
| `fail-on-error` | no | `false` | See below |

## Outputs

`deployment-id`, and `duplicate` (`true` when this run attempt had already recorded it: retrying the
step does not create a second marker, while a new attempt or a later rollback to the same version does).

## Failures

A marker should never take a deployment down. Any failure (a wrong secret, a missing scope, an
invalid service name, an API that cannot be reached, a 429 or a 5xx) logs a warning with the
reason and the step succeeds; set `fail-on-error: true` to fail it instead.

The step needs `bash`, `curl` and `jq`, which every GitHub-hosted runner has. The access token is
masked in the log and only touches a temporary file that is deleted when the step ends.

## No author is sent

The marker carries no author, name or email: only what was deployed, where and when.
