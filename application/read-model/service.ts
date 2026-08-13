import { ApplicationReadRepository, applicationReadRepositoryFromEnvironment } from "../../platform/database/application-read-repository";
import type { CampaignReadModel, ClaimProvenanceReadModel, CommandCentreReadModel, CompanyIntelligenceReadModel, EngagementReadModel, CompanyIndexReadModel, ResearchActivityReadModel, EngagementIndexReadModel, ProvenanceClaimIndexReadModel, RouteDisplayReadModel } from "./contracts";
import { assertCanonicalApplicationRead, assertCanonicalEngagementRead } from "./validation";

function currentIso(value?:string):string {
  const date=value?new Date(value):new Date();
  if(!Number.isFinite(date.getTime())) throw new Error("MARKETROUTE_APPLICATION_READ_TIME_INVALID");
  return date.toISOString();
}
function requiredId(value:string,name:string):string {
  const v=value?.trim(); if(!v) throw new Error(`MARKETROUTE_APPLICATION_READ_ID_REQUIRED:${name}`); return v;
}

export class ApplicationReadService {
  constructor(private readonly repository:ApplicationReadRepository){}
  async commandCentre(command:{organisationId:string;at?:string}):Promise<CommandCentreReadModel>{
    const value=await this.repository.commandCentre(requiredId(command.organisationId,"organisationId"),currentIso(command.at));
    return assertCanonicalApplicationRead<CommandCentreReadModel>(value,"COMMAND_CENTRE");
  }
  async campaign(command:{organisationId:string;campaignId:string;at?:string}):Promise<CampaignReadModel>{
    const value=await this.repository.campaign(requiredId(command.organisationId,"organisationId"),requiredId(command.campaignId,"campaignId"),currentIso(command.at));
    return assertCanonicalApplicationRead<CampaignReadModel>(value,"CAMPAIGN");
  }
  async company(command:{organisationId:string;campaignId:string;companyId:string;at?:string}):Promise<CompanyIntelligenceReadModel>{
    const value=await this.repository.company(requiredId(command.organisationId,"organisationId"),requiredId(command.campaignId,"campaignId"),requiredId(command.companyId,"companyId"),currentIso(command.at));
    return assertCanonicalApplicationRead<CompanyIntelligenceReadModel>(value,"COMPANY_INTELLIGENCE");
  }
  async companyIndex(command:{organisationId:string;campaignId:string;limit?:number;offset?:number;at?:string}):Promise<CompanyIndexReadModel>{
    const limit=Math.max(1,Math.min(command.limit??100,250)); const offset=Math.max(0,command.offset??0);
    const value=await this.repository.companyIndex(requiredId(command.organisationId,"organisationId"),requiredId(command.campaignId,"campaignId"),limit,offset,currentIso(command.at));
    return assertCanonicalApplicationRead<CompanyIndexReadModel>(value,"COMPANY_INDEX");
  }
  async researchActivity(command:{organisationId:string;campaignId:string;at?:string}):Promise<ResearchActivityReadModel>{
    const value=await this.repository.researchActivity(requiredId(command.organisationId,"organisationId"),requiredId(command.campaignId,"campaignId"),currentIso(command.at));
    return assertCanonicalApplicationRead<ResearchActivityReadModel>(value,"RESEARCH_ACTIVITY");
  }
  async engagementIndex(command:{organisationId:string;campaignId:string;limit?:number;offset?:number;at?:string}):Promise<EngagementIndexReadModel>{
    const limit=Math.max(1,Math.min(command.limit??100,250)); const offset=Math.max(0,command.offset??0);
    const value=await this.repository.engagementIndex(requiredId(command.organisationId,"organisationId"),requiredId(command.campaignId,"campaignId"),limit,offset,currentIso(command.at));
    return assertCanonicalApplicationRead<EngagementIndexReadModel>(value,"ENGAGEMENT_INDEX");
  }
  async routeDisplay(command:{organisationId:string;campaignId:string;companyId:string;at?:string}):Promise<RouteDisplayReadModel>{
    const value=await this.repository.routeDisplay(requiredId(command.organisationId,"organisationId"),requiredId(command.campaignId,"campaignId"),requiredId(command.companyId,"companyId"),currentIso(command.at));
    return assertCanonicalApplicationRead<RouteDisplayReadModel>(value,"ROUTE_DISPLAY");
  }
  async provenanceClaimIndex(command:{organisationId:string;campaignId:string;companyId:string;at?:string}):Promise<ProvenanceClaimIndexReadModel>{
    const value=await this.repository.provenanceClaimIndex(requiredId(command.organisationId,"organisationId"),requiredId(command.campaignId,"campaignId"),requiredId(command.companyId,"companyId"),currentIso(command.at));
    return assertCanonicalApplicationRead<ProvenanceClaimIndexReadModel>(value,"PROVENANCE_CLAIM_INDEX");
  }

  async engagement(command:{opportunityId:string;at?:string}):Promise<EngagementReadModel>{
    const value=await this.repository.engagement(requiredId(command.opportunityId,"opportunityId"),currentIso(command.at));
    return assertCanonicalEngagementRead<EngagementReadModel>(value);
  }
  async claimProvenance(command:{organisationId:string;campaignId:string;companyId:string;claimSnapshotId:string;at?:string}):Promise<ClaimProvenanceReadModel>{
    const value=await this.repository.claimProvenance(
      requiredId(command.organisationId,"organisationId"),requiredId(command.campaignId,"campaignId"),
      requiredId(command.companyId,"companyId"),requiredId(command.claimSnapshotId,"claimSnapshotId"),currentIso(command.at)
    );
    return assertCanonicalApplicationRead<ClaimProvenanceReadModel>(value,"CLAIM_PROVENANCE");
  }
}
export function applicationReadServiceFromEnvironment(){return new ApplicationReadService(applicationReadRepositoryFromEnvironment());}
