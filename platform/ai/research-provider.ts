import type { ResearchProvider, ResearchProviderExecutionContext, ResearchProviderResult, ResearchWorkUnit } from "../../core/research/index";

/** Provider boundary only. Build 10 intentionally does not couple Genesis to one model/search vendor. */
export interface ResearchAcquisitionProvider extends ResearchProvider {}

export class ResearchProviderError extends Error {
  constructor(message:string, public readonly costUsd:number|undefined){super(message);this.name="ResearchProviderError";}
}
export class UnconfiguredResearchProvider implements ResearchAcquisitionProvider {
  async execute(_unit: ResearchWorkUnit, _context: ResearchProviderExecutionContext): Promise<ResearchProviderResult> {
    throw new ResearchProviderError("MARKETROUTE_RESEARCH_PROVIDER_NOT_CONFIGURED",0);
  }
}
