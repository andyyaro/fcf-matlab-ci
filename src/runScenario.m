function out = runScenario(scenarioRow, varargin)
%RUNSCENARIO End-to-end pipeline for one scenario row.
%
%   out = RUNSCENARIO(scenarioRow) runs, for one row of the canonical
%   scenario table:
%       capacityGuard -> makeSessionProfiles -> managedCharging
%       (unmanaged + capacity-limited strategies when possible)
%       -> electricalEconomics -> flat summary metrics.
%
%   Everything runs in base MATLAB; Simulink is NOT required (the
%   optional Simulink layer in buildSimulinkModel.m is illustrative and
%   not load-bearing).
%
%   Name-value options (all forwarded where relevant):
%     'GuardMode'            - "planning_illustration" (default) or
%                              "feasibility" (errors unless verified
%                              capacity - fail-closed by design).
%     'AssumedSiteCapacity_kW' - explicit labeled planning assumption
%                              when the CSV defines no capacity value.
%     'ProfileMode'          - forwarded to makeSessionProfiles 'Mode'
%                              (default "deterministic_sessions").
%     'Seed'                 - stochastic seed (default 42).
%     'ChargerEfficiency'    - default 0.93.
%     'DiversityFactor'      - default 1.0.
%     'Tariff'               - optional tariff struct (see
%                              electricalEconomics).
%     'CommsLoss'            - energy_aware comms-loss study flag.
%
%   Output struct fields:
%     scenario   - scenario row echoed as struct
%     guard      - capacityGuard struct (carries placeholder banner)
%     profiles   - makeSessionProfiles output
%     results    - struct with fields unmanaged / clamp / energy_aware
%                  (capacity-limited fields present only when a finite
%                  capacity exists; otherwise skipped and recorded in
%                  skipped_strategies)
%     econ       - electricalEconomics output (vs best managed result)
%     metrics    - flat one-row struct for results tables (see
%                  run_all_scenarios.m)
%     skipped_strategies - string array with reasons
%
%   Part of Milestone 2 V3 implementation (pipeline assembly).

    p = inputParser;
    p.FunctionName = "runScenario";
    addParameter(p, "GuardMode", "planning_illustration", ...
        @(v) ismember(string(v), ["feasibility", "planning_illustration"]));
    addParameter(p, "AssumedSiteCapacity_kW", NaN, ...
        @(v) isnumeric(v) && isscalar(v));
    addParameter(p, "ProfileMode", "deterministic_sessions", ...
        @(v) ismember(string(v), ["deterministic_sessions", ...
            "stochastic", "legacy_gaussian"]));
    addParameter(p, "Seed", 42, @(v) isnumeric(v) && isscalar(v));
    addParameter(p, "ChargerEfficiency", 0.93, ...
        @(v) isnumeric(v) && isscalar(v) && v > 0 && v <= 1);
    addParameter(p, "DiversityFactor", 1.0, ...
        @(v) isnumeric(v) && isscalar(v) && v > 0 && v <= 1);
    addParameter(p, "Tariff", struct.empty, @(v) isstruct(v));
    addParameter(p, "CommsLoss", false, ...
        @(v) islogical(v) && isscalar(v));
    parse(p, varargin{:});
    opt = p.Results;

    % ---------------------------------------------------------------
    % 1. Capacity guard (fail-closed provenance gate)
    % ---------------------------------------------------------------
    guard = capacityGuard(scenarioRow, ...
        "Mode", opt.GuardMode, ...
        "AssumedSiteCapacity_kW", opt.AssumedSiteCapacity_kW);

    % ---------------------------------------------------------------
    % 2. Demand profiles (session-based by default)
    % ---------------------------------------------------------------
    profiles = makeSessionProfiles(scenarioRow, ...
        "Mode", opt.ProfileMode, ...
        "Seed", opt.Seed, ...
        "ChargerEfficiency", opt.ChargerEfficiency, ...
        "DiversityFactor", opt.DiversityFactor);

    % ---------------------------------------------------------------
    % 3. Charging strategies
    % ---------------------------------------------------------------
    results = struct();
    skipped = strings(0, 1);

    results.unmanaged = managedCharging(profiles, "unmanaged", ...
        "Guard", guard);

    if guard.capacity_defined
        results.clamp = managedCharging(profiles, "clamp", ...
            "SiteCapacity_kW", guard.capacity_kW, "Guard", guard);

        if string(opt.ProfileMode) == "legacy_gaussian"
            skipped(end+1) = "energy_aware: skipped_legacy_gaussian_mode";
        else
            results.energy_aware = managedCharging(profiles, ...
                "energy_aware", ...
                "SiteCapacity_kW", guard.capacity_kW, ...
                "Guard", guard, ...
                "CommsLoss", opt.CommsLoss);
        end
    else
        skipped(end+1) = "clamp: skipped_no_capacity_defined";
        skipped(end+1) = "energy_aware: skipped_no_capacity_defined";
    end

    % ---------------------------------------------------------------
    % 4. Economics (managed = energy_aware when available, else clamp,
    %    else unmanaged-vs-unmanaged with no reduction)
    % ---------------------------------------------------------------
    if isfield(results, "energy_aware")
        managedResult = results.energy_aware;
    elseif isfield(results, "clamp")
        managedResult = results.clamp;
    else
        managedResult = results.unmanaged;
    end

    econ = electricalEconomics(results.unmanaged, managedResult, ...
        "ChargerEfficiency", opt.ChargerEfficiency, ...
        "Guard", guard, ...
        "Tariff", opt.Tariff);

    % ---------------------------------------------------------------
    % 5. Flat metrics row
    % ---------------------------------------------------------------
    s = profiles.scenario;
    metrics = struct();
    metrics.scenario_id = string(s.scenario_id);
    metrics.site_id = string(s.site_id);
    metrics.horizon_year = double(s.horizon_year);
    metrics.case_label = string(localFieldOr(s, "case_label", "unknown"));
    metrics.profile_mode = string(profiles.mode);
    metrics.capacity_basis = guard.capacity_basis;
    metrics.capacity_verified = guard.is_verified;
    metrics.capacity_kW = guard.capacity_kW;
    metrics.energy_requested_kWh = results.unmanaged.requested_kWh;
    metrics.peak_base_kW = max(profiles.baseLoad_kW);
    metrics.peak_unmanaged_kW = results.unmanaged.peak_total_kW;

    metrics.peak_clamp_kW = NaN;
    metrics.curtailed_clamp_kWh = NaN;
    metrics.peak_energy_aware_kW = NaN;
    metrics.unmet_energy_aware_kWh = NaN;
    metrics.deferred_energy_aware_kWh = NaN;
    if isfield(results, "clamp")
        metrics.peak_clamp_kW = results.clamp.peak_total_kW;
        metrics.curtailed_clamp_kWh = results.clamp.curtailed_kWh;
    end
    if isfield(results, "energy_aware")
        metrics.peak_energy_aware_kW = results.energy_aware.peak_total_kW;
        metrics.unmet_energy_aware_kWh = results.energy_aware.unmet_kWh;
        metrics.deferred_energy_aware_kWh = ...
            results.energy_aware.deferred_kWh;
    end

    metrics.service_check = econ.service_check;
    metrics.cost_status = econ.cost_status;
    metrics.demand_charge_savings_usd_month = ...
        econ.demand_charge_savings_usd_month;
    metrics.placeholder_banner = guard.placeholder_banner;
    metrics.skipped_strategies = strjoin(skipped, "; ");
    if metrics.skipped_strategies == ""
        metrics.skipped_strategies = "none";
    end

    out = struct();
    out.scenario = s;
    out.guard = guard;
    out.profiles = profiles;
    out.results = results;
    out.econ = econ;
    out.metrics = metrics;
    out.skipped_strategies = skipped;
    out.options = opt;
end

function v = localFieldOr(s, fieldName, defaultValue)
%LOCALFIELDOR Field value when present, else the default.
    if isfield(s, fieldName)
        v = s.(fieldName);
    else
        v = defaultValue;
    end
end
