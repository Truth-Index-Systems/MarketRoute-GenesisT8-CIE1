import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { sessionServiceFromEnvironment, type MarketRouteSession, type WorkspaceActivationStatus, type WorkspaceMembership } from "@/application/session/service";

export const ACCESS_COOKIE="mr_access_token";
export const REFRESH_COOKIE="mr_refresh_token";
export const ORG_COOKIE="mr_org_id";

export interface WorkspaceSession { session:MarketRouteSession; workspace:WorkspaceMembership; activation:WorkspaceActivationStatus; }
export async function workspaceSessionOrRedirect():Promise<WorkspaceSession>{
  const jar=await cookies(); const access=jar.get(ACCESS_COOKIE)?.value; const refresh=jar.get(REFRESH_COOKIE)?.value;
  if(!access){ if(refresh) redirect("/api/session/refresh?next=/app"); redirect("/login?next=/app"); }
  let session:MarketRouteSession|null=null;
  try{session=await sessionServiceFromEnvironment().authenticate(access);}catch{if(refresh)redirect("/api/session/refresh?next=/app");redirect("/login?next=/app");}
  if(!session)redirect("/login?next=/app");
  if(session.memberships.length===0)redirect("/onboarding");
  const service=sessionServiceFromEnvironment();
  const workspace=service.selectWorkspace(session,jar.get(ORG_COOKIE)?.value);
  const activation=await service.activationStatus(access,workspace.organisationId);
  if(activation.status==="NOT_SUBMITTED"||activation.status==="NEEDS_INPUT")redirect("/setup");
  return {session,workspace,activation};
}
