export interface EngagementDeliveryPayload {
  queueItemId: string;
  idempotencyKey: string;
  channel: "EMAIL" | "CONTACT_FORM" | "LINKEDIN" | "PHONE" | "OTHER";
  accessPointValue: string;
  subjectText: string | null;
  bodyText: string;
}
export interface EngagementDeliveryResult { providerMessageId: string | null; metadata?: Record<string, string | number | boolean | null>; }
export interface EngagementDeliveryProvider { send(payload: EngagementDeliveryPayload, options: { signal: AbortSignal }): Promise<EngagementDeliveryResult>; }
export class EngagementDeliveryError extends Error {
  constructor(message:string, public readonly deliveryStateUnknown:boolean=true){super(message);this.name="EngagementDeliveryError";}
}
export class UnconfiguredEngagementDeliveryProvider implements EngagementDeliveryProvider {
  async send(): Promise<EngagementDeliveryResult> { throw new EngagementDeliveryError("MARKETROUTE_ENGAGEMENT_DELIVERY_PROVIDER_NOT_CONFIGURED",false); }
}
