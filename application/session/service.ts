import { supabaseAuthClientFromEnvironment, type SupabaseAuthSession, type AuthenticatedUser } from "../../platform/auth/supabase-auth";
import { workspaceRepositoryFromEnvironment, type WorkspaceMembership } from "../../platform/database/workspace-repository";
import { AuthenticatedRpcClient } from "../../platform/database/authenticated-rpc";
export type { WorkspaceMembership } from "../../platform/database/workspace-repository";

export interface MarketRouteSession {
  user:AuthenticatedUser;
  memberships:WorkspaceMembership[];
}
export class SessionService {
  private readonly auth=supabaseAuthClientFromEnvironment();
  private readonly workspace=workspaceRepositoryFromEnvironment();
  async signIn(email:string,password:string):Promise<{auth:SupabaseAuthSession;session:MarketRouteSession}>{
    if(!email.trim()||!password)throw new Error("MARKETROUTE_LOGIN_CREDENTIALS_REQUIRED");
    const auth=await this.auth.signInWithPassword(email.trim(),password); const memberships=await this.workspace.memberships(auth.user.id);
    return {auth,session:{user:auth.user,memberships}};
  }
  async authenticate(accessToken:string):Promise<MarketRouteSession>{const user=await this.auth.user(accessToken);const memberships=await this.workspace.memberships(user.id);return {user,memberships};}
  async refresh(refreshToken:string){const auth=await this.auth.refresh(refreshToken);const memberships=await this.workspace.memberships(auth.user.id);return {auth,session:{user:auth.user,memberships}};}
  async signOut(accessToken:string){await this.auth.signOut(accessToken);}
  selectWorkspace(session:MarketRouteSession,requestedId:string|null|undefined):WorkspaceMembership{
    const selected=requestedId?session.memberships.find((m)=>m.organisationId===requestedId):null;const workspace=selected??session.memberships[0];if(!workspace)throw new Error("MARKETROUTE_NO_ACTIVE_WORKSPACE_MEMBERSHIP");return workspace;
  }
  async createWorkspace(accessToken:string,name:string,slug:string):Promise<string>{const cleanName=name.trim(),cleanSlug=slug.trim().toLowerCase();if(!cleanName||!cleanSlug)throw new Error("MARKETROUTE_WORKSPACE_NAME_SLUG_REQUIRED");const value=await new AuthenticatedRpcClient().call<unknown>(accessToken,"marketroute_create_organisation",{p_name:cleanName,p_slug:cleanSlug});if(typeof value!=="string")throw new Error("MARKETROUTE_WORKSPACE_CREATE_INVALID_RESPONSE");return value;}
  async assertOpportunityScope(session:MarketRouteSession,opportunityId:string,organisationId:string):Promise<void>{
    if(!session.memberships.some((m)=>m.organisationId===organisationId))throw new Error("MARKETROUTE_WORKSPACE_ACCESS_DENIED");
    const actual=await this.workspace.opportunityOrganisation(opportunityId);if(actual!==organisationId)throw new Error("MARKETROUTE_OPPORTUNITY_SCOPE_MISMATCH");
  }
  async assertOpportunityWriteScope(session:MarketRouteSession,opportunityId:string,organisationId:string):Promise<void>{
    const membership=session.memberships.find((m)=>m.organisationId===organisationId);
    if(!membership)throw new Error("MARKETROUTE_WORKSPACE_ACCESS_DENIED");
    if(membership.role==="VIEWER")throw new Error("MARKETROUTE_WORKSPACE_WRITE_ACCESS_DENIED");
    const actual=await this.workspace.opportunityOrganisation(opportunityId);if(actual!==organisationId)throw new Error("MARKETROUTE_OPPORTUNITY_SCOPE_MISMATCH");
  }
}
export function sessionServiceFromEnvironment(){return new SessionService();}
