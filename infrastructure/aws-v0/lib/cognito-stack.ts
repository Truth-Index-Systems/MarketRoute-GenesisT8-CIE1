import { Aws, CfnOutput, RemovalPolicy, Stack, StackProps } from "aws-cdk-lib";
import * as cognito from "aws-cdk-lib/aws-cognito";
import { Construct } from "constructs";

export class MrAwsV0CognitoStack extends Stack {
  public constructor(scope: Construct, id: string, props: StackProps) {
    super(scope, id, props);

    const userPool = new cognito.CfnUserPool(this, "MarketRouteUserPool", {
      userPoolName: "marketroute-aws-v0-users",
      deletionProtection: "ACTIVE",
      usernameAttributes: ["email"],
      autoVerifiedAttributes: ["email"],
      mfaConfiguration: "OFF",
      adminCreateUserConfig: {
        allowAdminCreateUserOnly: false,
      },
      policies: {
        passwordPolicy: {
          minimumLength: 8,
          requireLowercase: true,
          requireUppercase: true,
          requireNumbers: true,
          requireSymbols: false,
          temporaryPasswordValidityDays: 7,
        },
      },
      accountRecoverySetting: {
        recoveryMechanisms: [{ name: "verified_email", priority: 1 }],
      },
      userAttributeUpdateSettings: {
        attributesRequireVerificationBeforeUpdate: ["email"],
      },
      schema: [{
        name: "email",
        attributeDataType: "String",
        mutable: true,
        required: true,
        stringAttributeConstraints: { minLength: "3", maxLength: "320" },
      }],
    });
    userPool.applyRemovalPolicy(RemovalPolicy.RETAIN);

    const userPoolClient = new cognito.CfnUserPoolClient(this, "MarketRouteWebClient", {
      userPoolId: userPool.ref,
      clientName: "marketroute-aws-v0-web",
      generateSecret: false,
      preventUserExistenceErrors: "ENABLED",
      enableTokenRevocation: true,
      explicitAuthFlows: [
        "ALLOW_USER_PASSWORD_AUTH",
        "ALLOW_USER_SRP_AUTH",
        "ALLOW_REFRESH_TOKEN_AUTH",
      ],
      accessTokenValidity: 1,
      idTokenValidity: 1,
      refreshTokenValidity: 30,
      tokenValidityUnits: {
        accessToken: "hours",
        idToken: "hours",
        refreshToken: "days",
      },
    });
    userPoolClient.applyRemovalPolicy(RemovalPolicy.RETAIN);

    const issuer = `https://cognito-idp.${Aws.REGION}.${Aws.URL_SUFFIX}/${userPool.ref}`;

    new CfnOutput(this, "CognitoUserPoolId", {
      value: userPool.ref,
      description: "MarketRoute AWS V0 Cognito user pool ID",
    });

    new CfnOutput(this, "CognitoUserPoolClientId", {
      value: userPoolClient.ref,
      description: "MarketRoute AWS V0 public web app client ID (no client secret)",
    });

    new CfnOutput(this, "CognitoIssuer", {
      value: issuer,
      description: "Trusted issuer for MarketRoute AWS V0 Cognito JWT verification",
    });

    new CfnOutput(this, "CognitoJwksUrl", {
      value: `${issuer}/.well-known/jwks.json`,
      description: "JWKS endpoint for MarketRoute AWS V0 Cognito JWT verification",
    });
  }
}
