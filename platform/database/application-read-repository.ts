import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc.js";

export class ApplicationReadRepository {
  constructor(private readonly rpc: PostgrestRpcClient) {}
  static fromEnvironment(){ return new ApplicationReadRepository(new PostgrestRpcClient(databaseConfigFromEnvironment())); }

  commandCentre(organisationId:string,at:string):Promise<unknown>{
    return this.rpc.call("marketroute_application_command_centre_read_v1",{p_organisation_id:organisationId,p_at:at});
  }
  campaign(organisationId:string,campaignId:string,at:string):Promise<unknown>{
    return this.rpc.call("marketroute_application_campaign_read_v1",{p_organisation_id:organisationId,p_campaign_id:campaignId,p_at:at});
  }
  company(organisationId:string,campaignId:string,companyId:string,at:string):Promise<unknown>{
    return this.rpc.call("marketroute_application_company_read_v1",{p_organisation_id:organisationId,p_campaign_id:campaignId,p_company_id:companyId,p_at:at});
  }
  engagement(opportunityId:string,at:string):Promise<unknown>{
    return this.rpc.call("marketroute_application_engagement_read_v1",{p_opportunity_id:opportunityId,p_at:at});
  }
  claimProvenance(organisationId:string,campaignId:string,companyId:string,claimSnapshotId:string,at:string):Promise<unknown>{
    return this.rpc.call("marketroute_application_claim_provenance_read_v1",{
      p_organisation_id:organisationId,p_campaign_id:campaignId,p_company_id:companyId,p_claim_snapshot_id:claimSnapshotId,p_at:at
    });
  }
}
export function applicationReadRepositoryFromEnvironment(){return ApplicationReadRepository.fromEnvironment();}
