function profiles = makeSessionProfiles(scenarioRow, varargin)
%MAKESESSIONPROFILES Session-based 24-hour demand profiles for one scenario.
%
%   profiles = MAKESESSIONPROFILES(scenarioRow) builds the base-building
%   load profile and the EV charging REQUEST profile for one scenario row
%   (a one-row table from loadScenarios, or an equivalent struct).
%
%   This replaces the legacy "ports x charger kW x Gaussian" shape (ML-03,
%   hypotheses H1/H2/H5): the EV request is now derived from charging
%   SESSIONS - sessions_per_day, arrival window, dwell_hr (actually
%   consumed), energy_per_session_kWh, charger power, and charger
%   efficiency - so the profile peak reflects modeled demand, not the
%   theoretical simultaneous maximum of every port.
%
%   Name-value options:
%     'Mode'          - "deterministic_sessions" (default): sessions are
%                        placed at evenly spaced arrival times across the
%                        arrival window; fractional sessions_per_day is
%                        conserved exactly via per-session weights.
%                     - "stochastic": Monte Carlo draw. Session count ~
%                        Poisson(sessions_per_day); arrival times drawn
%                        from 'ArrivalDistribution'; requires 'Seed'.
%                     - "legacy_gaussian": reproduces the legacy Gaussian
%                        request shape (ports x charger kW at peak) for
%                        presentation continuity ONLY. Output is labeled
%                        legacy_gaussian and carries no session list, so
%                        the energy-aware controller refuses it.
%     'ArrivalDistribution' - "uniform" (default) or "triangular"
%                        (peak at the window midpoint); stochastic mode.
%     'Seed'          - nonnegative integer for rng() in stochastic mode
%                        (default 42). Recorded in the output for
%                        reproducibility.
%     'ChargerEfficiency' - grid-to-battery efficiency in (0,1],
%                        default 0.92, matching src/fcf_m2/config.py
%                        CHARGER_EFFICIENCY. energy_per_session_kWh is treated
%                        as battery-side energy; grid-side draw is
%                        power/efficiency-adjusted.
%     'DiversityFactor'   - scalar in (0,1] applied to the aggregate EV
%                        request (default 1.0 = no diversity credit).
%                        Document any value < 1 when presenting.
%     'TimeStepMinutes'   - profile resolution, default 5.
%
%   Output struct fields (units kW / kWh / hours):
%     t_hr, dt_hr              - time axis (0..24) and step
%     baseLoad_kW              - base building load profile
%     evRequest_kW             - aggregate grid-side EV request profile
%     sessions                 - table of per-vehicle sessions:
%                                arrival_hr, departure_hr, dwell_hr,
%                                energy_required_kWh (battery side),
%                                energy_required_grid_kWh,
%                                max_power_kW (grid side), weight,
%                                priority_class
%     energyRequested_kWh      - grid-side energy under the request curve
%     mode, params             - provenance echo
%
%   The request profile assumes each session draws charger power until its
%   energy need is met or the vehicle departs (dwell_hr consumed),
%   whichever comes first. Managed-charging strategies reshape this
%   request; see managedCharging.m.
%
%   Part of Milestone 2 V3 implementation (item ML-03).

    % ---------------------------------------------------------------
    % Options
    % ---------------------------------------------------------------
    p = inputParser;
    p.FunctionName = "makeSessionProfiles";
    addParameter(p, "Mode", "deterministic_sessions", ...
        @(v) ismember(string(v), ["deterministic_sessions", ...
                                  "stochastic", "legacy_gaussian"]));
    addParameter(p, "ArrivalDistribution", "uniform", ...
        @(v) ismember(string(v), ["uniform", "triangular"]));
    addParameter(p, "Seed", 42, @(v) isnumeric(v) && isscalar(v) && v >= 0);
    % 0.92, NOT 0.93. This was 0.93 while src/fcf_m2/config.py has always said
    % CHARGER_EFFICIENCY = 0.92 -- the same physical assumption carrying two different
    % values in the two halves of one model. Found by running the pipeline on the canonical
    % data and reconciling against the contract: every energy figure came out 1/0.93 of the
    % contract's, and the implied efficiency measured 0.9300 across all 120 rows.
    %
    % It survived because charger efficiency is not a contract field, so there was nothing
    % to reconcile it against -- which is precisely the class of drift the canonical contract
    % exists to prevent, hiding in the one quantity the contract does not carry.
    %
    % Python is the single producer (see data/contract/v1/README.md), so MATLAB follows it.
    % tests/test_cross_model_constants.py fails if these two ever disagree again.
    addParameter(p, "ChargerEfficiency", 0.92, ...
        @(v) isnumeric(v) && isscalar(v) && v > 0 && v <= 1);
    addParameter(p, "DiversityFactor", 1.0, ...
        @(v) isnumeric(v) && isscalar(v) && v > 0 && v <= 1);
    addParameter(p, "TimeStepMinutes", 5, ...
        @(v) isnumeric(v) && isscalar(v) && v > 0);
    parse(p, varargin{:});
    opt = p.Results;

    s = localRowToStruct(scenarioRow);

    % ---------------------------------------------------------------
    % Time axis
    % ---------------------------------------------------------------
    dt_hr = opt.TimeStepMinutes / 60;
    t_hr = (0:dt_hr:24).';
    nT = numel(t_hr);

    % ---------------------------------------------------------------
    % Base building load (legacy Gaussian day-shape retained for
    % continuity with the reviewed Phase 2 visuals; mean -> peak scaling)
    % ---------------------------------------------------------------
    daytimeShape = exp(-0.5 * ((t_hr - 14) / 4.5).^2);
    morningShape = 0.25 * exp(-0.5 * ((t_hr - 8) / 1.7).^2);
    eveningShape = 0.15 * exp(-0.5 * ((t_hr - 19) / 2.0).^2);
    shape = daytimeShape + morningShape + eveningShape;
    shape = shape / max(shape);
    baseLoad_kW = s.base_load_mean_kW + ...
        (s.base_load_peak_kW - s.base_load_mean_kW) * shape;

    % ---------------------------------------------------------------
    % EV request profile
    % ---------------------------------------------------------------
    eta = opt.ChargerEfficiency;
    mode = string(opt.Mode);

    sessions = localEmptySessionTable();
    evRequest_kW = zeros(nT, 1);

    if mode == "legacy_gaussian"
        % Presentation-continuity mode ONLY. Reproduces the legacy
        % worst-case shape: all recommended ports at full charger power
        % at the arrival-window midpoint. No session basis, no dwell use.
        center = (s.arrival_start_hr + s.arrival_end_hr) / 2;
        width = max((s.arrival_end_hr - s.arrival_start_hr) / 2, 0.5);
        arrivalShape = exp(-0.5 * ((t_hr - center) / width).^2);
        arrivalShape = arrivalShape / max(arrivalShape);
        evRequest_kW = s.ports * s.charger_power_kW * arrivalShape;
    else
        % Session-based modes.
        if mode == "stochastic"
            rng(opt.Seed, "twister");
            nSessions = localPoissonDraw(s.sessions_per_day);
            weights = ones(nSessions, 1);
            arrivals = localDrawArrivals(nSessions, ...
                s.arrival_start_hr, s.arrival_end_hr, ...
                string(opt.ArrivalDistribution));
        else
            % Deterministic: evenly spaced arrivals; fractional
            % sessions_per_day conserved exactly through weights.
            nSessions = max(1, ceil(s.sessions_per_day));
            if s.sessions_per_day <= 0
                nSessions = 0;
            end
            weights = ones(nSessions, 1);
            if nSessions > 0
                weights = weights * (s.sessions_per_day / nSessions);
                arrivals = localEvenArrivals(nSessions, ...
                    s.arrival_start_hr, s.arrival_end_hr);
            else
                arrivals = zeros(0, 1);
            end
        end

        if nSessions > 0
            dwell = repmat(s.dwell_hr, nSessions, 1);
            departure = min(arrivals + dwell, 24);
            eBatt = repmat(s.energy_per_session_kWh, nSessions, 1);
            eGrid = eBatt / eta;
            pMax = repmat(s.charger_power_kW, nSessions, 1);

            sessions = table( ...
                (1:nSessions).', arrivals, departure, ...
                departure - arrivals, eBatt, eGrid, pMax, weights, ...
                ones(nSessions, 1), ...
                'VariableNames', ["session_id", "arrival_hr", ...
                    "departure_hr", "dwell_hr", ...
                    "energy_required_kWh", "energy_required_grid_kWh", ...
                    "max_power_kW", "weight", "priority_class"]);

            % Uncontrolled request: each session draws charger power from
            % arrival until its grid-side energy is delivered or it
            % departs (dwell actually consumed - closes H1).
            for k = 1:nSessions
                chargeDuration_hr = min( ...
                    eGrid(k) / pMax(k), ...
                    departure(k) - arrivals(k));
                evRequest_kW = evRequest_kW + weights(k) * ...
                    localPulseProfile(t_hr, dt_hr, arrivals(k), ...
                        arrivals(k) + chargeDuration_hr, pMax(k), ...
                        eGrid(k) * min(1, (departure(k) - arrivals(k)) ...
                            * pMax(k) / max(eGrid(k), eps)));
            end
        end
    end

    % Aggregate diversity credit (documented assumption when < 1).
    evRequest_kW = evRequest_kW * opt.DiversityFactor;

    % ---------------------------------------------------------------
    % Assemble output
    % ---------------------------------------------------------------
    profiles.t_hr = t_hr;
    profiles.dt_hr = dt_hr;
    profiles.baseLoad_kW = baseLoad_kW;
    profiles.evRequest_kW = evRequest_kW;
    profiles.sessions = sessions;
    profiles.energyRequested_kWh = trapz(t_hr, evRequest_kW);
    profiles.mode = mode;
    profiles.params = opt;
    profiles.scenario = s;
    profiles.charger_efficiency = eta;
    profiles.label = sprintf("%s | %s | mode=%s", ...
        s.scenario_id, s.site_id, mode);
end

% =====================================================================
% Local helpers
% =====================================================================

function s = localRowToStruct(scenarioRow)
%LOCALROWTOSTRUCT Accept a one-row table or struct; return a plain struct.
    if istable(scenarioRow)
        if height(scenarioRow) ~= 1
            error("makeSessionProfiles:oneRowRequired", ...
                "Expected exactly one scenario row, got %d.", ...
                height(scenarioRow));
        end
        s = table2struct(scenarioRow);
    elseif isstruct(scenarioRow)
        s = scenarioRow;
    else
        error("makeSessionProfiles:badInput", ...
            "scenarioRow must be a one-row table or a struct.");
    end

    requiredFields = ["scenario_id", "site_id", "ports", ...
        "charger_power_kW", "base_load_mean_kW", "base_load_peak_kW", ...
        "arrival_start_hr", "arrival_end_hr", "dwell_hr", ...
        "sessions_per_day", "energy_per_session_kWh"];
    missing = setdiff(requiredFields, string(fieldnames(s)));
    if ~isempty(missing)
        error("makeSessionProfiles:missingFields", ...
            "Scenario row is missing field(s): %s.", ...
            strjoin(missing, ", "));
    end
end

function n = localPoissonDraw(lambda)
%LOCALPOISSONDRAW Poisson sample via Knuth's algorithm (base MATLAB only;
%   avoids a Statistics Toolbox dependency).
    if lambda <= 0
        n = 0;
        return;
    end
    L = exp(-lambda);
    n = 0;
    prod_u = rand();
    while prod_u > L
        n = n + 1;
        prod_u = prod_u * rand();
    end
end

function arrivals = localDrawArrivals(n, startHr, endHr, dist)
%LOCALDRAWARRIVALS Random arrival times within the window.
    u = rand(n, 1);
    switch dist
        case "triangular"
            % Symmetric triangular on [start, end], peak at midpoint,
            % via inverse-CDF transform.
            c = 0.5;
            arrivals = zeros(n, 1);
            lo = u < c;
            arrivals(lo) = sqrt(u(lo) * c);
            arrivals(~lo) = 1 - sqrt((1 - u(~lo)) * (1 - c));
            arrivals = startHr + arrivals * (endHr - startHr);
        otherwise  % uniform
            arrivals = startHr + u * (endHr - startHr);
    end
    arrivals = sort(arrivals);
end

function arrivals = localEvenArrivals(n, startHr, endHr)
%LOCALEVENARRIVALS Evenly spaced arrival times (midpoints of n bins).
    edges = linspace(startHr, endHr, n + 1).';
    arrivals = (edges(1:n) + edges(2:n+1)) / 2;
end

function prof = localPulseProfile(t_hr, dt_hr, tOn, tOff, p_kW, eTarget_kWh)
%LOCALPULSEPROFILE Rectangular charging pulse rasterized onto the grid,
%   with partial-step overlap so the discretized energy matches the
%   continuous pulse energy; final scaling pins energy to eTarget_kWh.
    prof = zeros(size(t_hr));
    if tOff <= tOn || p_kW <= 0
        return;
    end
    % Fraction of each step [t, t+dt) covered by [tOn, tOff).
    stepStart = t_hr;
    stepEnd = t_hr + dt_hr;
    overlap = max(0, min(stepEnd, tOff) - max(stepStart, tOn));
    prof = p_kW * (overlap / dt_hr);
    % Trapz-consistent energy correction: scale so integrated energy under
    % the profile equals the intended pulse energy (numerical fidelity).
    eNow = trapz(t_hr, prof);
    if eNow > 0 && eTarget_kWh > 0
        prof = prof * (eTarget_kWh / eNow);
    end
end

function tbl = localEmptySessionTable()
%LOCALEMPTYSESSIONTABLE Zero-row session table with the canonical schema.
    tbl = table( ...
        zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), ...
        zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), ...
        zeros(0, 1), ...
        'VariableNames', ["session_id", "arrival_hr", "departure_hr", ...
            "dwell_hr", "energy_required_kWh", ...
            "energy_required_grid_kWh", "max_power_kW", "weight", ...
            "priority_class"]);
end
