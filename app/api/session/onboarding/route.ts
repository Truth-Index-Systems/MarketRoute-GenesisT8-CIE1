import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE, ORG_COOKIE } from "@/app/app/_lib/session";
import { sameOriginOrThrow } from "@/app/app/_lib/security";

export async function POST(request: Request) {
  try {
    sameOriginOrThrow(request);
    const jar = await cookies();
    const access = jar.get(ACCESS_COOKIE)?.value;
    if (!access) throw new Error("MARKETROUTE_AUTH_REQUIRED");

    const form = await request.formData();
    const organisationId = await sessionServiceFromEnvironment().createWorkspace(
      access,
      String(form.get("name") ?? ""),
      String(form.get("websiteUrl") ?? ""),
    );

    const response = NextResponse.redirect(new URL("/setup", request.url), 303);
    response.cookies.set(ORG_COOKIE, organisationId, {
      httpOnly: true,
      sameSite: "lax",
      secure: new URL(request.url).protocol === "https:",
      path: "/",
      maxAge: 60 * 60 * 24 * 365,
    });
    return response;
  } catch (error) {
    return NextResponse.redirect(
      new URL(`/onboarding?error=${encodeURIComponent(error instanceof Error ? error.message : "MARKETROUTE_ONBOARDING_FAILED")}`, request.url),
      303,
    );
  }
}
