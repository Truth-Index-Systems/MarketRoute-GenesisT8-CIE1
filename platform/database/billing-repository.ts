import { PostgrestRpcClient,databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface BillingContextRecord { organisationId:string;planCode:string|null;entitlementStatus:string|null;externalCustomerId:string|null;externalSubscriptionId:string|null;currentPeriodStart:string|null;currentPeriodEnd:string|null;cancelAtPeriodEnd:boolean; }
export interface BillingCheckoutAttemptRecord { attemptId:string; }
export class BillingRepository {
  constructor(private readonly rpc=new PostgrestRpcClient(databaseConfigFromEnvironment())){}
  context(organisationId:string){return this.rpc.call<BillingContextRecord>("marketroute_billing_context_v1",{p_organisation_id:organisationId});}
  beginCheckout(input:{organisationId:string;userId:string;planCode:string}){return this.rpc.call<BillingCheckoutAttemptRecord>("marketroute_begin_billing_checkout_v1",{p_organisation_id:input.organisationId,p_user_id:input.userId,p_plan_code:input.planCode});}
  attachCheckout(input:{attemptId:string;sessionId:string}){return this.rpc.call<boolean>("marketroute_attach_billing_checkout_v1",{p_attempt_id:input.attemptId,p_external_checkout_session_id:input.sessionId});}
  terminateCheckout(input:{attemptId:string;organisationId:string;userId:string;status:"FAILED"|"EXPIRED";reason:string}){return this.rpc.call<boolean>("marketroute_terminate_billing_checkout_v1",{p_attempt_id:input.attemptId,p_organisation_id:input.organisationId,p_user_id:input.userId,p_status:input.status,p_reason:input.reason});}
  beginEvent(input:{eventId:string;eventType:string;payloadSha256:string}){return this.rpc.call<boolean>("marketroute_begin_billing_event_v1",{p_external_event_id:input.eventId,p_event_type:input.eventType,p_payload_sha256:input.payloadSha256});}
  finishEvent(input:{eventId:string;status:"PROCESSED"|"IGNORED"|"FAILED";errorCode?:string|null;metadata?:Record<string,unknown>}){return this.rpc.call<boolean>("marketroute_finish_billing_event_v1",{p_external_event_id:input.eventId,p_status:input.status,p_error_code:input.errorCode??null,p_metadata_json:input.metadata??{}});}
  reconcile(input:{organisationId:string;planCode:string;customerId:string;subscriptionId:string;providerStatus:string;periodStart:string|null;periodEnd:string|null;cancelAtPeriodEnd:boolean;eventId:string|null;eventType:string|null;checkoutSessionId:string|null}){return this.rpc.call<boolean>("marketroute_reconcile_stripe_subscription_v1",{p_organisation_id:input.organisationId,p_plan_code:input.planCode,p_external_customer_id:input.customerId,p_external_subscription_id:input.subscriptionId,p_provider_status:input.providerStatus,p_current_period_start:input.periodStart,p_current_period_end:input.periodEnd,p_cancel_at_period_end:input.cancelAtPeriodEnd,p_external_event_id:input.eventId,p_event_type:input.eventType,p_external_checkout_session_id:input.checkoutSessionId});}
}
export function billingRepositoryFromEnvironment(){return new BillingRepository();}
