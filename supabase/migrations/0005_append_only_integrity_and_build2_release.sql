BEGIN;

CREATE OR REPLACE FUNCTION public.marketroute_reject_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'MARKETROUTE_APPEND_ONLY_RELATION:%', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER source_acquisitions_append_only
BEFORE UPDATE OR DELETE ON public.source_acquisitions
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER evidence_items_append_only
BEFORE UPDATE OR DELETE ON public.evidence_items
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER claims_append_only
BEFORE UPDATE OR DELETE ON public.claims
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER claim_supersessions_append_only
BEFORE UPDATE OR DELETE ON public.claim_supersessions
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER claim_evidence_links_append_only
BEFORE UPDATE OR DELETE ON public.claim_evidence_links
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER reasoning_artifacts_append_only
BEFORE UPDATE OR DELETE ON public.reasoning_artifacts
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER authority_records_append_only
BEFORE UPDATE OR DELETE ON public.authority_records
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER authority_events_append_only
BEFORE UPDATE OR DELETE ON public.authority_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER opportunity_human_reviews_append_only
BEFORE UPDATE OR DELETE ON public.opportunity_human_reviews
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER ai_usage_events_append_only
BEFORE UPDATE OR DELETE ON public.ai_usage_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER audit_events_append_only
BEFORE UPDATE OR DELETE ON public.audit_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

REVOKE ALL ON FUNCTION public.marketroute_reject_mutation() FROM PUBLIC;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
) VALUES (
  'MRV2-BUILD2-CONSTITUTIONAL-SCHEMA',
  2,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'authority_writers', 0,
    'legacy_runtime_dependencies', false,
    'workflow_separate_from_authority', true,
    'evidence_append_only', true
  )
);

NOTIFY pgrst, 'reload schema';

COMMIT;
