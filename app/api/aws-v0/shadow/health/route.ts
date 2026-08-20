import { NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  if (process.env.MARKETROUTE_AWS_SHADOW_MODE !== "true") {
    return NextResponse.json({ error: "not_found" }, { status: 404 });
  }

  const databaseConfigured = Boolean(
    process.env.MARKETROUTE_AWS_RDS_CLUSTER_ARN &&
    process.env.MARKETROUTE_AWS_RDS_SECRET_ARN &&
    process.env.MARKETROUTE_AWS_RDS_DATABASE,
  );
  const cognitoConfigured = Boolean(
    process.env.MARKETROUTE_COGNITO_USER_POOL_ID &&
    process.env.MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID,
  );

  return NextResponse.json(
    {
      status: "ok",
      build: "AWS-V0-BUILD-6",
      hosting: "amplify-shadow",
      runtime: "nodejs",
      awsRegionPresent: Boolean(process.env.AWS_REGION),
      databaseConfigured,
      cognitoConfigured,
      productionCutover: false,
      genesisEnabled: false,
    },
    {
      status: 200,
      headers: { "cache-control": "no-store" },
    },
  );
}
