function present(name){return Boolean(String(process.env[name]||"").trim())}
const missing=[];
for(const key of ["SUPABASE_URL","OPENAI_API_KEY","CRON_SECRET","FOUNDER_DASHBOARD_PASSWORD","FOUNDER_DASHBOARD_SESSION_SECRET"])if(!present(key))missing.push(key);
if(!(present("SUPABASE_SECRET_KEY")||present("SUPABASE_SERVICE_ROLE_KEY")))missing.push("SUPABASE_SECRET_KEY_OR_SUPABASE_SERVICE_ROLE_KEY");
if(!(present("SUPABASE_PUBLISHABLE_KEY")||present("SUPABASE_ANON_KEY")))missing.push("SUPABASE_PUBLISHABLE_KEY_OR_SUPABASE_ANON_KEY");
if(String(process.env.MARKETROUTE_DELIVERY_ENABLED||"").toLowerCase()==="true")for(const key of ["RESEND_API_KEY","MARKETROUTE_EMAIL_FROM"])if(!present(key))missing.push(key);
if(missing.length){console.error(`Missing production environment variables: ${missing.join(", ")}`);process.exit(1)}
if(!/^https:\/\//.test(process.env.SUPABASE_URL))throw new Error("SUPABASE_URL must use https://");
if(String(process.env.CRON_SECRET).trim().length<32)throw new Error("CRON_SECRET must be at least 32 characters");
if(String(process.env.FOUNDER_DASHBOARD_PASSWORD).trim().length<12)throw new Error("FOUNDER_DASHBOARD_PASSWORD must be at least 12 characters");
if(String(process.env.FOUNDER_DASHBOARD_SESSION_SECRET).trim().length<32)throw new Error("FOUNDER_DASHBOARD_SESSION_SECRET must be at least 32 characters");
const mode=present("SUPABASE_SECRET_KEY")&&present("SUPABASE_PUBLISHABLE_KEY")?"current":present("SUPABASE_SERVICE_ROLE_KEY")&&present("SUPABASE_ANON_KEY")?"legacy":"mixed";
console.log(`MarketRoute production environment contract: PASS (Supabase=${mode}, model=${process.env.OPENAI_MODEL||"gpt-5.6-luna"}, delivery=${String(process.env.MARKETROUTE_DELIVERY_ENABLED||"false").toLowerCase()})`);
