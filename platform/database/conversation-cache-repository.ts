import { PostgrestRpcClient,databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface ConversationCacheRecord<T=Record<string,unknown>>{payload:T;model:string;createdAt:string;expiresAt:string;}
export class ConversationCacheRepository{
  constructor(private readonly rpc=new PostgrestRpcClient(databaseConfigFromEnvironment())){}
  get<T=Record<string,unknown>>(input:{scope:string;scopeKey:string;fingerprint:string;contractVersion:string}){
    return this.rpc.call<ConversationCacheRecord<T>|null>("marketroute_conversation_cache_get_v1",{
      p_scope_kind:input.scope,p_scope_key:input.scopeKey,p_input_fingerprint:input.fingerprint,p_contract_version:input.contractVersion
    });
  }
  put(input:{scope:string;scopeKey:string;fingerprint:string;contractVersion:string;payload:Record<string,unknown>;model:string;organisationId?:string|null;campaignId?:string|null;companyId?:string|null;ttlHours:number}){
    return this.rpc.call<void>("marketroute_conversation_cache_put_v1",{
      p_scope_kind:input.scope,p_scope_key:input.scopeKey,p_input_fingerprint:input.fingerprint,p_contract_version:input.contractVersion,
      p_payload_json:input.payload,p_model:input.model,p_organisation_id:input.organisationId??null,p_campaign_id:input.campaignId??null,p_company_id:input.companyId??null,p_ttl_hours:input.ttlHours
    });
  }
}
export function conversationCacheRepositoryFromEnvironment(){return new ConversationCacheRepository();}
