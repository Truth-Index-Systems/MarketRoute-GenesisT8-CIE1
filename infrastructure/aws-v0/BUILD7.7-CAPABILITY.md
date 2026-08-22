# AWS V0 Build 7.7 — Evidence-Grounded Company Understanding

Status: SOURCE CERTIFICATION TARGET
Live provider certification: PENDING AWS BEDROCK QUOTA

## Purpose

Build 7.7 adds the first non-synthetic MarketRoute semantic capability behind the provider-neutral AI boundary: evidence-grounded company understanding.

The capability accepts a bounded set of supplied evidence facts and returns only structured semantic interpretation. Every semantic statement must cite one or more evidence IDs from the supplied set.

## Authority boundary

AI may:
- summarise what a company appears to do;
- identify evidence-grounded business activities;
- identify evidence-grounded offerings;
- identify evidence-grounded customer types;
- identify neutral operating signals;
- express semantic uncertainty and unresolved questions.

AI may not:
- adjudicate Truth Index truth;
- calculate CIE/UDOSIB commercial mathematics;
- score or rank opportunities, routes, contacts, organisations, or execution decisions;
- persist canonical state;
- invent evidence identifiers or unsupported facts.

## Security / provenance controls

- Evidence content is explicitly treated as untrusted data, never instructions.
- Instructions embedded inside evidence must not be followed.
- Input evidence IDs are bounded and unique.
- Output evidence references are allow-listed against the supplied evidence set.
- Every grounded statement requires at least one evidence ID.
- Structured output is closed with `additionalProperties: false` and is revalidated locally.
- Bedrock remains non-streaming and accessible only through the server-side provider adapter.
- No new HTTP route is introduced by Build 7.7.
- No canonical persistence path is introduced.

## Live-provider status

The AWS Bedrock integration has reached the provider successfully, but live Sonnet 4.5 inference is currently blocked by the AWS account's applied token quota. Build 7.7 source and fixture/static certification can proceed independently; live quality, usage, cost, and final provider certification remain pending quota activation.
