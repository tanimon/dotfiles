---
id: json-validation-with-jq
trigger: when validating or extracting fields from JSON-formatted observations and event logs
confidence: 0.7
domain: workflow
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# JSON Validation and Extraction with jq

## Action
Use `jq` to validate observation structure and extract fields instead of shell string manipulation.

## Evidence
- Observed 3+ times in session 6e0cc6bc-f31a-498c-b915-9db7e712e48c
- Pattern: Commands like `head -1 observations.jsonl | jq -r '.tool_name // .event_type // "unknown"'` and `jq 'keys'` for schema inspection
- Used to validate observation format before analysis
- Last observed: 2026-04-04T14:34:43Z
