import { databaseConfigFromEnvironment, type PostgrestRpcConfig } from "./postgrest-rpc";

function safeJson(raw:string):unknown{try{return raw?JSON.parse(raw):null}catch{return raw}}
export class PostgrestRestClient{
  constructor(private readonly config:PostgrestRpcConfig=databaseConfigFromEnvironment()){}
  private headers(extra:Record<string,string>={}){return {apikey:this.config.serviceRoleKey,Authorization:`Bearer ${this.config.serviceRoleKey}`,Accept:"application/json",...extra};}
  async get<T>(path:string):Promise<T>{const r=await (this.config.fetchImpl??fetch)(`${this.config.supabaseUrl}/rest/v1/${path}`,{headers:this.headers(),cache:"no-store"});const raw=await r.text();if(!r.ok)throw new Error(`MARKETROUTE_DATABASE_GET_FAILED:${r.status}:${path}`);return safeJson(raw) as T;}
}
