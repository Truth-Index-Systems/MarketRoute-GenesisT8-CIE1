import { createHmac,timingSafeEqual } from "node:crypto";
import { cookies } from "next/headers";

const COOKIE_NAME="mr_founder_session";
const SESSION_SECONDS=12*60*60;

function required(name:"FOUNDER_DASHBOARD_PASSWORD"|"FOUNDER_DASHBOARD_SESSION_SECRET"){
  const value=process.env[name]?.trim();
  if(!value)throw new Error(`MARKETROUTE_ENV_REQUIRED:${name}`);
  return value;
}
function equal(a:string,b:string){const aa=Buffer.from(a),bb=Buffer.from(b);return aa.length===bb.length&&timingSafeEqual(aa,bb);}
function signature(expires:string){const secret=required("FOUNDER_DASHBOARD_SESSION_SECRET");if(secret.length<32)throw new Error("MARKETROUTE_FOUNDER_SESSION_SECRET_TOO_SHORT");return createHmac("sha256",secret).update(`MARKETROUTE_FOUNDER:${expires}`).digest("hex");}

export function verifyFounderPassword(candidate:string){
  const expected=required("FOUNDER_DASHBOARD_PASSWORD");
  if(expected.length<12)throw new Error("MARKETROUTE_FOUNDER_PASSWORD_TOO_SHORT");
  return equal(candidate,expected);
}
export function createFounderSessionToken(){const expires=String(Math.floor(Date.now()/1000)+SESSION_SECONDS);return `${expires}.${signature(expires)}`;}
export function verifyFounderSessionToken(token:string|undefined){
  if(!token)return false;const [expires,sig,...rest]=token.split(".");if(rest.length||!expires||!sig||!/^[0-9]+$/.test(expires))return false;
  if(Number(expires)<=Math.floor(Date.now()/1000))return false;
  try{return equal(sig,signature(expires));}catch{return false;}
}
export async function founderSessionIsValid(){const store=await cookies();return verifyFounderSessionToken(store.get(COOKIE_NAME)?.value);}
export const founderSessionCookie={name:COOKIE_NAME,maxAge:SESSION_SECONDS};
export function founderSessionCookieOptions(maxAge=SESSION_SECONDS){return {httpOnly:true,secure:process.env.NODE_ENV==="production",sameSite:"strict" as const,path:"/dashboard",maxAge};}
