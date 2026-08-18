const STATUS_LABELS: Record<string, string> = {
  ACTIONABLE: "Ready to contact",
  AUTHORITY_READY: "Ready for action",
  COMMERCIAL_CANDIDATE: "Strong opportunity",
  ROUTE_STRUCTURALLY_OPEN: "Possible route found",
  CONTACT_AUTHORISED: "Contact route ready",
  APPROVED: "Ready",
  SENT: "Sent",
  SUCCEEDED: "Completed",
  ACTIVE: "Active",
  KNOWN: "Known",
  REVIEWABLE: "Ready",
  SUPPORTED: "Well supported",
  RUNNING: "In progress",
  RESERVED: "Reserved",
  PENDING: "Pending",
  AUTOPILOT: "Autopilot",
  RESEARCH_REQUIRED: "More research needed",
  REVALIDATION_REQUIRED: "Needs another check",
  CONTACT_RESEARCH_REQUIRED: "Finding a better contact route",
  ROUTE_RESEARCH_REQUIRED: "Finding a route in",
  RESEARCHING: "Researching",
  PAUSED: "Paused",
  DEFERRED: "Deferred",
  REWRITE: "Rewrite needed",
  NOT_ADMISSIBLE: "Not a priority right now",
  CONTRADICTED: "Research needs resolving",
  FAILED: "Failed",
  BLOCK: "Blocked",
  REJECTED: "Rejected",
  BLOCKED_STALE: "Needs fresh research",
  RECONCILIATION_REQUIRED: "Needs another check",
  CLOSED: "Closed",
  SUSPENDED: "Suspended",
  CONTACT_NOT_APPLICABLE: "No named contact required",
  ROUTE_NOT_APPLICABLE: "No route required",
  ARCHIVED: "Archived",
  STALE: "Stale",
  UNRESOLVED: "Unresolved",
  OPEN: "Route available",
  CURRENT: "Current",
  HUMAN_ONLY: "Human approval",
  NONE: "None",
  NO_CURRENT_R4: "Why it fits is not clear yet",
  NO_CURRENT_R5: "No usable route yet",
  NO_CURRENT_R6: "No usable contact route yet",
  NO_CURRENT_TRUTH: "Research still developing",
};

export function humanStatus(value: string | null | undefined, fallback = "Not available") {
  if (!value) return fallback;
  if (STATUS_LABELS[value]) return STATUS_LABELS[value];
  return value
    .replaceAll("_", " ")
    .toLowerCase()
    .replace(/(^|\s)\S/g, (character) => character.toUpperCase());
}

export function commercialVerdict(disposition: string, executableNow: boolean) {
  if (executableNow) return "Strong opportunity — ready to contact";
  if (disposition === "ACTIONABLE" || disposition === "AUTHORITY_READY") return "Strong opportunity — ready to act";
  if (disposition === "REVIEWABLE") return "Strong opportunity";
  if (disposition === "NOT_ADMISSIBLE") return "Not a priority right now";
  if (disposition.includes("RESEARCH")) return "Promising — still researching";
  return humanStatus(disposition);
}

export function truthStrength(value: number) {
  if (value >= 85) return "Strong research base";
  if (value >= 70) return "Good research base";
  if (value >= 50) return "Partial research base";
  return "Research still developing";
}

export function routeSummary(authorised: number, structural: number) {
  if (authorised > 0) return `${authorised} ready contact route${authorised === 1 ? "" : "s"}`;
  if (structural > 0) return `${structural} possible route${structural === 1 ? "" : "s"}`;
  return "No usable route yet";
}

export function researchPressureLabel(value: string) {
  const normal = humanStatus(value, "No urgent research needed");
  return normal === "None" ? "No urgent research needed" : normal;
}
