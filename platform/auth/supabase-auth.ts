export interface AuthenticatedUser {
  id: string;
  email: string | null;
}
export interface SupabaseAuthSession {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  user: AuthenticatedUser;
}

function required(name:"SUPABASE_URL"|"SUPABASE_ANON_KEY"):string {
  const fallback=name==="SUPABASE_ANON_KEY"?process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY:undefined;
  const value=(process.env[name]??fallback)?.trim();
  if(!value) throw new Error(`MARKETROUTE_ENV_REQUIRED:${name}`);
  return value;
}
function config(){return {url:required("SUPABASE_URL").replace(/\/+$/,""),anon:required("SUPABASE_ANON_KEY")};}
async function request(path:string,init:RequestInit,accessToken?:string):Promise<unknown>{
  const {url,anon}=config();
  const response=await fetch(`${url}${path}`,{...init,headers:{apikey:anon,"Content-Type":"application/json",...(accessToken?{Authorization:`Bearer ${accessToken}`}:{ }),...(init.headers??{})},cache:"no-store"});
  const raw=await response.text(); let value:unknown=null; try{value=raw?JSON.parse(raw):null;}catch{value=raw;}
  if(!response.ok){const object=value&&typeof value==="object"?value as Record<string,unknown>:null;throw new Error(typeof object?.msg==="string"?object.msg:typeof object?.message==="string"?object.message:`MARKETROUTE_AUTH_REQUEST_FAILED:${response.status}`);}
  return value;
}
function asRecord(value:unknown):Record<string,unknown>{if(!value||typeof value!=="object"||Array.isArray(value))throw new Error("MARKETROUTE_AUTH_RESPONSE_INVALID");return value as Record<string,unknown>;}
function parseUser(value:unknown):AuthenticatedUser{const u=asRecord(value);if(typeof u.id!=="string")throw new Error("MARKETROUTE_AUTH_USER_ID_MISSING");return {id:u.id,email:typeof u.email==="string"?u.email:null};}
function parseSession(value:unknown):SupabaseAuthSession{const v=asRecord(value);if(typeof v.access_token!=="string"||typeof v.refresh_token!=="string"||typeof v.expires_in!=="number")throw new Error("MARKETROUTE_AUTH_SESSION_INVALID");return {accessToken:v.access_token,refreshToken:v.refresh_token,expiresIn:v.expires_in,user:parseUser(v.user)};}

export class SupabaseAuthClient {
  async signInWithPassword(email:string,password:string):Promise<SupabaseAuthSession>{
    return parseSession(await request("/auth/v1/token?grant_type=password",{method:"POST",body:JSON.stringify({email,password})}));
  }
  async refresh(refreshToken:string):Promise<SupabaseAuthSession>{
    return parseSession(await request("/auth/v1/token?grant_type=refresh_token",{method:"POST",body:JSON.stringify({refresh_token:refreshToken})}));
  }
  async user(accessToken:string):Promise<AuthenticatedUser>{return parseUser(await request("/auth/v1/user",{method:"GET"},accessToken));}
  async signOut(accessToken:string):Promise<void>{await request("/auth/v1/logout",{method:"POST"},accessToken);}
}
export function supabaseAuthClientFromEnvironment(){return new SupabaseAuthClient();}
