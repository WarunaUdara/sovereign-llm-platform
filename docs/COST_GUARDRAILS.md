# Cost guardrails

## Facts this policy rests on

- The trial credit is a subsidy, not an always-free entitlement. Its end date is shown in Billing and was about 4 days away on 2026-10-29.
- Free-tier credit covers one cluster management fee (see [architecture-plan.md](architecture/architecture-plan.md) for sources). Nodes, load balancers, NAT, disks, egress, and logs are billed.
- Budget alerts only notify. They do not stop spend. Spend caps cover only selected services.
- Free Trial accounts get no GPU quota by default.
- Do not upgrade the billing account to get around a limit.

## Policy

1. **Default profile is local and costs $0.** `task up-local` creates only a local kind cluster and makes no cloud API call.
2. **No cloud resource exists unless every gate below passes.** Gates are checked by a human and written into `evidence/cloud-gate.md` with a timestamp.
   - [ ] Billing account state and remaining credit read from the Billing console, not estimated.
   - [ ] Trial end date confirmed in the console.
   - [ ] Pricing calculator estimate for the exact footprint (one zonal Standard cluster, one small node pool, one external IP if any) written down, with the number of hours the run will last.
   - [ ] Estimate is under 20% of the remaining credit, leaving a margin for mistakes.
   - [ ] Teardown script tested in dry-run on the local profile first.
   - [ ] A hard stop time is written down and a reminder is set.
3. **Budget alert at $1 and at 50% of remaining credit**, created before any resource exists. These are notifications only.
4. **Time box.** A cloud run ends at the stop time regardless of progress. Teardown starts then.
5. **Teardown order:** delete external IP and load balancer; delete workloads; delete cluster; sweep labeled resources; check inventory; delete the project only if inventory is not clean and the project is disposable.
6. **Evidence of zero spend:** after teardown, record the billing summary and resource inventory in `evidence/`.

## Local cost

Local cost is electricity and disk. Model cache is about 470 MB; kind images are a few GB. Docker VM memory is set in Docker Desktop.

## Unknowns to measure, not assume

- Actual Docker VM memory headroom with the model loaded under concurrent streams.
- Cloud cost per hour for the exact footprint (measured in the gated run).
- Whether the trial account allows the node pool sizes we would choose (quota check, gated run).
