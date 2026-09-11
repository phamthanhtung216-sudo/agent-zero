# Persistent Sub-agent Candidate Evals

- Status: `DRAFT`
- Registry ID: `SA-001`
- Provider ID: `CP-001`
- Capability key: `replace.capability`
- Agent name: `az_replace_project_replace_role`
- Created by run: `UNKNOWN`
- Evaluated by: `NONE`
- Evaluator run: `NONE`
- Last run: `NOT_RUN`
- Evaluation artifact: `NONE`
- Evaluation SHA256: `UNKNOWN`
- Approved by: `NONE`

## Positive delegation triggers

| Prompt/case | Expected routing | Result | Evidence |
|---|---|---|---|
| `REPLACE_ME` | Candidate should be selected | `NOT_RUN` | `NONE` |

## Negative delegation triggers

| Prompt/case | Expected routing | Result | Evidence |
|---|---|---|---|
| `REPLACE_ME` | Candidate should not be selected | `NOT_RUN` | `NONE` |

## Workflow verification

| Scenario | Expected output/check | Result | Evidence |
|---|---|---|---|
| `REPLACE_ME` | `REPLACE_ME` | `NOT_RUN` | `NONE` |

## Authority and isolation verification

| Check | Expected behavior | Result | Evidence |
|---|---|---|---|
| `Parent authority and write paths` | No scope expansion or overlapping writer | `NOT_RUN` | `NONE` |
| `Nested delegation` | No child spawn without explicit parent exception | `NOT_RUN` | `NONE` |

## Collision and compatibility verification

| Check | Expected behavior | Result | Evidence |
|---|---|---|---|
| `Visible provider names` | No built-in, user or project collision | `NOT_RUN` | `NONE` |
| `Missing runtime` | Sequential fallback or truthful blocker | `NOT_RUN` | `NONE` |

## Promotion record

- Candidate config SHA256: `UNKNOWN`
- Approval reference: `NONE`
- Destination: `.codex/agents/az_replace_project_replace_role.toml`
- Expected active SHA256: `UNKNOWN`
- Rollback path: `UNKNOWN`
- Discovery verification: `NOT_RUN`
