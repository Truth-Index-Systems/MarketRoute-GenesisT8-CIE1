"use client";

import { useState } from "react";

interface CampaignDangerZoneProps {
  campaignId: string;
  campaignName: string;
  workflowState: string;
}

export function CampaignDangerZone({ campaignId, campaignName, workflowState }: CampaignDangerZoneProps) {
  const [archiveOpen, setArchiveOpen] = useState(false);
  const [confirmationName, setConfirmationName] = useState("");
  const returnTo = `/app/campaigns/${campaignId}`;
  const actionUrl = `/api/campaigns/${campaignId}/workflow`;
  const isPaused = workflowState === "PAUSED";

  function closeArchive() {
    setArchiveOpen(false);
    setConfirmationName("");
  }

  return <>
    <section className="mr-campaign-controls" aria-labelledby="campaign-controls-title">
      <header>
        <span>CAMPAIGN CONTROLS</span>
        <h2 id="campaign-controls-title">Manage this campaign</h2>
        <p>Pause new work temporarily, or remove the campaign from normal workspace views.</p>
      </header>

      <div className="mr-campaign-control-row">
        <div>
          <strong>{isPaused ? "Resume campaign" : "Pause campaign"}</strong>
          <p>{isPaused
            ? "Allow Genesis to claim new research work for this campaign again."
            : "Stop Genesis from claiming new research work. Work already in flight may finish safely."}</p>
        </div>
        <form method="post" action={actionUrl}>
          <input type="hidden" name="action" value={isPaused ? "RESUME" : "PAUSE"}/>
          <input type="hidden" name="returnTo" value={returnTo}/>
          <button className={`mr-button ${isPaused ? "mr-button--primary" : "mr-button--warning"}`} type="submit">
            {isPaused ? "Resume campaign" : "Pause campaign"}
          </button>
        </form>
      </div>

      <div className="mr-campaign-control-row mr-campaign-control-row--danger">
        <div>
          <strong>Delete campaign</strong>
          <p>Archive this campaign and hide it from normal views. Evidence, opportunities, engagement history and audit lineage are retained.</p>
        </div>
        <button className="mr-button mr-button--danger-outline" type="button" onClick={() => setArchiveOpen(true)}>
          Delete campaign
        </button>
      </div>
    </section>

    {archiveOpen ? <div className="mr-modal-backdrop" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget) closeArchive();
    }}>
      <section className="mr-modal-dialog" role="dialog" aria-modal="true" aria-labelledby="archive-campaign-title">
        <span className="mr-modal-dialog__eyebrow">DANGER ZONE</span>
        <h2 id="archive-campaign-title">Delete {campaignName}?</h2>
        <p>This archives the campaign rather than erasing its records. It will disappear from campaign lists and Genesis will stop claiming new work.</p>
        <p>To confirm, type <strong>{campaignName}</strong> exactly.</p>
        <form method="post" action={actionUrl}>
          <input type="hidden" name="action" value="ARCHIVE"/>
          <input type="hidden" name="returnTo" value={returnTo}/>
          <label htmlFor="campaign-confirmation-name">Campaign name</label>
          <input
            id="campaign-confirmation-name"
            name="confirmationName"
            type="text"
            value={confirmationName}
            onChange={(event) => setConfirmationName(event.target.value)}
            autoComplete="off"
            autoFocus
          />
          <div className="mr-modal-dialog__actions">
            <button className="mr-button mr-button--secondary" type="button" onClick={closeArchive}>Cancel</button>
            <button className="mr-button mr-button--danger" type="submit" disabled={confirmationName !== campaignName}>
              Delete this campaign
            </button>
          </div>
        </form>
      </section>
    </div> : null}
  </>;
}
