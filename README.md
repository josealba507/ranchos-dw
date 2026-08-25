# ranchos-dw

[![CI](https://github.com/josealba507/ranchos-dw/actions/workflows/ci.yml/badge.svg)](https://github.com/josealba507/ranchos-dw/actions/workflows/ci.yml)

The analytics data warehouse behind a livestock management ERP running
in production — built solo, with dbt and BigQuery, and published
deliberately as a case study. The operational app (Firestore/Firebase,
the actual ERP the ranch staff use day to day) lives in a separate
private repository; its source is not exposed here.

- 5-layer architecture, 5 business domains, 52 dbt models and 3 SCD2 snapshots
- 359 automated data-quality tests, covering all 6 DAMA-DMBOK quality dimensions
- 26 source tables replicated 3x/day from the operational database
- Full pipeline orchestration on GCP: BigQuery Data Transfer + Cloud Workflows + Cloud Run Jobs, with email alerting on failure

## Architecture

```mermaid
flowchart LR
    L0[("L0 · raw\ndataset: ranchos\nEL replica, 3x/day")] --> L1
    L1["L1 · staging\ndataset: stg_ranchos\nviews, 1:1 with source"] --> L2S
    L1 --> L2I
    L2S["L2 · snapshots\ndataset: int_ranchos\nSCD2 history"] --> L3
    L2I["L2 · intermediate\nephemeral\nbusiness-rule joins"] --> L3
    L3["L3 · marts\ndataset: marts_ranchos\nstar schema, 5 domains"] --> L4
    L4["L4 · reporting\ndataset: rpt_ranchos\nviews — the only layer BI touches"]
    MD[("metadata_ranchos\ntest results, freshness,\nanomaly detection")]
```

One BigQuery dataset per layer, on purpose: BigQuery grants IAM
permissions at the dataset level, so this is how a reporting tool gets
read access to L4 without ever seeing raw or intermediate data.

[**Browse the full data catalog and lineage graph**](https://josealba507.github.io/ranchos-dw/) — every model, column, description and test, generated with `dbt docs`.

## What this answers for the business

The reporting layer exists to answer operational questions the people
running the farm actually ask. A few the current views support:

- **Which cows are producing below the herd average, and is that trend or noise?** Per-animal, per-day yield, summing both milkings — a distinction that matters, since reading a single milking silently halves a cow's day.
- **Which pregnancies are overdue, and by how long?** Palpation results carry the expected calving date and how many times it has been pushed back — so "she should have calved a month ago" is a query, not someone's recollection.
- **Which treated animals are still inside their milk withdrawal period?** Every treatment records its withdrawal days. This is a food-safety question with a real cost attached to getting it wrong.
- **Is delivered milk holding its quality, and how does that track against the price paid per liter?** Microbiology and composition are sampled independently of delivery, so the two are joined on farm and date rather than assumed to arrive together.
- **Where is the money going by category, and how does that shift between the dry and rainy seasons?** The date dimension carries the season, so seasonality is a group-by instead of a manual date range.

## Engineering decisions worth reading

The full decision log lives in `docs/` and `CLAUDE.md`, in Spanish (the
project's working language) — each entry documents not just what was
built, but what broke first and why. A few worth the click:

- [**Data governance as executable tests, not a slide deck**](docs/dama_governance.md) — every DAMA-DMBOK quality dimension maps to a real, runnable dbt test, not a policy document nobody enforces.
- [**A snapshot bug that only shows up with real historical data**](docs/checkpoint2_movimientos_insumos.md) — the first `dbt snapshot` run assigns `dbt_valid_from = now()` to every row, which silently breaks point-in-time joins against older facts. Fixed with a fallback join, caught by actually inspecting output data instead of trusting green tests.
- [**A reconciliation test that "failed" on purpose**](docs/fase5_reconciliacion_raw.md) — comparing row counts against the live operational source (not just the replica) surfaced a transient false positive, traced to its root cause instead of being patched away.
- [**Orchestrating the pipeline on GCP, with the real bugs included**](docs/fase_orquestacion_dbt.md) — BigQuery Data Transfer, Cloud Workflows, Cloud Run Jobs and Cloud Build wired together, plus the 5 actual issues hit building it (not the sanitized version).
- [**Verifying an alert by actually breaking something**](docs/fase6_alarmas_tecnicas.md) — a forced failure test that revealed the first attempt didn't even count as a failure to dbt, before the second one proved the alert fired end to end.
- [**The alert fired for real, and the runbook was wrong**](docs/incidente_dbt_scratch_prod_y_timeout.md) — a production alert fired; the first diagnostic command in the runbook I had written turned out to have never been run, and didn't work. Three separate root causes underneath, including tests verified only against `dev` that had been failing in `prod` for days. The pipeline went from 34 minutes to 13.

This repo is also a working example of disciplined AI-assisted development — see [`CLAUDE.md`](CLAUDE.md) for the collaboration rules and the full decision log.

## Roadmap

- A metrics layer in L4 with explicit grain, consumed by both BI and agents.
- A BI dashboard on Looker Studio reading only from L4, declared as a dbt exposure.
- An MCP server exposing business-scoped query tools over L4, restricted by IAM to the reporting dataset.

## Stack

dbt-core + dbt-bigquery, BigQuery Data Transfer Service, Cloud
Workflows, Cloud Run Jobs, Cloud Build, Cloud Monitoring, Elementary
(anomaly detection), sqlfluff.

## More

Local setup, day-to-day commands, and full pipeline/orchestration
detail: [`docs/setup.md`](docs/setup.md).

More about the author: [joseluisalba.com](https://joseluisalba.com)

---

Source-available as a case study. All rights reserved.
