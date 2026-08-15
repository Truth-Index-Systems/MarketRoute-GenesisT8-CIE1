# MarketRoute V2 — Campaign progress polling hotfix 0.18.3.17

## Outcome

Campaign preparation remains visibly live without repeatedly refreshing the full `/app` route.

The previous progress component called `router.refresh()` every 2.2 seconds. That re-ran server components and session resolution and, near access-token expiry, produced bursts of `/app`, `/app/campaigns`, and `/api/session/refresh` requests.

## Changes

- Adds a small authenticated `GET /api/campaigns/activation-status` JSON endpoint.
- Polls only while an activation is still working: every 12 seconds while queued, every 3 seconds while running, and every 30 seconds when a retry is scheduled.
- Defers polling while the browser tab is hidden.
- Updates the progress component locally for intermediate stages.
- Calls `router.refresh()` once when activation reaches a terminal state, so the completed campaign page is rendered.
- Guards token refresh so a mounted progress view can start it only once.
- Deduplicates repeated workspace-session reads inside one React server render.

## Deployment

Deploy this package to Vercel. Do not run new SQL for this release. Supabase migration `0036_campaign_activation_progress_ui.sql` from 0.18.3.16 must already be applied.
