import { ResearchRepository } from "../../platform/database/research-repository";
import { ResearchPlanningService } from "./service";

export class ResearchPlanningAutomationService {
  constructor(
    private readonly repository: ResearchRepository,
    private readonly planner: ResearchPlanningService,
  ) {}

  async runCycle(command: { maxPlanningTargets?: number; referenceTime?: string } = {}) {
    const at = (command.referenceTime ? new Date(command.referenceTime) : new Date()).toISOString();
    const maxPlanning = Math.max(0, Math.min(command.maxPlanningTargets ?? 100, 1_000));
    const targets = await this.repository.planningTargets(maxPlanning);
    let plannedWorkUnits = 0;
    let emptyPlans = 0;

    for (const target of targets) {
      const result = await this.planner.planCompany({
        organisationId: target.organisation_id,
        campaignId: target.campaign_id,
        companyId: target.company_id,
        referenceTime: command.referenceTime ? at : new Date().toISOString(),
      });
      plannedWorkUnits += result.persisted.createdWorkUnits;
      if (result.plan.workUnits.length === 0) emptyPlans += 1;
    }

    return {
      status: "SUCCEEDED" as const,
      planningTargets: targets.length,
      plannedWorkUnits,
      emptyPlans,
      workersRequired: false as const,
    };
  }
}
