import { databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface WorkspaceMembership {
  organisationId:string;
  role:"OWNER"|"ADMIN"|"MEMBER"|"VIEWER";
  organisation:{organisationId:string;name:string;slug:string;status:"ACTIVE"|"SUSPENDED"|"CLOSED"};
}

function encode(value:string){return encodeURIComponent(value);}
function object(value:unknown):Record<string,unknown>{if(!value||typeof value!=="object"||Array.isArray(value))throw new Error("MARKETROUTE_WORKSPACE_RESPONSE_INVALID");return value as Record<string,unknown>;}
export class WorkspaceRepository {
  private async get(path:string):Promise<unknown>{
    const cfg=databaseConfigFromEnvironment();
    const response=await fetch(`${cfg.supabaseUrl}/rest/v1/${path}`,{headers:{apikey:cfg.serviceRoleKey,Authorization:`Bearer ${cfg.serviceRoleKey}`,Accept:"application/json"},cache:"no-store"});
    const raw=await response.text(); let value:unknown=null; try{value=raw?JSON.parse(raw):null;}catch{value=raw;}
    if(!response.ok)throw new Error(`MARKETROUTE_WORKSPACE_DATABASE_FAILED:${response.status}`); return value;
  }
  async memberships(userId:string):Promise<WorkspaceMembership[]>{
    const rows=await this.get(`organisation_memberships?select=organisation_id,role,status,organisations!inner(id,name,slug,status)&user_id=eq.${encode(userId)}&status=eq.ACTIVE&order=created_at.asc`);
    if(!Array.isArray(rows))throw new Error("MARKETROUTE_WORKSPACE_MEMBERSHIPS_INVALID");
    return rows.map((row)=>{const r=object(row);const org=object(r.organisations);const role=String(r.role) as WorkspaceMembership["role"];if(!["OWNER","ADMIN","MEMBER","VIEWER"].includes(role))throw new Error("MARKETROUTE_WORKSPACE_ROLE_INVALID");return {organisationId:String(r.organisation_id),role,organisation:{organisationId:String(org.id),name:String(org.name),slug:String(org.slug),status:String(org.status) as WorkspaceMembership["organisation"]["status"]}};}).filter((m)=>m.organisation.status==="ACTIVE");
  }
  async opportunityOrganisation(opportunityId:string):Promise<string|null>{
    const rows=await this.get(`opportunities?select=organisation_id&id=eq.${encode(opportunityId)}&limit=1`); if(!Array.isArray(rows)||rows.length===0)return null; return String(object(rows[0]).organisation_id);
  }
}
export function workspaceRepositoryFromEnvironment(){return new WorkspaceRepository();}
