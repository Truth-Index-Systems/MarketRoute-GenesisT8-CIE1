import { NextResponse } from "next/server";
import { runAwsV0SyntheticSemanticProbe } from "@/application/aws-v0/shadow-ai-semantic-probe";
import { isAwsV0ShadowModeEnabled } from "@/application/aws-v0/shadow-runtime";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const noStoreHeaders = { "cache-control": "no-store" } as const;

export async function POST() {
  if (!isAwsV0ShadowModeEnabled()) {
    return NextResponse.json({ error: "not_found" }, { status: 404, headers: noStoreHeaders });
  }

  try {
    const result = await runAwsV0SyntheticSemanticProbe();
    if (!result.ok) {
      const status = result.failureCode === "TIMEOUT" ? 504 : 503;
      return NextResponse.json(
        {
          status: "unavailable",
          build: "AWS-V0-BUILD-7.5",
          operation: "ai.semanticProbe",
          failureCode: result.failureCode,
          diagnostics: result.diagnostics,
          productionCutover: false,
          genesisEnabled: false,
        },
        { status, headers: noStoreHeaders },
      );
    }

    return NextResponse.json(
      {
        status: "ok",
        build: "AWS-V0-BUILD-7.5",
        operation: "ai.semanticProbe",
        structuredOutput: true,
        result: result.value,
        diagnostics: result.diagnostics,
        productionCutover: false,
        genesisEnabled: false,
      },
      { status: 200, headers: noStoreHeaders },
    );
  } catch {
    return NextResponse.json(
      {
        status: "unavailable",
        build: "AWS-V0-BUILD-7.5",
        operation: "ai.semanticProbe",
        failureCode: "PROVIDER_UNAVAILABLE",
        diagnostics: null,
        productionCutover: false,
        genesisEnabled: false,
      },
      { status: 503, headers: noStoreHeaders },
    );
  }
}
