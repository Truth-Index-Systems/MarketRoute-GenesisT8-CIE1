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
        <span>MARKET CONTROLS</span>
        <h2 id="campaign-controls-title">Manage this market</h2>
        <p>Pause new research temporarily, or remove this market from normal workspace views.</p>
      </header>

      <div className="mr-campaign-control-row">
        <div>
          <strong>{isPaused ? "Resume market" : "Pause market"}</strong>
          <p>{isPaused
            ? "Let MarketRoute continue researching this market."
            : "Pause new research for this market. Work already under way may finish safely."}</p>
        </div>
        <form method="post" action={actionUrl}>
          <input type="hidden" name="action" value={isPaused ? "RESUME" : "PAUSE"}/>
          <input type="hidden" name="returnTo" value={returnTo}/>
          <button className={`mr-button ${isPaused ? "mr-button--primary" : "mr-button--warning"}`} type="submit">
            {isPaused ? "Resume market" : "Pause market"}
          </button>
        </form>
      </div>

      <div className="mr-campaign-control-row mr-campaign-control-row--danger">
        <div>
          <strong>Remove market</strong>
          <p>Hide this market from normal views. Its companies, opportunities, outreach history and audit trail are kept safely.</p>
        </div>
        <button className="mr-button mr-button--danger-outline" type="button" onClick={() => setArchiveOpen(true)}>
          Remove market
        </button>
      </div>
    </section>

    {archiveOpen ? <div className="mr-modal-backdrop" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget) closeArchive();
    }}>
      <section className="mr-modal-dialog" role="dialog" aria-modal="true" aria-labelledby="archive-campaign-title">
        <span className="mr-modal-dialog__eyebrow">DANGER ZONE</span>
        <h2 id="archive-campaign-title">Remove {campaignName}?</h2>
        <p>This archives the market rather than erasing it. It disappears from your market list and MarketRoute stops new research for it.</p>
        <p>To confirm, type <strong>{campaignName}</strong> exactly.</p>
        <form method="post" action={actionUrl}>
          <input type="hidden" name="action" value="ARCHIVE"/>
          <input type="hidden" name="returnTo" value={returnTo}/>
          <label htmlFor="campaign-confirmation-name">Market name</label>
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
              Remove this market
            </button>
          </div>
        </form>
      </section>
    </div> : null}
  </>;
}
