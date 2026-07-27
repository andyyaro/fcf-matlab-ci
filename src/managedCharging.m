function result = managedCharging(profiles, strategy, varargin)
%MANAGEDCHARGING Managed-charging strategies with strict energy accounting.
%
%   result = MANAGEDCHARGING(profiles, strategy, ...) applies one of three
%   strategies to the profiles produced by makeSessionProfiles:
%
%     'unmanaged'    - EV load equals the request profile; no control.
%     'clamp'        - the legacy instantaneous clamp:
%                      ev = min(request, max(siteCap - baseLoad, 0)).
%                      Refused energy is CURTAILED (never rescheduled) -
%                      this preserves the legacy behavior for comparison
%                      and is labeled as such (hypothesis H4).
%     'energy_aware' - deferral scheduler (ML-05): tracks each session's
%                      remaining grid-side energy need and departure
%                      deadline; allocates limited site headroom by
%                      priority class then earliest departure (EDF);
%                      defers load rather than discarding it; reports
%                      delivered vs unmet energy PER VEHICLE. Requires
%                      session-based profiles (refuses legacy_gaussian).
%
%   Energy balance invariant (validated internally to 1e-6 kWh relative):
%       requested_kWh = delivered_kWh + curtailed_kWh + unmet_kWh
%   with DISJOINT definitions:
%       curtailed - energy refused with no rescheduling intent
%                   (clamp strategy only);
%       unmet     - energy the scheduler intended to deliver before the
%                   vehicle's departure but could not (energy_aware only);
%       deferred_kWh is reported separately (energy shifted later in time
%                   relative to the request) and is NOT part of the
%                   balance: deferred-and-recovered energy is delivered.
%
%   Name-value options:
%     'SiteCapacity_kW'   - finite site capacity limit (from
%                           capacityGuard). REQUIRED for 'clamp' and
%                           'energy_aware'; ignored by 'unmanaged'.
%     'Guard'             - capacityGuard struct; carried into the result
%                           so plots/tables inherit the placeholder
%                           banner. If provided and it defines capacity,
%                           'SiteCapacity_kW' may be omitted.
%     'CommsLoss'         - logical (default false). energy_aware only:
%                           simulates loss of the control channel; every
%                           active session falls back to the fail-safe
%                           static limit below (no dynamic allocation).
%     'FailSafeFraction'  - fraction of charger power used as the
%                           fail-safe static per-vehicle limit under
%                           comms loss (default 0.5). A conservative
%                           default so a dead control link degrades to a
%                           bounded, predictable load.
%
%   Result struct: strategy, t_hr, ev_kW, total_kW, requested_kWh,
%   delivered_kWh, curtailed_kWh, unmet_kWh, deferred_kWh,
%   balance_error_kWh, peak_total_kW, overload_kW (vs capacity when
%   defined), per_vehicle (table, energy_aware), notes, guard.
%
%   Part of Milestone 2 V3 implementation (item ML-05).

    validStrategies = ["unmanaged", "clamp", "energy_aware"];
    strategy = string(strategy);
    if ~ismember(strategy, validStrategies)
        error("managedCharging:badStrategy", ...
            "Unknown strategy '%s'. Valid: %s.", strategy, ...
            strjoin(validStrategies, ", "));
    end

    p = inputParser;
    p.FunctionName = "managedCharging";
    addParameter(p, "SiteCapacity_kW", NaN, ...
        @(v) isnumeric(v) && isscalar(v));
    addParameter(p, "Guard", struct.empty, @(v) isstruct(v));
    addParameter(p, "CommsLoss", false, ...
        @(v) islogical(v) && isscalar(v));
    addParameter(p, "FailSafeFraction", 0.5, ...
        @(v) isnumeric(v) && isscalar(v) && v > 0 && v <= 1);
    parse(p, varargin{:});
    opt = p.Results;

    t_hr = profiles.t_hr;
    dt_hr = profiles.dt_hr;
    nT = numel(t_hr);
    baseLoad_kW = profiles.baseLoad_kW;
    evRequest_kW = profiles.evRequest_kW;

    % Resolve site capacity.
    siteCap_kW = opt.SiteCapacity_kW;
    if ~isfinite(siteCap_kW) && ~isempty(opt.Guard) && ...
            isfield(opt.Guard, "capacity_kW")
        siteCap_kW = opt.Guard.capacity_kW;
    end

    notes = strings(0, 1);
    perVehicle = table();

    switch strategy
        % -------------------------------------------------------------
        case "unmanaged"
            ev_kW = evRequest_kW;
            requested_kWh = trapz(t_hr, evRequest_kW);
            delivered_kWh = requested_kWh;
            curtailed_kWh = 0;
            unmet_kWh = 0;
            deferred_kWh = 0;
            notes(end+1) = "No control applied; request served as-is.";

        % -------------------------------------------------------------
        case "clamp"
            localRequireCapacity(siteCap_kW, strategy);
            headroom_kW = max(siteCap_kW - baseLoad_kW, 0);
            ev_kW = min(evRequest_kW, headroom_kW);
            requested_kWh = trapz(t_hr, evRequest_kW);
            delivered_kWh = trapz(t_hr, ev_kW);
            curtailed_kWh = max(requested_kWh - delivered_kWh, 0);
            unmet_kWh = 0;
            deferred_kWh = 0;
            notes(end+1) = "Legacy instantaneous clamp: refused " + ...
                "energy is curtailed, never rescheduled (H4 behavior, " + ...
                "retained for comparison).";

        % -------------------------------------------------------------
        case "energy_aware"
            localRequireCapacity(siteCap_kW, strategy);
            if profiles.mode == "legacy_gaussian" || ...
                    height(profiles.sessions) == 0
                error("managedCharging:sessionsRequired", ...
                    "energy_aware requires session-based profiles " + ...
                    "(mode deterministic_sessions or stochastic). " + ...
                    "Profiles mode is '%s' with %d sessions.", ...
                    profiles.mode, height(profiles.sessions));
            end

            [ev_kW, perVehicle, schedNotes] = localEnergyAwareSchedule( ...
                profiles.sessions, t_hr, dt_hr, baseLoad_kW, ...
                siteCap_kW, opt.CommsLoss, opt.FailSafeFraction);
            notes = [notes; schedNotes];

            % Requested = deliverable-within-dwell grid energy per session
            % (identical basis to the request profile construction).
            requested_kWh = sum(perVehicle.requested_kWh);
            delivered_kWh = sum(perVehicle.delivered_kWh);
            unmet_kWh = sum(perVehicle.unmet_kWh);
            curtailed_kWh = 0;

            % Deferred energy: request served later than the uncontrolled
            % profile would have served it (informational only).
            cumReq = cumtrapz(t_hr, evRequest_kW);
            cumEv = cumtrapz(t_hr, ev_kW);
            deferred_kWh = max(max(cumReq - cumEv, [], "omitnan"), 0);
    end

    totalLoad_kW = baseLoad_kW + ev_kW;

    % ---------------------------------------------------------------
    % Energy balance check (hard invariant)
    % ---------------------------------------------------------------
    balanceError_kWh = requested_kWh - ...
        (delivered_kWh + curtailed_kWh + unmet_kWh);
    tol = 1e-6 * max(1, abs(requested_kWh));
    if abs(balanceError_kWh) > tol
        error("managedCharging:energyBalance", ...
            "Energy balance violated for strategy %s: requested=%.6f, " + ...
            "delivered=%.6f, curtailed=%.6f, unmet=%.6f " + ...
            "(error %.3e kWh).", strategy, requested_kWh, ...
            delivered_kWh, curtailed_kWh, unmet_kWh, balanceError_kWh);
    end

    if isfinite(siteCap_kW)
        overload_kW = max(totalLoad_kW - siteCap_kW, 0);
    else
        overload_kW = nan(nT, 1);
    end

    result = struct();
    result.strategy = strategy;
    result.t_hr = t_hr;
    result.ev_kW = ev_kW;
    result.total_kW = totalLoad_kW;
    result.site_capacity_kW = siteCap_kW;
    result.requested_kWh = requested_kWh;
    result.delivered_kWh = delivered_kWh;
    result.curtailed_kWh = curtailed_kWh;
    result.unmet_kWh = unmet_kWh;
    result.deferred_kWh = deferred_kWh;
    result.balance_error_kWh = balanceError_kWh;
    result.peak_total_kW = max(totalLoad_kW);
    result.peak_ev_kW = max(ev_kW);
    result.max_overload_kW = max(overload_kW);
    result.overload_kW = overload_kW;
    result.per_vehicle = perVehicle;
    result.comms_loss = opt.CommsLoss;
    result.notes = notes;
    result.guard = opt.Guard;
end

% =====================================================================
% Local functions
% =====================================================================

function localRequireCapacity(siteCap_kW, strategy)
%LOCALREQUIRECAPACITY Capacity-limited strategies refuse to run blind.
    if ~isfinite(siteCap_kW)
        error("managedCharging:capacityUndefined", ...
            "Strategy '%s' needs a finite site capacity, but none is " + ...
            "defined (service_capacity_kW and spare_capacity_kW are " + ...
            "empty in the canonical CSV). Either supply " + ...
            "'SiteCapacity_kW' explicitly as a labeled planning " + ...
            "assumption (see capacityGuard AssumedSiteCapacity_kW) or " + ...
            "run 'unmanaged'.", strategy);
    end
end

function [ev_kW, perVehicle, notes] = localEnergyAwareSchedule( ...
        sessions, t_hr, dt_hr, baseLoad_kW, siteCap_kW, ...
        commsLoss, failSafeFraction)
%LOCALENERGYAWARESCHEDULE Priority + earliest-departure-first deferral
%   scheduler over discrete time steps.
%
%   For each step the available EV headroom is max(cap - base, 0). Active
%   sessions (arrived, not departed, energy remaining) are sorted by
%   priority_class (ascending; 1 = highest priority), then departure
%   time, then arrival time. Each is granted up to weight*max_power_kW,
%   bounded by remaining need and remaining headroom. Remaining need not
%   delivered by departure is recorded as unmet for that vehicle.

    nT = numel(t_hr);
    nS = height(sessions);
    ev_kW = zeros(nT, 1);
    notes = strings(0, 1);

    % Requested (deliverable-within-dwell) grid energy per session -
    % same basis as the request profile in makeSessionProfiles.
    reqPerSession = zeros(nS, 1);
    for k = 1:nS
        deliverable = min(sessions.energy_required_grid_kWh(k), ...
            (sessions.departure_hr(k) - sessions.arrival_hr(k)) * ...
            sessions.max_power_kW(k));
        reqPerSession(k) = sessions.weight(k) * deliverable;
    end

    remaining_kWh = reqPerSession;   % weighted grid-side energy still owed
    delivered_kWh = zeros(nS, 1);

    if commsLoss
        notes(end+1) = sprintf("COMMS LOSS simulated: dynamic " + ...
            "allocation disabled; every active vehicle charges at the " + ...
            "fail-safe static limit (%.0f%% of charger power). Site " + ...
            "cap NOT enforced dynamically - this is the point of the " + ...
            "fail-safe study.", 100 * failSafeFraction);
    end

    for i = 1:nT
        tNow = t_hr(i);
        active = find(sessions.arrival_hr <= tNow & ...
                      sessions.departure_hr > tNow & ...
                      remaining_kWh > 1e-12);
        if isempty(active)
            continue;
        end

        if commsLoss
            % Fail-safe: static per-vehicle limit, no coordination.
            for idx = active.'
                pMax = failSafeFraction * sessions.max_power_kW(idx) * ...
                    sessions.weight(idx);
                p_kW = min(pMax, remaining_kWh(idx) / dt_hr);
                ev_kW(i) = ev_kW(i) + p_kW;
                delivered_kWh(idx) = delivered_kWh(idx) + p_kW * dt_hr;
                remaining_kWh(idx) = remaining_kWh(idx) - p_kW * dt_hr;
            end
        else
            headroom_kW = max(siteCap_kW - baseLoad_kW(i), 0);
            % Sort: priority class asc, then earliest departure, then
            % earliest arrival (stable tie-break).
            [~, order] = sortrows([sessions.priority_class(active), ...
                sessions.departure_hr(active), ...
                sessions.arrival_hr(active)]);
            queue = active(order);

            for idx = queue.'
                if headroom_kW <= 1e-12
                    break;
                end
                pMax = sessions.max_power_kW(idx) * sessions.weight(idx);
                p_kW = min([pMax, headroom_kW, ...
                    remaining_kWh(idx) / dt_hr]);
                ev_kW(i) = ev_kW(i) + p_kW;
                headroom_kW = headroom_kW - p_kW;
                delivered_kWh(idx) = delivered_kWh(idx) + p_kW * dt_hr;
                remaining_kWh(idx) = remaining_kWh(idx) - p_kW * dt_hr;
            end
        end
    end

    unmetPerSession = max(reqPerSession - delivered_kWh, 0);

    perVehicle = sessions;
    perVehicle.requested_kWh = reqPerSession;
    perVehicle.delivered_kWh = delivered_kWh;
    perVehicle.unmet_kWh = unmetPerSession;
    perVehicle.fully_served = unmetPerSession < ...
        max(1e-6, 1e-6 * max(reqPerSession));

    nShort = sum(~perVehicle.fully_served);
    if nShort > 0
        notes(end+1) = sprintf("%d of %d session(s) depart with unmet " + ...
            "energy (capacity-limited); see per_vehicle table.", ...
            nShort, nS);
    end
end
