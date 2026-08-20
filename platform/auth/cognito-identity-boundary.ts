import "server-only";

import { awsDataApiFromEnvironment, type AwsDataApi } from "../database/aws-data-api";
import {
  cognitoAuthClientFromEnvironment,
  cognitoConfigFromEnvironment,
  type CognitoAuthClient,
  type CognitoAuthenticatedUser,
} from "./cognito-auth";

export interface MarketRouteActorIdentity {
  actorUserId: string;
  externalProvider: "COGNITO";
  externalSubject: string;
  email: string | null;
  emailVerified: boolean;
}

function requiredActorUserId(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new Error("MARKETROUTE_COGNITO_ACTOR_RESOLUTION_INVALID");
  }
  return value;
}

export class CognitoIdentityBoundary {
  public constructor(
    private readonly auth: CognitoAuthClient,
    private readonly database: AwsDataApi,
    private readonly issuer: string,
  ) {}

  async resolveAccessToken(accessToken: string): Promise<MarketRouteActorIdentity> {
    const externalUser = await this.auth.user(accessToken);
    return this.resolveExternalUser(externalUser);
  }

  async resolveExternalUser(externalUser: CognitoAuthenticatedUser): Promise<MarketRouteActorIdentity> {
    const result = await this.database.executeOperation("identity.resolveActor", {
      provider: "COGNITO",
      issuer: this.issuer,
      subject: externalUser.id,
      email: externalUser.email,
      emailVerified: externalUser.emailVerified,
    });
    const actorUserId = requiredActorUserId(result.rows[0]?.actor_user_id);
    return {
      actorUserId,
      externalProvider: "COGNITO",
      externalSubject: externalUser.id,
      email: externalUser.email,
      emailVerified: externalUser.emailVerified,
    };
  }
}

export async function cognitoIdentityBoundaryFromEnvironment(): Promise<CognitoIdentityBoundary> {
  const config = cognitoConfigFromEnvironment();
  return new CognitoIdentityBoundary(
    cognitoAuthClientFromEnvironment(),
    await awsDataApiFromEnvironment(),
    config.issuer,
  );
}
