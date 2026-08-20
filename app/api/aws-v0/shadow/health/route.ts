import { NextResponse } from "next/server";
import {
  getAwsV0ShadowRuntimeStatus,
  isAwsV0ShadowModeEnabled,
} from "@/application/aws-v0/shadow-runtime";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  if (!isAwsV0ShadowModeEnabled()) {
    return NextResponse.json({ error: "not_found" }, { status: 404 });
  }

  const { awsRegionPresent, databaseConfigured, cognitoConfigured } = getAwsV0ShadowRuntimeStatus();

  return NextResponse.json(
    {
      status: "ok",
      build: "AWS-V0-BUILD-6",
      hosting: "amplify-shadow",
      runtime: "nodejs",
      awsRegionPresent,
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
