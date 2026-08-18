import { commercialAccessServiceFromEnvironment } from "../commercial/service";
import { supabaseAuthClientFromEnvironment, type SupabaseAuthSession, type AuthenticatedUser } from "../../platform/auth/supabase-auth";
import { workspaceRepositoryFromEnvironment, type WorkspaceMembership } from "../../platform/database/workspace-repository";
import { AuthenticatedRpcClient } from "../../platform/database/authenticated-rpc";
export type { WorkspaceMembership } from "../../platform/database/workspace-repository";

export interface MarketRouteSession {
  user:AuthenticatedUser;
  memberships:WorkspaceMembership[];
}
export interface WorkspaceActivationStatus {
  status:string;
  lastErrorCode:string|null;
  campaignId:string|null;
  campaignName:string|null;
  stage:string;
  progress:number;
  stageDetail:Record<string,unknown>;
  updatedAt:string|null;
}
interface ActivationBriefInput {
  organisationId:string;
  sellerOfferingText:string;
  objectiveText:string;
  targetMarketText:string;
  hardConstraintsText:string;
  noHardConstraints:boolean;
}

function validatedActivationBrief(input:ActivationBriefInput){
  const offering=input.sellerOfferingText.trim(),objective=input.objectiveText.trim(),target=input.targetMarketText.trim(),hard=input.hardConstraintsText.trim();
  if(offering.length<8)throw new Error("MARKETROUTE_SETUP_OFFERING_REQUIRED");if(objective.length<8)throw new Error("MARKETROUTE_SETUP_OBJECTIVE_REQUIRED");if(target.length<3)throw new Error("MARKETROUTE_SETUP_TARGET_REQUIRED");if(input.noHardConstraints&&hard.length>0)throw new Error("MARKETROUTE_SETUP_CONSTRAINT_CONFLICT");if(!input.noHardConstraints&&hard.length<3)throw new Error("MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED");
  return{offering,objective,target,hard};
}
export class SessionService {
  private readonly auth=supabaseAuthClientFromEnvironment();
  private readonly workspace=workspaceRepositoryFromEnvironment();
  private readonly commercial=commercialAccessServiceFromEnvironment();
  async signUp(email:string,password:string){
    const cleanEmail=email.trim().toLowerCase();
    if(!cleanEmail||!password)throw new Error("MARKETROUTE_SIGNUP_CREDENTIALS_REQUIRED");
    if(password.length<8)throw new Error("MARKETROUTE_PASSWORD_MINIMUM_8_CHARACTERS");
    return this.auth.signUpWithPassword(cleanEmail,password);
  }
  async signIn(email:string,password:string):Promise<{auth:SupabaseAuthSession;session:MarketRouteSession}>{
    if(!email.trim()||!password)throw new Error("MARKETROUTE_LOGIN_CREDENTIALS_REQUIRED");
    const auth=await this.auth.signInWithPassword(email.trim(),password); const memberships=await this.workspace.memberships(auth.user.id);
    return {auth,session:{user:auth.user,memberships}};
  }
  async authenticate(accessToken:string):Promise<MarketRouteSession>{const user=await this.auth.user(accessToken);const memberships=await this.workspace.memberships(user.id);return {user,memberships};}
  async refresh(refreshToken:string){const auth=await this.auth.refresh(refreshToken);const memberships=await this.workspace.memberships(auth.user.id);return {auth,session:{user:auth.user,memberships}};}
  async requestPasswordReset(email:string,redirectTo:string){const clean=email.trim().toLowerCase();if(!clean)throw new Error("MARKETROUTE_RESET_EMAIL_REQUIRED");await this.auth.requestPasswordReset(clean,redirectTo);}
  async updatePassword(accessToken:string,password:string){if(password.length<8)throw new Error("MARKETROUTE_PASSWORD_MINIMUM_8_CHARACTERS");await this.auth.updatePassword(accessToken,password);}
  async signOut(accessToken:string){await this.auth.signOut(accessToken);}
  selectWorkspace(session:MarketRouteSession,requestedId:string|null|undefined):WorkspaceMembership{
    const selected=requestedId?session.memberships.find((m)=>m.organisationId===requestedId):null;const workspace=selected??session.memberships[0];if(!workspace)throw new Error("MARKETROUTE_NO_ACTIVE_WORKSPACE_MEMBERSHIP");return workspace;
  }
  async createWorkspace(accessToken:string,name:string,websiteUrl:string):Promise<string>{
    const cleanName=name.trim(),cleanWebsiteUrl=websiteUrl.trim();
    if(!cleanName||!cleanWebsiteUrl)throw new Error("MARKETROUTE_WORKSPACE_NAME_WEBSITE_REQUIRED");
    let parsed:URL;
    try{parsed=new URL(cleanWebsiteUrl);}catch{throw new Error("MARKETROUTE_WORKSPACE_WEBSITE_INVALID");}
    if(!["http:","https:"].includes(parsed.protocol)||!parsed.hostname.includes("."))throw new Error("MARKETROUTE_WORKSPACE_WEBSITE_INVALID");
    const value=await new AuthenticatedRpcClient().call<unknown>(accessToken,"marketroute_create_workspace_with_seller_v1",{p_name:cleanName,p_website_url:parsed.toString()});
    if(typeof value!=="string")throw new Error("MARKETROUTE_WORKSPACE_CREATE_INVALID_RESPONSE");
    return value;
  }
  async activationStatus(accessToken:string,organisationId:string):Promise<WorkspaceActivationStatus>{
    const value=await new AuthenticatedRpcClient().call<unknown>(accessToken,"marketroute_workspace_activation_status_v2",{p_organisation_id:organisationId});
    if(!value||typeof value!=="object"||Array.isArray(value))throw new Error("MARKETROUTE_ACTIVATION_STATUS_INVALID");
    const row=value as Record<string,unknown>;
    const detail=row.stageDetail&&typeof row.stageDetail==="object"&&!Array.isArray(row.stageDetail)?row.stageDetail as Record<string,unknown>:{};
    const progress=Number(row.progress??0);
    return{status:String(row.status??"UNKNOWN"),lastErrorCode:typeof row.lastErrorCode==="string"?row.lastErrorCode:null,campaignId:typeof row.campaignId==="string"?row.campaignId:null,campaignName:typeof row.campaignName==="string"?row.campaignName:null,stage:String(row.stage??"QUEUED"),progress:Number.isFinite(progress)?Math.max(0,Math.min(100,Math.round(progress))):0,stageDetail:detail,updatedAt:typeof row.updatedAt==="string"?row.updatedAt:null};
  }
  async submitActivationBrief(accessToken:string,input:ActivationBriefInput):Promise<string>{
    const {offering,objective,target,hard}=validatedActivationBrief(input);
    const value=await new AuthenticatedRpcClient().call<unknown>(accessToken,"marketroute_submit_workspace_activation_v2",{p_organisation_id:input.organisationId,p_seller_offering_text:offering,p_objective_text:objective,p_target_market_text:target,p_hard_constraints_text:input.noHardConstraints?null:hard,p_no_hard_constraints:input.noHardConstraints});
    if(typeof value!=="string")throw new Error("MARKETROUTE_ACTIVATION_SUBMIT_INVALID_RESPONSE");return value;
  }
  async submitReplacementCampaign(accessToken:string,input:ActivationBriefInput&{campaignName:string}):Promise<string>{
    const campaignName=input.campaignName.trim();
    if(campaignName.length<3||campaignName.length>120)throw new Error("MARKETROUTE_CAMPAIGN_NAME_REQUIRED");
    const {offering,objective,target,hard}=validatedActivationBrief(input);
    const value=await new AuthenticatedRpcClient().call<unknown>(accessToken,"marketroute_submit_campaign_v2",{p_organisation_id:input.organisationId,p_campaign_name:campaignName,p_seller_offering_text:offering,p_objective_text:objective,p_target_market_text:target,p_hard_constraints_text:input.noHardConstraints?null:hard,p_no_hard_constraints:input.noHardConstraints});
    if(typeof value!=="string")throw new Error("MARKETROUTE_CAMPAIGN_CREATION_INVALID_RESPONSE");return value;
  }
  async assertOpportunityScope(session:MarketRouteSession,opportunityId:string,organisationId:string):Promise<void>{
    if(!session.memberships.some((m)=>m.organisationId===organisationId))throw new Error("MARKETROUTE_WORKSPACE_ACCESS_DENIED");
    const actual=await this.workspace.opportunityOrganisation(opportunityId);if(actual!==organisationId)throw new Error("MARKETROUTE_OPPORTUNITY_SCOPE_MISMATCH");const access=await this.commercial.access(organisationId);if(!this.commercial.canReadOpportunity(access,opportunityId))throw new Error("MARKETROUTE_DISCOVERY_UPGRADE_REQUIRED");
  }
  async assertOpportunityWriteScope(session:MarketRouteSession,opportunityId:string,organisationId:string):Promise<void>{
    const membership=session.memberships.find((m)=>m.organisationId===organisationId);
    if(!membership)throw new Error("MARKETROUTE_WORKSPACE_ACCESS_DENIED");
    if(membership.role==="VIEWER")throw new Error("MARKETROUTE_WORKSPACE_WRITE_ACCESS_DENIED");
    const actual=await this.workspace.opportunityOrganisation(opportunityId);if(actual!==organisationId)throw new Error("MARKETROUTE_OPPORTUNITY_SCOPE_MISMATCH");const access=await this.commercial.access(organisationId);if(!this.commercial.canReadOpportunity(access,opportunityId))throw new Error("MARKETROUTE_DISCOVERY_UPGRADE_REQUIRED");
  }
}
export function sessionServiceFromEnvironment(){return new SessionService();}
