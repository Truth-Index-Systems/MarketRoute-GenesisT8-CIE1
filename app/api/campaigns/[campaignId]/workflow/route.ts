import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { campaignManagementService, type CampaignManagementAction } from "@/application/campaigns/service";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE, ORG_COOKIE } from "@/app/app/_lib/session";
import { sameOriginOrThrow, safeReturnPath } from "@/app/app/_lib/security";

function redirectWith(request: Request, path: string, key: string, value: string): NextResponse {
  const target = new URL(path, request.url);
  target.searchParams.set(key, value);
  return NextResponse.redirect(target, 303);
}

export async function POST(request: Request, { params }: { params: Promise<{ campaignId: string }> }) {
  const form = await request.formData();
  const { campaignId } = await params;
  const returnTo = safeReturnPath(form.get("returnTo"), `/app/campaigns/${campaignId}`);

  try {
    sameOriginOrThrow(request);
    const action = String(form.get("action") ?? "").toUpperCase() as CampaignManagementAction;
    if (!["PAUSE", "RESUME", "ARCHIVE"].includes(action)) {
      throw new Error("MARKETROUTE_CAMPAIGN_ACTION_INVALID");
    }

    const jar = await cookies();
    const accessToken = jar.get(ACCESS_COOKIE)?.value;
    if (!accessToken) throw new Error("MARKETROUTE_AUTH_REQUIRED");
    const sessions = sessionServiceFromEnvironment();
    const session = await sessions.authenticate(accessToken);
    const workspace = sessions.selectWorkspace(session, jar.get(ORG_COOKIE)?.value);
    if (!['OWNER', 'ADMIN'].includes(workspace.role)) {
      throw new Error("MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED");
    }

    await campaignManagementService().manage(accessToken, {
      organisationId: workspace.organisationId,
      campaignId,
      action,
      confirmationName: typeof form.get("confirmationName") === "string"
        ? String(form.get("confirmationName"))
        : null
    });

    if (action === "ARCHIVE") {
      return redirectWith(request, "/app/campaigns", "campaignAction", "archived");
    }
    return redirectWith(request, returnTo, "campaignAction", action === "PAUSE" ? "paused" : "resumed");
  } catch (error) {
    return redirectWith(
      request,
      returnTo,
      "actionError",
      error instanceof Error ? error.message : "MARKETROUTE_CAMPAIGN_MANAGEMENT_FAILED"
    );
  }
}
