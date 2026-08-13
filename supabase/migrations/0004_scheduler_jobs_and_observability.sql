BEGIN;

CREATE TABLE public.scheduler_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  runner_key text NOT NULL,
  status text NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','SUCCEEDED','PARTIAL','FAILED','CANCELLED')),
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object')
);

CREATE TABLE public.scheduler_leases (
  lease_key text PRIMARY KEY,
  owner_run_id uuid NOT NULL REFERENCES public.scheduler_runs(id) ON DELETE CASCADE,
  acquired_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  heartbeat_at timestamptz NOT NULL DEFAULT now(),
  CHECK (expires_at > acquired_at)
);

CREATE TABLE public.background_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid REFERENCES public.organisations(id) ON DELETE CASCADE,
  campaign_id uuid,
  job_type text NOT NULL,
  dedupe_key text NOT NULL,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RESERVED','RUNNING','SUCCEEDED','FAILED','CANCELLED','DEFERRED')),
  priority integer NOT NULL DEFAULT 100,
  payload_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload_json) = 'object'),
  available_at timestamptz NOT NULL DEFAULT now(),
  reserved_by_run_id uuid REFERENCES public.scheduler_runs(id) ON DELETE SET NULL,
  reserved_at timestamptz,
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  max_attempts integer NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 50),
  last_error_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (job_type, dedupe_key),
  CHECK (campaign_id IS NULL OR organisation_id IS NOT NULL),
  CONSTRAINT background_jobs_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE CASCADE
);

CREATE INDEX background_jobs_claim_idx ON public.background_jobs(status, available_at, priority, created_at);
CREATE INDEX background_jobs_scope_idx ON public.background_jobs(organisation_id, campaign_id, status);

CREATE TABLE public.background_job_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.background_jobs(id) ON DELETE CASCADE,
  scheduler_run_id uuid REFERENCES public.scheduler_runs(id) ON DELETE SET NULL,
  attempt_number integer NOT NULL CHECK (attempt_number > 0),
  status text NOT NULL CHECK (status IN ('RUNNING','SUCCEEDED','FAILED','TIMED_OUT','ABORTED')),
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  error_code text,
  telemetry_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(telemetry_json) = 'object'),
  UNIQUE (job_id, attempt_number)
);

CREATE INDEX background_job_attempts_job_idx ON public.background_job_attempts(job_id, attempt_number DESC);

CREATE TABLE public.ai_usage_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid REFERENCES public.organisations(id) ON DELETE SET NULL,
  campaign_id uuid,
  reasoning_run_id uuid REFERENCES public.reasoning_runs(id) ON DELETE SET NULL,
  provider text NOT NULL,
  model text NOT NULL,
  request_kind text NOT NULL,
  input_tokens bigint CHECK (input_tokens IS NULL OR input_tokens >= 0),
  output_tokens bigint CHECK (output_tokens IS NULL OR output_tokens >= 0),
  cost_usd numeric(18,8) CHECK (cost_usd IS NULL OR cost_usd >= 0),
  latency_ms integer CHECK (latency_ms IS NULL OR latency_ms >= 0),
  status text NOT NULL CHECK (status IN ('SUCCEEDED','FAILED','TIMED_OUT','CANCELLED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  CHECK (campaign_id IS NULL OR organisation_id IS NOT NULL),
  CONSTRAINT ai_usage_events_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE SET NULL
);

CREATE TABLE public.audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid REFERENCES public.organisations(id) ON DELETE SET NULL,
  actor_type text NOT NULL CHECK (actor_type IN ('USER','SYSTEM','SCHEDULER','MIGRATION')),
  actor_id text,
  event_type text NOT NULL,
  subject_type text,
  subject_id uuid,
  details_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details_json) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER background_jobs_touch_updated_at
BEFORE UPDATE ON public.background_jobs
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

ALTER TABLE public.scheduler_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scheduler_leases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.background_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.background_job_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_usage_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.scheduler_runs FROM anon, authenticated, service_role;
REVOKE ALL ON public.scheduler_leases FROM anon, authenticated, service_role;
REVOKE ALL ON public.background_jobs FROM anon, authenticated, service_role;
REVOKE ALL ON public.background_job_attempts FROM anon, authenticated, service_role;
REVOKE ALL ON public.ai_usage_events FROM anon, authenticated, service_role;
REVOKE ALL ON public.audit_events FROM anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE ON public.scheduler_runs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.scheduler_leases TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.background_jobs TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.background_job_attempts TO service_role;
GRANT SELECT, INSERT ON public.ai_usage_events TO service_role;
GRANT SELECT, INSERT ON public.audit_events TO service_role;

COMMIT;
