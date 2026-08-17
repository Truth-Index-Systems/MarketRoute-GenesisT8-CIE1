import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface AnonymousDiscoveryStatusRecord {
  runId:string;
  companyName:string;
  websiteUrl:string;
  runStatus:string;
  activation:{status:string;stage:string;progress:number;lastErrorCode:string|null;updatedAt:string|null;stageDetail:Record<string,unknown>};
  metrics:{scopedCompanies:number;researchedCompanies:number;researchWorkTotal:number;researchWorkCompleted:number;opportunities:number;structuralRoutes:number;authorisedRoutes:number};
}

export class AnonymousDiscoveryRepository {
  constructor(private readonly rpc=new PostgrestRpcClient(databaseConfigFromEnvironment())){}
  create(input:{browserKeyHash:string;ipHash:string;companyName:string;websiteUrl:string;sellerOfferingText:string;targetMarketText:string;objectiveText:string;lifetimeBudgetUsd:number;researchWindowHours:number;targetCount:number}){
    return this.rpc.call<{runId:string;existing:boolean}>("marketroute_create_anonymous_discovery_v1",{
      p_browser_key_hash:input.browserKeyHash,
      p_ip_hash:input.ipHash,
      p_company_name:input.companyName,
      p_website_url:input.websiteUrl,
      p_seller_offering_text:input.sellerOfferingText,
      p_target_market_text:input.targetMarketText,
      p_objective_text:input.objectiveText,
      p_lifetime_budget_usd:input.lifetimeBudgetUsd,
      p_research_window_hours:input.researchWindowHours,
      p_target_count:input.targetCount,
    });
  }
  status(browserKeyHash:string){
    return this.rpc.call<AnonymousDiscoveryStatusRecord|null>("marketroute_anonymous_discovery_status_v1",{p_browser_key_hash:browserKeyHash});
  }
  anonymousPolicy(organisationId:string){
    return this.rpc.call<{runId:string;lifetimeBudgetUsd:number;researchExpiresAt:string;targetCount:number}|null>("marketroute_anonymous_discovery_policy_v1",{p_organisation_id:organisationId});
  }
}
export function anonymousDiscoveryRepositoryFromEnvironment(){return new AnonymousDiscoveryRepository();}
