import { AuthenticatedRpcClient } from "../../platform/database/authenticated-rpc";

export type CampaignManagementAction = "PAUSE" | "RESUME" | "ARCHIVE";
export type CampaignWorkflowState = "ACTIVE" | "PAUSED" | "ARCHIVED";

export interface CampaignManagementResult {
  campaignId: string;
  action: CampaignManagementAction;
  workflowState: CampaignWorkflowState;
  deduplicated: boolean;
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("MARKETROUTE_CAMPAIGN_MANAGEMENT_INVALID_RESPONSE");
  }
  return value as Record<string, unknown>;
}

export class CampaignManagementService {
  constructor(private readonly rpc = new AuthenticatedRpcClient()) {}

  async manage(accessToken: string, input: {
    organisationId: string;
    campaignId: string;
    action: CampaignManagementAction;
    confirmationName?: string | null;
  }): Promise<CampaignManagementResult> {
    const organisationId = input.organisationId.trim();
    const campaignId = input.campaignId.trim();
    if (!organisationId || !campaignId) throw new Error("MARKETROUTE_CAMPAIGN_SCOPE_REQUIRED");
    if (!["PAUSE", "RESUME", "ARCHIVE"].includes(input.action)) {
      throw new Error("MARKETROUTE_CAMPAIGN_ACTION_INVALID");
    }

    const value = object(await this.rpc.call<unknown>(accessToken, "marketroute_manage_campaign_v1", {
      p_organisation_id: organisationId,
      p_campaign_id: campaignId,
      p_action: input.action,
      p_confirmation_name: input.confirmationName ?? null
    }));
    const action = String(value.action ?? "") as CampaignManagementAction;
    const workflowState = String(value.workflowState ?? "") as CampaignWorkflowState;
    if (String(value.campaignId ?? "") !== campaignId
      || !["PAUSE", "RESUME", "ARCHIVE"].includes(action)
      || !["ACTIVE", "PAUSED", "ARCHIVED"].includes(workflowState)) {
      throw new Error("MARKETROUTE_CAMPAIGN_MANAGEMENT_INVALID_RESPONSE");
    }

    return {
      campaignId,
      action,
      workflowState,
      deduplicated: value.deduplicated === true
    };
  }
}

export function campaignManagementService(): CampaignManagementService {
  return new CampaignManagementService();
}
