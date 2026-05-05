# env0 Pending Approval Resolver

## Problem

When a deployment is sitting in **Pending Approval** and a developer pushes a new commit, env0's continuous deployment triggers a new deployment run. However, that new run gets stuck in a **Queued** state — it cannot proceed because there is already an unresolved pending approval blocking the queue for that environment.

The result: the stale pending approval sits there indefinitely, blocking all subsequent deployments unless someone manually cancels it. This is especially painful across large organizations with many environments.

---

## Solution

This project is a **no-op env0 deployment that runs on a 15-minute schedule**. It does not deploy any real infrastructure. Its only job is to run a shell script (via a custom flow task) that:

1. Scans all environments in the organization (or a single project for testing)
2. Identifies environments where **both** of the following are true at the same time:
   - There is a deployment in `WAITING_FOR_USER` (pending approval)
   - There is at least one deployment in `QUEUED`
3. Cancels the blocking `WAITING_FOR_USER` deployment
4. If there are multiple `QUEUED` deployments, cancels all but the **most recent** one
5. Once the blocker is cancelled, env0 automatically promotes the most recent `QUEUED` deployment — which then enters `WAITING_FOR_USER` (pending approval) itself, ready for a fresh review

The custom flow task runs **before** the Terraform no-op `apply`, meaning if the script fails (e.g. bad API key, network error), the entire deployment is marked **FAILED** in env0. This ensures errors are visible and not silently swallowed.

---

## How It Works — Step by Step

```
Every 15 minutes:
│
├─ env0 triggers a scheduled deployment on this project
│
├─ Custom flow task: "Resolve Pending Approvals"
│   │
│   ├─ Fetch all environments (paginated, 100 per page)
│   │
│   └─ For each environment:
│       │
│       ├─ Fetch last 20 deployments
│       │
│       ├─ Check: WAITING_FOR_USER count > 0?    ─┐
│       ├─ Check: QUEUED count > 0?               ─┤─ Both must be true (AND)
│       │                                          ─┘
│       ├─ If yes:
│       │   ├─ If multiple QUEUED → cancel all except most recent
│       │   └─ Cancel all WAITING_FOR_USER deployments
│       │
│       └─ If no → skip, no action taken
│
├─ Print full summary:
│   - How many environments were checked
│   - How many were actioned
│   - How many deployments were cancelled
│   - Exact environment name and deployment ID for every cancellation
│
└─ Terraform no-op apply runs (outputs a status message, does nothing else)
```

---

## Deployment Status Reference

| Status | Meaning |
|---|---|
| `WAITING_FOR_USER` | Deployment is pending manual approval |
| `QUEUED` | Deployment is queued, waiting for the current one to finish |
| `IN_PROGRESS` | Deployment is actively running |
| `SUCCESS` | Deployment completed successfully |
| `FAILED` | Deployment failed |
| `CANCELLED` | Deployment was cancelled |

This script only reads `WAITING_FOR_USER` and `QUEUED` statuses. All other statuses are ignored.

---

## File Structure

```
env0-pending-approval-resolver/
├── main.tf                                    # No-op Terraform (outputs status message only)
├── env0.yml                                   # Custom flow — runs the script before apply
├── scripts/
│   ├── check-pending-approvals-org.sh         # Production: scans entire organization
│   └── check-pending-approvals-project.sh     # Testing: scans a single project only
└── README.md
```

---

## Setup Instructions

### 1. Create a new env0 project

- In the env0 UI, create a new project (e.g. `pending-approval-resolver`)
- Create a new environment inside it (e.g. `resolver`)
- Point it at this repository

### 2. Set the template type

- Template type: **Terraform**
- Terraform version: **1.0.0** or higher
- Workspace: leave as default

### 3. Configure environment variables

Go to the environment's **Configuration Variables** and add the following:

#### For production (org-level scan):

| Variable | Value | Sensitive? |
|---|---|---|
| `ENV0_API_KEY` | Your env0 API key | ✅ Yes — mark as sensitive |
| `ENV0_ORGANIZATION_ID` | Your env0 organization ID | No |

#### For testing (project-level scan):

| Variable | Value | Sensitive? |
|---|---|---|
| `ENV0_API_KEY` | Your env0 API key | ✅ Yes — mark as sensitive |
| `ENV0_PROJECT_ID` | The project ID you want to test against | No |

> **How to find your Organization ID:** Go to env0 Settings → Organization → copy the ID from the URL or the settings page.
>
> **How to find your Project ID:** Go to the project in env0 — it's in the URL: `app.env0.com/p/{projectId}/...`

### 4. Enable the custom flow

- In the environment settings, make sure **Custom Flow** is enabled and pointing to `env0.yml` in the root of this repo

### 5. Set up the schedule

- In the environment settings, go to **Scheduling**
- Add a **Deploy** schedule with a cron expression for every 15 minutes:

```
*/15 * * * *
```

### 6. Select the correct script

- By default, `env0.yml` runs `check-pending-approvals-org.sh` (org-level)
- To test against a single project first, edit `env0.yml` and change the command to `check-pending-approvals-project.sh`
- Once you're satisfied with testing, switch back to `check-pending-approvals-org.sh`

---

## Testing

Before enabling the org-level script in production:

1. Set `ENV0_PROJECT_ID` to the ID of a test project you control
2. In `env0.yml`, change the command to `check-pending-approvals-project.sh`
3. Manually trigger a deployment of the resolver environment
4. Review the task logs — you'll see every environment checked, the deployment statuses found, and any actions taken
5. The project-level script outputs **all deployment statuses** for every environment (not just the relevant ones), which is useful for verifying the status names are correct in your env0 instance

Once confirmed working, switch to `check-pending-approvals-org.sh` and set `ENV0_ORGANIZATION_ID`.

---

## Reading the Logs

When the script runs, every deployment in the org is printed in this format:

```
┌─ [3/47] my-environment-name
│  Project    : my-project (abc-123)
│  Env ID     : xyz-456
│  Pending Approval (WAITING_FOR_USER) : 1
│  Queued (QUEUED)                     : 1
│
│  ⚠  BOTH conditions met — taking action
│  Cancelling 1 pending approval deployment(s)...
│    → Cancelling deployment: ba8e1b32-2717-4512-a7ae-cb034fb3b978
│      Reason              : Pending approval superseded by a newer queued deployment
│    ✓ Cancelled successfully
│
└─ ✓ Done. Most recent queued deployment will auto-trigger.
```

At the end, a full summary is printed:

```
========================================================================
  SUMMARY
========================================================================
  Total environments checked:         47
  Environments actioned:              2
  Total deployments cancelled:        3

  Actions taken:
    • ENV: my-environment-name | Deployment ID: ba8e1b32-... | Reason: Pending approval superseded by a newer queued deployment
    • ENV: another-environment | Deployment ID: 9c3d2f11-... | Reason: Pending approval superseded by a newer queued deployment
    • ENV: another-environment | Deployment ID: 4e7a1b09-... | Reason: Older queued deployment — superseded by a more recent queued deployment

  Completed at: 2024-01-15 14:30:00 UTC
========================================================================
```

---

## Multiple Queued Deployments

If an environment has more than one `QUEUED` deployment (e.g. 3 commits came in quickly while approval was pending), the script handles it like this:

```
QUEUED deployments (newest to oldest):
  [0] commit-3 ← KEEP THIS ONE
  [1] commit-2 ← cancel
  [2] commit-1 ← cancel

WAITING_FOR_USER:
  [0] original-deploy ← cancel
```

Only the most recent queued deployment survives and gets promoted once the blocker is cleared.

> **Note:** The deployments list is assumed to be returned **newest-first** by the env0 API. If you observe unexpected behaviour (e.g. the wrong queued deployment is being kept), verify the sort order of `GET /environments/{id}/deployments` in your env0 instance and swap `.[1:]` to `.[:-1]` in the script if needed.

---

## Error Handling

- The script uses `set -euo pipefail` — any unhandled error immediately exits with a non-zero code
- A non-zero exit code causes the env0 deployment to be marked **FAILED**
- This ensures API failures, auth errors, or unexpected responses are visible in the env0 UI rather than silently passing
- Temp files used during the run are cleaned up automatically via a `trap` on EXIT, even if the script fails midway

---

## API Reference

| Action | Method | Endpoint |
|---|---|---|
| List environments (org) | `GET` | `/environments?organizationId={orgId}&limit=100&offset=0` |
| List environments (project) | `GET` | `/environments?projectId={projectId}&limit=100&offset=0` |
| List deployments | `GET` | `/environments/{environmentId}/deployments?limit=20` |
| Cancel a deployment | `PUT` | `/environments/deployments/{deploymentId}/cancel` |

Authentication: **Basic Auth** — API key as the username, empty password.

```bash
curl -X PUT \
  -H "Accept: application/json" \
  --user "<your-api-key>:" \
  "https://api.env0.com/environments/deployments/{deploymentId}/cancel"
```

---

## Limitations & Known Considerations

- **Approval history is lost:** When the `WAITING_FOR_USER` deployment is cancelled, the original approval request is discarded. The newly promoted `QUEUED` deployment will start a fresh approval cycle.
- **15-minute window:** There is up to a 15-minute delay between a deployment getting stuck and this resolver running. This is acceptable for most workflows but can be reduced by changing the cron schedule.
- **Assumes newest-first API ordering:** The script treats index `[0]` of the deployments list as the most recent. If env0 changes the sort order, adjust accordingly (see Multiple Queued Deployments section above).
- **Environments in other active states are not touched:** The script only cancels `WAITING_FOR_USER` and excess `QUEUED` deployments. Environments with `IN_PROGRESS` deployments are left alone.
