export function sameOriginOrThrow(request:Request):void{
  const origin=request.headers.get("origin"); const host=request.headers.get("host");
  if(origin&&host){const parsed=new URL(origin);if(parsed.host!==host)throw new Error("MARKETROUTE_CSRF_ORIGIN_MISMATCH");}
}
export function safeReturnPath(value:FormDataEntryValue|null,fallback="/app"):string{const v=typeof value==="string"?value:"";return v.startsWith("/app")&&!v.startsWith("//")?v:fallback;}
