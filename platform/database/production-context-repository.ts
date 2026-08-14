import { PostgrestRestClient } from "./postgrest-rest";
function enc(v:string){return encodeURIComponent(v)}
function row(v:unknown):Record<string,unknown>|null{return v&&typeof v==="object"&&!Array.isArray(v)?v as Record<string,unknown>:null}
export interface CompanyResearchContext{companyId:string;name:string;canonicalDomain:string|null;websiteUrl:string|null;countryCode:string|null}
export interface ContactResearchContext{personId:string;personName:string;companyId:string;companyName:string;companyDomain:string|null;accessPointId:string;accessPointKind:string|null;accessPointValue:string|null}
export class ProductionContextRepository{
  constructor(private readonly rest=new PostgrestRestClient()){}
  async company(companyId:string):Promise<CompanyResearchContext>{const rows=await this.rest.get<unknown[]>(`companies?select=id,canonical_name,canonical_domain,website_url,country_code&id=eq.${enc(companyId)}&limit=1`);const r=row(rows?.[0]);if(!r)throw new Error("MARKETROUTE_RESEARCH_COMPANY_NOT_FOUND");return{companyId:String(r.id),name:String(r.canonical_name),canonicalDomain:typeof r.canonical_domain==="string"?r.canonical_domain:null,websiteUrl:typeof r.website_url==="string"?r.website_url:null,countryCode:typeof r.country_code==="string"?r.country_code:null};}
  async contact(personId:string,companyId:string,accessPointId:string):Promise<ContactResearchContext>{const [p,c,n]=await Promise.all([
    this.rest.get<unknown[]>(`people?select=id,display_name&id=eq.${enc(personId)}&limit=1`),
    this.rest.get<unknown[]>(`companies?select=id,canonical_name,canonical_domain&id=eq.${enc(companyId)}&limit=1`),
    this.rest.get<unknown[]>(`commercial_graph_nodes?select=id,access_point_kind,canonical_value&id=eq.${enc(accessPointId)}&limit=1`),
  ]);const pr=row(p?.[0]),cr=row(c?.[0]),nr=row(n?.[0]);if(!pr||!cr||!nr)throw new Error("MARKETROUTE_RESEARCH_CONTACT_CONTEXT_NOT_FOUND");return{personId:String(pr.id),personName:String(pr.display_name),companyId:String(cr.id),companyName:String(cr.canonical_name),companyDomain:typeof cr.canonical_domain==="string"?cr.canonical_domain:null,accessPointId:String(nr.id),accessPointKind:typeof nr.access_point_kind==="string"?nr.access_point_kind:null,accessPointValue:typeof nr.canonical_value==="string"?nr.canonical_value:null};}
}
