import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE } from "@/app/app/_lib/session";
import { MarketRouteLogo, Icon } from "@/ui";

function onboardingError(message: string | null): string | null {
  if (!message) return null;
  const known: Record<string, string> = {
    MARKETROUTE_WORKSPACE_NAME_WEBSITE_REQUIRED: "Add your organisation name and company website to continue.",
    MARKETROUTE_WORKSPACE_WEBSITE_INVALID: "Enter a full company website, for example https://truthindexsystems.co.uk.",
    MARKETROUTE_WORKSPACE_CREATE_INVALID_RESPONSE: "MarketRoute could not create the workspace. Please try again.",
    MARKETROUTE_AUTH_REQUIRED: "Your session has expired. Sign in again to continue.",
  };
  return known[message] ?? "MarketRoute could not create the workspace. Please check the details and try again.";
}

export default async function Onboarding({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const query = await searchParams;
  const jar = await cookies();
  const access = jar.get(ACCESS_COOKIE)?.value;
  if (!access) redirect("/login?next=/onboarding");

  try {
    const session = await sessionServiceFromEnvironment().authenticate(access);
    if (session.memberships.length > 0) redirect("/app");
  } catch {
    redirect("/login?next=/onboarding");
  }

  const rawError = typeof query.error === "string" ? decodeURIComponent(query.error) : null;
  const error = onboardingError(rawError);

  return (
    <main className="mr-login">
      <section className="mr-login__context">
        <a href="/" aria-label="MarketRoute home"><MarketRouteLogo /></a>
        <div>
          <span>Workspace setup</span>
          <h1>Give your commercial intelligence a home.</h1>
          <p>
            Your workspace keeps your company context, campaigns, research, opportunities and engagement together in one private place.
          </p>
        </div>
        <footer>Step 1 of your MarketRoute workspace</footer>
      </section>

      <section className="mr-login__panel">
        <div className="mr-kicker"><span /> Organisation</div>
        <h2>Create your workspace</h2>
        <p>Tell MarketRoute which business it is working for. We will generate the technical workspace details for you.</p>

        {error && (
          <div className="mr-alert mr-alert--error">
            <Icon name="shield" size={18} />
            <span>{error}</span>
          </div>
        )}

        <form action="/api/session/onboarding" method="post" className="mr-login__form">
          <label>
            <span>Organisation name</span>
            <input
              name="name"
              required
              autoComplete="organization"
              placeholder="Truth Index Systems"
            />
          </label>

          <label>
            <span>Company website</span>
            <input
              name="websiteUrl"
              type="url"
              inputMode="url"
              autoComplete="url"
              required
              placeholder="https://truthindexsystems.co.uk"
              aria-describedby="mr-company-website-help"
            />
            <small className="mr-field-help" id="mr-company-website-help">
              Use the full website address, including https://. MarketRoute uses this to identify your business and prepare seller research.
            </small>
          </label>

          <button className="mr-button mr-button--primary" type="submit">
            Create workspace <Icon name="arrow" size={18} />
          </button>
        </form>

        <small>Your workspace URL is generated automatically. You can change campaigns and research settings later.</small>
      </section>
    </main>
  );
}
