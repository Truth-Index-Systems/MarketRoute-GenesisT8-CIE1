import { NextResponse } from "next/server";
import { assertAwsRdsDataSdkBundled } from "@/platform/database/aws-data-api-bundle-anchor";
import { awsDataApiFromEnvironment } from "@/platform/database/aws-data-api";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const noStoreHeaders = { "cache-control": "no-store" } as const;

export async function GET() {
  if (process.env.MARKETROUTE_AWS_SHADOW_MODE !== "true") {
    return NextResponse.json({ error: "not_found" }, { status: 404 });
  }

  try {
    assertAwsRdsDataSdkBundled();
    const database = await awsDataApiFromEnvironment();
    const result = await database.executeOperation("system.health", {});
    const resultOk = result.rows.length === 1 && result.rows[0]?.ok === 1;

    if (!resultOk) {
      return NextResponse.json(
        {
          status: "unavailable",
          build: "AWS-V0-BUILD-6",
          hosting: "amplify-shadow",
          transport: "rds-data-api",
          operation: "system.health",
          databaseReachable: true,
          resultOk: false,
          productionCutover: false,
          genesisEnabled: false,
        },
        { status: 503, headers: noStoreHeaders },
      );
    }

    return NextResponse.json(
      {
        status: "ok",
        build: "AWS-V0-BUILD-6",
        hosting: "amplify-shadow",
        transport: "rds-data-api",
        operation: "system.health",
        databaseReachable: true,
        resultOk: true,
        productionCutover: false,
        genesisEnabled: false,
      },
      { status: 200, headers: noStoreHeaders },
    );
  } catch (error) {
    console.error(
      "MARKETROUTE_AWS_V0_DATA_API_PROBE_FAILED",
      error instanceof Error ? error.name : "UnknownError",
    );
    return NextResponse.json(
      {
        status: "unavailable",
        build: "AWS-V0-BUILD-6",
        hosting: "amplify-shadow",
        transport: "rds-data-api",
        operation: "system.health",
        databaseReachable: false,
        resultOk: false,
        productionCutover: false,
        genesisEnabled: false,
      },
      { status: 503, headers: noStoreHeaders },
    );
  }
}
