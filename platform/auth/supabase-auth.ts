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
export interface SupabaseSignUpResult {
  user: AuthenticatedUser;
  session: SupabaseAuthSession | null;
}

function requiredUrl():string {
  const value=process.env.SUPABASE_URL?.trim();
  if(!value) throw new Error("MARKETROUTE_ENV_REQUIRED:SUPABASE_URL");
  return value;
}
function publicKey():string {
  const value=process.env.SUPABASE_PUBLISHABLE_KEY?.trim()||process.env.SUPABASE_ANON_KEY?.trim();
  if(!value) throw new Error("MARKETROUTE_ENV_REQUIRED:SUPABASE_PUBLISHABLE_KEY_OR_SUPABASE_ANON_KEY");
  return value;
}
function config(){return {url:requiredUrl().replace(/\/+$/, ""),anon:publicKey()};}
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
function parseSignUp(value:unknown):SupabaseSignUpResult{
  const v=asRecord(value);
  const user=parseUser(v.user??v);
  const hasSession=typeof v.access_token==="string"&&typeof v.refresh_token==="string"&&typeof v.expires_in==="number";
  return {user,session:hasSession?parseSession(v):null};
}

export class SupabaseAuthClient {
  async signUpWithPassword(email:string,password:string):Promise<SupabaseSignUpResult>{
    return parseSignUp(await request("/auth/v1/signup",{method:"POST",body:JSON.stringify({email,password})}));
  }
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
