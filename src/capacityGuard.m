function guard = capacityGuard(scenarioRow, varargin)
%CAPACITYGUARD Fail-closed capacity-provenance gate (ML-04, hypothesis H3).
%
%   guard = CAPACITYGUARD(scenarioRow) evaluates the capacity provenance
%   of one scenario row and returns a guard struct. The controlled
%   vocabulary for capacity_basis is:
%
%       verified_utility     - confirmed by the serving utility
%       verified_facility    - confirmed from facility electrical records
%       engineering_estimate - engineer-derived estimate, not confirmed
%       planning_proxy       - proxy value adopted for planning only
%       placeholder          - declared placeholder (the current adapter
%                              CSV state for ALL 12 sites)
%       unknown              - no provenance recorded
%
%   Only verified_utility and verified_facility count as VERIFIED.
%
%   FAIL-CLOSED RULE: in 'feasibility' mode (the default), this function
%   ERRORS unless capacity_basis is verified. No code path in this
%   repository can emit a feasibility claim from placeholder capacity.
%
%   Name-value options:
%     'Mode' - "feasibility" (default): error unless verified.
%            - "planning_illustration": permitted for planning visuals;
%              the returned struct carries placeholder_banner text that
%              plotScenario.m MUST render on every capacity visual.
%     'AssumedSiteCapacity_kW' - optional explicit planning assumption
%              used ONLY when the row defines no capacity value at all
%              (service_capacity_kW and spare_capacity_kW both empty, as
%              in the current adapter CSV). Recorded as an assumption and
%              forces capacity_basis handling as 'placeholder'.
%
%   Returned struct fields:
%     capacity_basis       - normalized basis string
%     is_verified          - true only for verified_utility/facility
%     mode                 - guard mode used
%     capacity_kW          - site capacity limit for simulation, or NaN
%     capacity_defined     - true when capacity_kW is finite
%     capacity_definition  - text describing how capacity_kW was derived
%     placeholder_banner   - "" when verified; otherwise mandatory
%                            banner text for every plot/table
%     assumed_capacity_used- true when AssumedSiteCapacity_kW supplied
%
%   Capacity derivation order:
%     1. service_capacity_kW when present (preferred, service definition)
%     2. base_load_mean_kW + spare_capacity_kW (legacy definition,
%        labeled as such)
%     3. AssumedSiteCapacity_kW when supplied (planning assumption)
%     4. otherwise NaN - capacity-limited strategies must refuse to run.
%
%   Part of Milestone 2 V3 implementation (item ML-04).

    allowedBases = ["verified_utility", "verified_facility", ...
        "engineering_estimate", "planning_proxy", "placeholder", ...
        "unknown"];

    p = inputParser;
    p.FunctionName = "capacityGuard";
    addParameter(p, "Mode", "feasibility", ...
        @(v) ismember(string(v), ["feasibility", "planning_illustration"]));
    addParameter(p, "AssumedSiteCapacity_kW", NaN, ...
        @(v) isnumeric(v) && isscalar(v));
    parse(p, varargin{:});
    mode = string(p.Results.Mode);
    assumedCap = p.Results.AssumedSiteCapacity_kW;

    s = localRowToStruct(scenarioRow);

    % ---------------------------------------------------------------
    % Normalize and validate capacity_basis against the vocabulary
    % ---------------------------------------------------------------
    basis = lower(strtrim(string(s.capacity_basis)));
    if ismissing(basis) || basis == ""
        basis = "unknown";
    end
    if ~ismember(basis, allowedBases)
        error("capacityGuard:unknownBasis", ...
            "capacity_basis '%s' (scenario %s) is not in the controlled " + ...
            "vocabulary {%s}. Fix the producing adapter; do not " + ...
            "hand-edit the CSV.", basis, string(s.scenario_id), ...
            strjoin(allowedBases, ", "));
    end

    isVerified = ismember(basis, ["verified_utility", "verified_facility"]);

    % ---------------------------------------------------------------
    % FAIL-CLOSED: feasibility claims require verified capacity
    % ---------------------------------------------------------------
    if mode == "feasibility" && ~isVerified
        error("capacityGuard:notVerified", ...
            "FEASIBILITY BLOCKED for scenario %s: capacity_basis is " + ...
            "'%s', not verified_utility/verified_facility. No " + ...
            "feasibility, adequacy, or headroom claim may be made. " + ...
            "Re-run with Mode='planning_illustration' for labeled " + ...
            "planning visuals only.", string(s.scenario_id), basis);
    end

    % ---------------------------------------------------------------
    % Derive the capacity value (may legitimately be NaN)
    % ---------------------------------------------------------------
    serviceCap = localNumericOrNaN(s, "service_capacity_kW");
    spareCap = localNumericOrNaN(s, "spare_capacity_kW");
    baseMean = localNumericOrNaN(s, "base_load_mean_kW");

    assumedUsed = false;
    if isfinite(serviceCap)
        capacity_kW = serviceCap;
        capacityDef = "service_capacity_kW (service definition)";
    elseif isfinite(spareCap) && isfinite(baseMean)
        capacity_kW = baseMean + spareCap;
        capacityDef = "base_load_mean_kW + spare_capacity_kW " + ...
            "(legacy definition - NOT a service rating)";
    elseif isfinite(assumedCap)
        capacity_kW = assumedCap;
        capacityDef = sprintf("assumed planning capacity %.1f kW " + ...
            "(explicit user assumption; treated as placeholder)", ...
            assumedCap);
        assumedUsed = true;
        if isVerified
            % An assumed value can never upgrade provenance; it can only
            % exist alongside unverified data.
            isVerified = false;
            basis = "placeholder";
        end
    else
        capacity_kW = NaN;
        capacityDef = "undefined - service_capacity_kW and " + ...
            "spare_capacity_kW are both empty in the canonical CSV";
    end

    % ---------------------------------------------------------------
    % Mandatory banner text for anything not verified
    % ---------------------------------------------------------------
    if isVerified
        banner = "";
    else
        banner = sprintf("CAPACITY IS A PLANNING PLACEHOLDER " + ...
            "(capacity_basis=%s). Illustrates managed-charging " + ...
            "behavior only; NOT evidence of electrical feasibility. " + ...
            "Utility/facility confirmation pending.", basis);
    end

    guard = struct( ...
        "scenario_id", string(s.scenario_id), ...
        "capacity_basis", basis, ...
        "is_verified", isVerified, ...
        "mode", mode, ...
        "capacity_kW", capacity_kW, ...
        "capacity_defined", isfinite(capacity_kW), ...
        "capacity_definition", string(capacityDef), ...
        "placeholder_banner", string(banner), ...
        "assumed_capacity_used", assumedUsed, ...
        "allowed_bases", allowedBases);
end

% =====================================================================
% Local helpers
% =====================================================================

function s = localRowToStruct(scenarioRow)
    if istable(scenarioRow)
        if height(scenarioRow) ~= 1
            error("capacityGuard:oneRowRequired", ...
                "Expected exactly one scenario row, got %d.", ...
                height(scenarioRow));
        end
        s = table2struct(scenarioRow);
    elseif isstruct(scenarioRow)
        s = scenarioRow;
    else
        error("capacityGuard:badInput", ...
            "scenarioRow must be a one-row table or a struct.");
    end
    if ~isfield(s, "capacity_basis")
        error("capacityGuard:missingBasis", ...
            "Scenario row has no capacity_basis field. Fail-closed: " + ...
            "refusing to evaluate capacity without provenance.");
    end
    if ~isfield(s, "scenario_id")
        s.scenario_id = "unspecified_scenario";
    end
end

function v = localNumericOrNaN(s, fieldName)
%LOCALNUMERICORNAN Field value as a finite double, else NaN.
    v = NaN;
    if isfield(s, fieldName)
        raw = s.(fieldName);
        if isnumeric(raw) && isscalar(raw)
            v = double(raw);
        elseif (isstring(raw) || ischar(raw))
            parsed = str2double(string(raw));
            v = parsed;  % NaN when empty/non-numeric
        end
    end
    if ~isfinite(v)
        v = NaN;
    end
end
