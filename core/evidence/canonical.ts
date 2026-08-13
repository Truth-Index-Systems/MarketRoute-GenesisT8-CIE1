import {
  CLAIM_FINGERPRINT_VERSION,
  DEPENDENCE_FAMILY_VERSION,
  EVIDENCE_FINGERPRINT_VERSION,
  EVIDENCE_NORMALISATION_VERSION,
  type CanonicalClaim,
  type CanonicalEvidence,
  type CanonicalSource,
  type RawClaimInput,
  type RawEvidenceInput,
  type RawSourceInput,
} from "./contracts.js";

const TRACKING_PARAMS = new Set([
  "fbclid",
  "gclid",
  "dclid",
  "msclkid",
  "mc_cid",
  "mc_eid",
  "ref",
  "ref_src",
]);

function isTrackingParam(key: string): boolean {
  const lower = key.toLowerCase();
  return lower.startsWith("utm_") || TRACKING_PARAMS.has(lower);
}

export function normaliseText(value: string): string {
  return value.normalize("NFKC").replace(/\s+/g, " ").trim();
}

export function normaliseOptionalText(value?: string | null): string | null {
  if (value == null) return null;
  const normalised = normaliseText(value);
  return normalised.length > 0 ? normalised : null;
}

export function stableJson(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string") return JSON.stringify(value.normalize("NFKC"));
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("MARKETROUTE_NON_FINITE_JSON_NUMBER");
    return JSON.stringify(Object.is(value, -0) ? 0 : value);
  }
  if (typeof value === "boolean") return value ? "true" : "false";
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (typeof value === "object") {
    const object = value as Record<string, unknown>;
    const keys = Object.keys(object).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
  }
  throw new Error(`MARKETROUTE_UNSUPPORTED_JSON_TYPE:${typeof value}`);
}

export function sha256Hex(value: string): string {
  const bytes = new TextEncoder().encode(value);
  const bitLength = bytes.length * 8;
  const withOne = bytes.length + 1;
  const padding = (64 - ((withOne + 8) % 64)) % 64;
  const total = withOne + padding + 8;
  const buffer = new Uint8Array(total);
  buffer.set(bytes);
  buffer[bytes.length] = 0x80;
  const view = new DataView(buffer.buffer);
  const high = Math.floor(bitLength / 0x100000000);
  const low = bitLength >>> 0;
  view.setUint32(total - 8, high, false);
  view.setUint32(total - 4, low, false);

  const k = [
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
  ];
  let h0=0x6a09e667,h1=0xbb67ae85,h2=0x3c6ef372,h3=0xa54ff53a,h4=0x510e527f,h5=0x9b05688c,h6=0x1f83d9ab,h7=0x5be0cd19;
  const w = new Uint32Array(64);
  const rotr = (n:number,x:number) => (x >>> n) | (x << (32-n));
  for (let offset=0; offset<total; offset+=64) {
    for (let i=0;i<16;i++) w[i]=view.getUint32(offset+i*4,false);
    for (let i=16;i<64;i++) {
      const s0=(rotr(7,w[i-15]!)^rotr(18,w[i-15]!)^(w[i-15]!>>>3))>>>0;
      const s1=(rotr(17,w[i-2]!)^rotr(19,w[i-2]!)^(w[i-2]!>>>10))>>>0;
      w[i]=(w[i-16]!+s0+w[i-7]!+s1)>>>0;
    }
    let a=h0,b=h1,c=h2,d=h3,e=h4,f=h5,g=h6,h=h7;
    for (let i=0;i<64;i++) {
      const S1=(rotr(6,e)^rotr(11,e)^rotr(25,e))>>>0;
      const ch=((e&f)^((~e)&g))>>>0;
      const temp1=(h+S1+ch+k[i]!+w[i]!)>>>0;
      const S0=(rotr(2,a)^rotr(13,a)^rotr(22,a))>>>0;
      const maj=((a&b)^(a&c)^(b&c))>>>0;
      const temp2=(S0+maj)>>>0;
      h=g;g=f;f=e;e=(d+temp1)>>>0;d=c;c=b;b=a;a=(temp1+temp2)>>>0;
    }
    h0=(h0+a)>>>0;h1=(h1+b)>>>0;h2=(h2+c)>>>0;h3=(h3+d)>>>0;
    h4=(h4+e)>>>0;h5=(h5+f)>>>0;h6=(h6+g)>>>0;h7=(h7+h)>>>0;
  }
  return [h0,h1,h2,h3,h4,h5,h6,h7].map((x)=>x.toString(16).padStart(8,"0")).join("");
}

export function canonicaliseUrl(rawUrl: string): string {
  const url = new URL(normaliseText(rawUrl));
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("MARKETROUTE_UNSUPPORTED_SOURCE_PROTOCOL");
  }
  if (url.username || url.password) throw new Error("MARKETROUTE_SOURCE_URL_CREDENTIALS_FORBIDDEN");

  const originalProtocol = url.protocol;
  if ((originalProtocol === "https:" && url.port === "443") || (originalProtocol === "http:" && url.port === "80")) url.port = "";
  url.protocol = "https:";
  url.hostname = url.hostname.toLowerCase().replace(/^www\./, "");
  url.hash = "";

  const params = [...url.searchParams.entries()]
    .filter(([key]) => !isTrackingParam(key))
    .sort(([aKey, aValue], [bKey, bValue]) => aKey.localeCompare(bKey) || aValue.localeCompare(bValue));
  url.search = "";
  for (const [key, value] of params) url.searchParams.append(key, value);

  url.pathname = url.pathname.replace(/\/{2,}/g, "/");
  if (url.pathname.length > 1) url.pathname = url.pathname.replace(/\/+$/, "");
  return url.toString();
}

export function canonicalisePublisherDomain(value?: string | null): string | null {
  const text = normaliseOptionalText(value);
  if (!text) return null;
  const withoutScheme = text.replace(/^https?:\/\//i, "").split("/")[0] ?? "";
  const withoutPort = withoutScheme.replace(/:\d+$/, "");
  const lower = withoutPort.toLowerCase().replace(/^www\./, "");
  if (!lower || lower.includes(" ")) throw new Error("MARKETROUTE_INVALID_PUBLISHER_DOMAIN");
  return lower;
}

function isoOrNull(value?: string | null): string | null {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error("MARKETROUTE_INVALID_TIMESTAMP");
  return date.toISOString();
}

function requiredIso(value?: string | null): string {
  if (!value) return new Date().toISOString();
  const parsed = isoOrNull(value);
  if (!parsed) throw new Error("MARKETROUTE_INVALID_TIMESTAMP");
  return parsed;
}

export function canonicaliseSource(input: RawSourceInput): CanonicalSource {
  const canonicalUrl = input.url ? canonicaliseUrl(input.url) : null;
  const urlDomain = canonicalUrl ? canonicalisePublisherDomain(new URL(canonicalUrl).hostname) : null;
  const suppliedDomain = canonicalisePublisherDomain(input.publisherDomain);
  if (urlDomain && suppliedDomain && urlDomain !== suppliedDomain) {
    throw new Error("MARKETROUTE_PUBLISHER_DOMAIN_URL_MISMATCH");
  }
  const publisherDomain = urlDomain ?? suppliedDomain;
  const stableLocator = canonicalUrl ?? normaliseOptionalText(input.stableLocator);
  if (!stableLocator) throw new Error("MARKETROUTE_SOURCE_STABLE_LOCATOR_REQUIRED");

  const identityPayload = stableJson({
    version: EVIDENCE_NORMALISATION_VERSION,
    sourceKind: input.sourceKind,
    stableLocator,
  });
  const sourceIdentityFingerprint = sha256Hex(identityPayload);

  const familyIdentity = publisherDomain
    ? `publisher:${publisherDomain}`
    : `source:${input.sourceKind}:${sourceIdentityFingerprint}`;
  const dependenceFamilyKey = `${DEPENDENCE_FAMILY_VERSION}:${sha256Hex(familyIdentity)}`;

  return {
    sourceKind: input.sourceKind,
    canonicalUrl,
    publisherDomain,
    title: normaliseOptionalText(input.title),
    publishedAt: isoOrNull(input.publishedAt),
    stableLocator,
    sourceIdentityFingerprint,
    dependenceFamilyKey,
    normalisationVersion: EVIDENCE_NORMALISATION_VERSION,
    metadata: input.metadata ?? {},
  };
}

export function canonicaliseEvidence(source: CanonicalSource, input: RawEvidenceInput): CanonicalEvidence {
  const excerptText = normaliseOptionalText(input.excerptText);
  const structuredValue = input.structuredValue === undefined ? null : input.structuredValue;
  if (!excerptText && structuredValue === null) throw new Error("MARKETROUTE_EVIDENCE_CONTENT_REQUIRED");

  const observedAt = requiredIso(input.observedAt);
  const originPublishedAt = isoOrNull(input.originPublishedAt);
  const extractionVersion = normaliseOptionalText(input.extractionVersion);
  const payload = stableJson({
    version: EVIDENCE_FINGERPRINT_VERSION,
    sourceIdentityFingerprint: source.sourceIdentityFingerprint,
    tenantScopeOrganisationId: input.tenantScopeOrganisationId ?? null,
    subjectType: input.subjectType,
    subjectId: input.subjectId,
    evidenceKind: input.evidenceKind,
    excerptText,
    structuredValue,
    originPublishedAt,
    extractionMethod: input.extractionMethod,
    extractionVersion,
  });

  return {
    tenantScopeOrganisationId: input.tenantScopeOrganisationId ?? null,
    subjectType: input.subjectType,
    subjectId: input.subjectId,
    evidenceKind: input.evidenceKind,
    excerptText,
    structuredValue,
    observedAt,
    originPublishedAt,
    extractionMethod: input.extractionMethod,
    extractionVersion,
    evidenceFingerprint: sha256Hex(payload),
    fingerprintVersion: EVIDENCE_FINGERPRINT_VERSION,
  };
}

export function canonicaliseClaim(input: RawClaimInput): CanonicalClaim {
  const claimKey = normaliseText(input.claimKey).toLowerCase();
  const predicate = normaliseText(input.predicate).toLowerCase();
  if (!claimKey || !predicate) throw new Error("MARKETROUTE_CLAIM_KEY_AND_PREDICATE_REQUIRED");
  const canonicalValueText = normaliseOptionalText(input.canonicalValueText);
  const payload = stableJson({
    version: CLAIM_FINGERPRINT_VERSION,
    tenantScopeOrganisationId: input.tenantScopeOrganisationId ?? null,
    subjectType: input.subjectType,
    subjectId: input.subjectId,
    claimKey,
    predicate,
    object: input.object,
    canonicalValueText,
  });
  return {
    tenantScopeOrganisationId: input.tenantScopeOrganisationId ?? null,
    subjectType: input.subjectType,
    subjectId: input.subjectId,
    claimKey,
    predicate,
    object: input.object,
    canonicalValueText,
    claimFingerprint: sha256Hex(payload),
    fingerprintVersion: CLAIM_FINGERPRINT_VERSION,
  };
}
