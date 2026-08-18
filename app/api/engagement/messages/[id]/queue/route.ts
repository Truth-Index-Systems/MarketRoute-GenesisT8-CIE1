import { NextResponse } from "next/server";
import { sameOriginOrThrow,safeReturnPath } from "@/app/app/_lib/security";

export async function POST(request:Request){
  const form=await request.formData();const returnTo=safeReturnPath(form.get("returnTo"));
  try{sameOriginOrThrow(request);throw new Error("MARKETROUTE_ASSISTED_ENGAGEMENT_ONLY");}
  catch(error){const code=encodeURIComponent(error instanceof Error?error.message:"MARKETROUTE_ASSISTED_ENGAGEMENT_ONLY");return NextResponse.redirect(new URL(`${returnTo}${returnTo.includes("?")?"&":"?"}actionError=${code}`,request.url),303);}
}
