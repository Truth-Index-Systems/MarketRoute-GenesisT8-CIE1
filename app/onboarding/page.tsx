import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE } from "@/app/app/_lib/session";

// Launch flow is discovery-first. The anonymous discovery already created the
// organisation, seller and market context, so asking for them again here would
// duplicate data and create a second workspace. Membership-less accounts are
// returned to Discovery instead of entering the legacy manual-workspace path.
export default async function Onboarding(){
  const jar=await cookies();
  const access=jar.get(ACCESS_COOKIE)?.value;
  if(!access)redirect("/login?next=/app");
  try{
    const session=await sessionServiceFromEnvironment().authenticate(access);
    if(session.memberships.length>0)redirect("/app");
  }catch{
    redirect("/login?next=/app");
  }
  redirect("/discover");
}
