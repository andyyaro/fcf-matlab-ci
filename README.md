# fcf-matlab-ci — downstream MATLAB validation harness

**This is not the source of truth. It is a downstream copy, and it is never hand-edited.**

## What this is

A public repository whose only purpose is to execute a MATLAB site-load model in GitHub
Actions. Public repositories receive MathWorks MATLAB and Simulink licences automatically,
which is the only reason this repository exists.

It holds three things: nine model sources, six test files, and one **synthetic** scenario
fixture. Nothing else.

## What this is not

- **Not the project.** The model this validates belongs to a private repository. That
  repository is the single source of truth for every one of these files.
- **Not project data.** `data/harness_scenarios_synthetic.csv` is **fabricated**. Its site
  ids are `SYN001`–`SYN012`, its loads and demand values are generated, and **no row
  corresponds to any real facility**. It exists to exercise code paths, not to describe
  anywhere. It is not a redaction of a real file; it was generated from scratch.
- **Not a source of findings.** No site ranking, readiness score, cost conclusion, or study
  result appears here, and none may be added. This repository publishes *methodology*.
  Anything you can compute from it is a property of the method, not of any real place.

## The model, briefly

A session-based site electrical load model for public EV charging:

- `loadScenarios` — reads and hard-validates the scenario table; horizons are read **from the
  data**, never hard-coded
- `capacityGuard` — a **fail-closed** provenance gate. Unless electrical capacity is confirmed
  by a utility or facility record, the model refuses to emit a feasibility claim at all. This
  is the most important thing in the repository.
- `makeSessionProfiles` — demand from charging *sessions* (arrivals, dwell actually consumed,
  energy per session), not from the theoretical simultaneous maximum of every port
- `managedCharging` — unmanaged, a legacy instantaneous clamp, and an energy-aware deferral
  scheduler, with a hard energy-balance invariant
- `electricalEconomics` — apparent-power and demand-charge comparison. With no tariff supplied
  it reports `tariff_not_supplied` rather than inventing a cost.
- `buildSimulinkModel` — **illustrative only**. Every metric is computed by the plain MATLAB
  pipeline, which runs without Simulink. The model exists to visualise signal flow.

## Synchronisation

Sync is **one-directional: private → public, automated, and hash-verified.**

A fix made here instead of upstream creates two diverging MATLAB layers, which is exactly the
failure the upstream project's contract discipline exists to prevent. If something here is
wrong, fix it upstream; the change arrives on the next sync. Pull requests that edit `src/` or
`tests/` cannot be accepted for that reason.

## Running it

```
matlab -batch "addpath('src'); runtests('tests')"
matlab -batch "addpath('src'); run_all_scenarios('CsvFile','data/harness_scenarios_synthetic.csv')"
```

## Licence

**No licence has been selected. All rights reserved by the team.**

This is deliberate and matches the upstream repository. Absence of a licence is not an
invitation to assume permissive terms.
