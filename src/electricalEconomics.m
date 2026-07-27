function econ = electricalEconomics(resultUnmanaged, resultManaged, varargin)
%ELECTRICALECONOMICS Electrical-fidelity checks and demand-charge economics.
%
%   econ = ELECTRICALECONOMICS(resultUnmanaged, resultManaged, ...)
%   compares an unmanaged and a managed managedCharging result for the
%   same scenario and computes (ML-11):
%
%     * Apparent-power peaks (kVA) via an optional power factor.
%     * A service/transformer constraint check against a verified or
%       supplied service capacity.
%     * Demand-charge and energy cost comparison WHEN a tariff struct is
%       supplied. When it is not, every cost field is NaN and cost_status
%       is "tariff_not_supplied" - costs are NEVER invented.
%
%   Charger efficiency is applied upstream in makeSessionProfiles (the
%   request profile is grid-side); its value is echoed here from the
%   'ChargerEfficiency' option for reporting.
%
%   Name-value options:
%     'PowerFactor'          - scalar in (0,1], default 0.95. kVA =
%                              kW / power factor.
%     'ChargerEfficiency'    - echo of the efficiency used upstream,
%                              default 0.92 (reporting only), matching
%                              src/fcf_m2/config.py CHARGER_EFFICIENCY.
%     'ServiceCapacity_kW'   - transformer/service limit for the
%                              constraint check. Default NaN -> check
%                              reported as "service_capacity_unknown".
%     'Guard'                - capacityGuard struct; its banner and
%                              provenance propagate into the output, and
%                              any constraint verdict is labeled
%                              non-verified unless guard.is_verified.
%     'Tariff'               - struct with fields:
%                                demand_charge_usd_per_kw_month
%                                energy_usd_per_kwh
%                              Both required for costs to be computed.
%
%   Output struct (units noted per field):
%     peak_kW_unmanaged / peak_kW_managed
%     peak_kVA_unmanaged / peak_kVA_managed      (power-factor adjusted)
%     power_factor, charger_efficiency
%     service_capacity_kW, service_check         ("within_service" |
%         "exceeds_service" | "service_capacity_unknown"), labeled with
%         provenance in service_check_note
%     demand_charge_usd_month_unmanaged / _managed
%     demand_charge_savings_usd_month
%     energy_cost_usd_day_unmanaged / _managed
%     cost_status                                ("computed" |
%                                                 "tariff_not_supplied")
%     peak_reduction_kW, banner
%
%   Part of Milestone 2 V3 implementation (item ML-11).

    p = inputParser;
    p.FunctionName = "electricalEconomics";
    addParameter(p, "PowerFactor", 0.95, ...
        @(v) isnumeric(v) && isscalar(v) && v > 0 && v <= 1);
    % 0.92 to match src/fcf_m2/config.py. See makeSessionProfiles.m for why this
    % was 0.93 and how the disagreement was found.
    addParameter(p, "ChargerEfficiency", 0.92, ...
        @(v) isnumeric(v) && isscalar(v) && v > 0 && v <= 1);
    addParameter(p, "ServiceCapacity_kW", NaN, ...
        @(v) isnumeric(v) && isscalar(v));
    addParameter(p, "Guard", struct.empty, @(v) isstruct(v));
    addParameter(p, "Tariff", struct.empty, @(v) isstruct(v));
    parse(p, varargin{:});
    opt = p.Results;

    pf = opt.PowerFactor;

    peakUn_kW = resultUnmanaged.peak_total_kW;
    peakMg_kW = resultManaged.peak_total_kW;

    econ = struct();
    econ.strategy_unmanaged = resultUnmanaged.strategy;
    econ.strategy_managed = resultManaged.strategy;
    econ.power_factor = pf;
    econ.charger_efficiency = opt.ChargerEfficiency;
    econ.peak_kW_unmanaged = peakUn_kW;
    econ.peak_kW_managed = peakMg_kW;
    econ.peak_kVA_unmanaged = peakUn_kW / pf;
    econ.peak_kVA_managed = peakMg_kW / pf;
    econ.peak_reduction_kW = peakUn_kW - peakMg_kW;

    % ---------------------------------------------------------------
    % Service / transformer constraint check
    % ---------------------------------------------------------------
    serviceCap_kW = opt.ServiceCapacity_kW;
    isVerified = false;
    banner = "";
    if ~isempty(opt.Guard)
        if ~isfinite(serviceCap_kW) && isfield(opt.Guard, "capacity_kW")
            serviceCap_kW = opt.Guard.capacity_kW;
        end
        if isfield(opt.Guard, "is_verified")
            isVerified = opt.Guard.is_verified;
        end
        if isfield(opt.Guard, "placeholder_banner")
            banner = string(opt.Guard.placeholder_banner);
        end
    end

    econ.service_capacity_kW = serviceCap_kW;
    if ~isfinite(serviceCap_kW)
        econ.service_check = "service_capacity_unknown";
        econ.service_check_note = "No service capacity available; " + ...
            "constraint check skipped (fail-closed reporting).";
    else
        if peakMg_kW <= serviceCap_kW
            econ.service_check = "within_service";
        else
            econ.service_check = "exceeds_service";
        end
        if isVerified
            econ.service_check_note = "Checked against VERIFIED " + ...
                "service capacity.";
        else
            econ.service_check_note = "Checked against NON-VERIFIED " + ...
                "capacity (placeholder/proxy). Planning illustration " + ...
                "only - no feasibility claim.";
        end
    end
    econ.banner = banner;

    % ---------------------------------------------------------------
    % Tariff economics - only when a tariff is actually supplied
    % ---------------------------------------------------------------
    tariffOk = ~isempty(opt.Tariff) && ...
        isfield(opt.Tariff, "demand_charge_usd_per_kw_month") && ...
        isfield(opt.Tariff, "energy_usd_per_kwh") && ...
        isnumeric(opt.Tariff.demand_charge_usd_per_kw_month) && ...
        isnumeric(opt.Tariff.energy_usd_per_kwh);

    if tariffOk
        dc = double(opt.Tariff.demand_charge_usd_per_kw_month);
        ec = double(opt.Tariff.energy_usd_per_kwh);

        % Demand charge: billed monthly on the daily peak modeled here
        % (assumes the modeled day sets the billing peak - stated
        % simplification, see README limitations).
        econ.demand_charge_usd_month_unmanaged = peakUn_kW * dc;
        econ.demand_charge_usd_month_managed = peakMg_kW * dc;
        econ.demand_charge_savings_usd_month = ...
            (peakUn_kW - peakMg_kW) * dc;

        econ.energy_cost_usd_day_unmanaged = ...
            resultUnmanaged.delivered_kWh * ec;
        econ.energy_cost_usd_day_managed = ...
            resultManaged.delivered_kWh * ec;

        econ.cost_status = "computed";
        econ.tariff = opt.Tariff;
    else
        econ.demand_charge_usd_month_unmanaged = NaN;
        econ.demand_charge_usd_month_managed = NaN;
        econ.demand_charge_savings_usd_month = NaN;
        econ.energy_cost_usd_day_unmanaged = NaN;
        econ.energy_cost_usd_day_managed = NaN;
        econ.cost_status = "tariff_not_supplied";
        econ.tariff = struct.empty;
    end
end
