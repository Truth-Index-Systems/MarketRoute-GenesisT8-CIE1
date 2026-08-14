const STATUS_LABELS: Record<string, string> = {
  ACTIONABLE: "Ready to pursue",
  AUTHORITY_READY: "Ready for action",
  COMMERCIAL_CANDIDATE: "Commercial case confirmed",
  ROUTE_STRUCTURALLY_OPEN: "Route confirmed",
  CONTACT_AUTHORISED: "Contact confirmed",
  APPROVED: "Approved",
  SENT: "Sent",
  SUCCEEDED: "Completed",
  ACTIVE: "Active",
  KNOWN: "Known",
  REVIEWABLE: "Ready for review",
  SUPPORTED: "Well supported",
  RUNNING: "In progress",
  RESERVED: "Reserved",
  PENDING: "Pending",
  AUTOPILOT: "Autopilot",
  RESEARCH_REQUIRED: "More research needed",
  REVALIDATION_REQUIRED: "Needs revalidation",
  CONTACT_RESEARCH_REQUIRED: "Contact research needed",
  ROUTE_RESEARCH_REQUIRED: "Route research needed",
  RESEARCHING: "Researching",
  PAUSED: "Paused",
  DEFERRED: "Deferred",
  REWRITE: "Rewrite needed",
  NOT_ADMISSIBLE: "Not worth pursuing",
  CONTRADICTED: "Evidence conflicts",
  FAILED: "Failed",
  BLOCK: "Blocked",
  REJECTED: "Rejected",
  BLOCKED_STALE: "Blocked — stale",
  RECONCILIATION_REQUIRED: "Needs reconciliation",
  CLOSED: "Closed",
  SUSPENDED: "Suspended",
  CONTACT_NOT_APPLICABLE: "No named contact required",
  ROUTE_NOT_APPLICABLE: "No route required",
  ARCHIVED: "Archived",
  STALE: "Stale",
  UNRESOLVED: "Unresolved",
  OPEN: "Route open",
  CURRENT: "Current",
  HUMAN_ONLY: "Human approval",
  NONE: "None",
  NO_CURRENT_R4: "Commercial case not established",
  NO_CURRENT_R5: "Route not established",
  NO_CURRENT_R6: "Contact not established",
  NO_CURRENT_TRUTH: "Research not established",
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
  if (executableNow) return "Worth pursuing — reachable now";
  if (disposition === "ACTIONABLE" || disposition === "AUTHORITY_READY") return "Worth pursuing — action available";
  if (disposition === "REVIEWABLE") return "Worth pursuing — awaiting your review";
  if (disposition === "NOT_ADMISSIBLE") return "Not currently worth pursuing";
  if (disposition.includes("RESEARCH")) return "Promising, but more evidence is needed";
  return humanStatus(disposition);
}

export function truthStrength(value: number) {
  if (value >= 85) return "Strong research base";
  if (value >= 70) return "Good research base";
  if (value >= 50) return "Partial research base";
  return "Research still developing";
}

export function routeSummary(authorised: number, structural: number) {
  if (authorised > 0) return `${authorised} contact-qualified route${authorised === 1 ? "" : "s"}`;
  if (structural > 0) return `${structural} structural route${structural === 1 ? "" : "s"}`;
  return "No proven route yet";
}

export function researchPressureLabel(value: string) {
  const normal = humanStatus(value, "No active research pressure");
  return normal === "None" ? "No active research pressure" : normal;
}
