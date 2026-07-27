function tests = test_managedCharging
%TEST_MANAGEDCHARGING Unit tests for the charging strategies (ML-05).
%   Core invariants: strict energy balance, energy-aware delivery before
%   departure when capacity allows, honest shortfall reporting when it
%   does not, and disjoint deferred-vs-curtailed accounting.
    tests = functiontests(localfunctions);
end

% =====================================================================
% Fixtures
% =====================================================================

function setupOnce(testCase)
    thisDir = fileparts(mfilename("fullpath"));
    repoRoot = fileparts(thisDir);
    addpath(fullfile(repoRoot, "src"));
    testCase.TestData.row = localScenarioRow();
end

% =====================================================================
% Energy balance (requested = delivered + curtailed + unmet, +-1e-6)
% =====================================================================

function testEnergyBalanceUnmanaged(testCase)
    prof = makeSessionProfiles(testCase.TestData.row);
    r = managedCharging(prof, "unmanaged");
    localVerifyBalance(testCase, r);
    verifyEqual(testCase, r.curtailed_kWh, 0);
    verifyEqual(testCase, r.unmet_kWh, 0);
end

function testEnergyBalanceClamp(testCase)
    prof = makeSessionProfiles(testCase.TestData.row);
    r = managedCharging(prof, "clamp", "SiteCapacity_kW", 60);
    localVerifyBalance(testCase, r);
end

function testEnergyBalanceEnergyAwareAmple(testCase)
    prof = makeSessionProfiles(testCase.TestData.row);
    r = managedCharging(prof, "energy_aware", "SiteCapacity_kW", 500);
    localVerifyBalance(testCase, r);
end

function testEnergyBalanceEnergyAwareTight(testCase)
    prof = makeSessionProfiles(testCase.TestData.row);
    r = managedCharging(prof, "energy_aware", "SiteCapacity_kW", 75);
    localVerifyBalance(testCase, r);
end

% =====================================================================
% Energy-aware guarantees
% =====================================================================

function testEnergyAwareMeetsNeedWhenCapacityAllows(testCase)
    % Generous cap: every session must be fully served before departure.
    prof = makeSessionProfiles(testCase.TestData.row);
    r = managedCharging(prof, "energy_aware", "SiteCapacity_kW", 500);
    verifyLessThan(testCase, r.unmet_kWh, 1e-6);
    verifyTrue(testCase, all(r.per_vehicle.fully_served), ...
        "All vehicles must be fully served under a generous cap.");
end

function testEnergyAwareReportsShortfallWhenCapacityTight(testCase)
    % Cap barely above base load: shortfall must be REPORTED, not hidden.
    prof = makeSessionProfiles(testCase.TestData.row);
    r = managedCharging(prof, "energy_aware", "SiteCapacity_kW", 72);
    verifyGreaterThan(testCase, r.unmet_kWh, 0, ...
        "A binding cap must produce reported unmet energy.");
    verifyTrue(testCase, any(~r.per_vehicle.fully_served));
    % Per-vehicle table must reconcile with the aggregate.
    verifyEqual(testCase, sum(r.per_vehicle.unmet_kWh), r.unmet_kWh, ...
        "AbsTol", 1e-9);
end

function testEnergyAwareNeverExceedsCap(testCase)
    prof = makeSessionProfiles(testCase.TestData.row);
    cap = 90;
    r = managedCharging(prof, "energy_aware", "SiteCapacity_kW", cap);
    verifyLessThanOrEqual(testCase, max(r.total_kW), cap + 1e-9, ...
        "Energy-aware total load must respect the site cap.");
end

function testDeferredIsNotCurtailed(testCase)
    % Moderately tight cap: the scheduler defers energy (recovered later)
    % rather than curtailing it. Deferred > 0 while curtailed == 0.
    prof = makeSessionProfiles(testCase.TestData.row);
    r = managedCharging(prof, "energy_aware", "SiteCapacity_kW", 95);
    verifyEqual(testCase, r.curtailed_kWh, 0, ...
        "energy_aware never curtails; it defers or reports unmet.");
    verifyGreaterThan(testCase, r.deferred_kWh, 0, ...
        "A binding cap must show deferral relative to the request.");
    % Clamp on the same profiles curtails instead.
    rc = managedCharging(prof, "clamp", "SiteCapacity_kW", 95);
    verifyGreaterThan(testCase, rc.curtailed_kWh, 0);
    verifyEqual(testCase, rc.unmet_kWh, 0);
end

function testEnergyAwareBeatsClampOnDeliveredEnergy(testCase)
    % Same binding cap: deferral must deliver at least as much energy as
    % the legacy clamp (that is the point of ML-05).
    prof = makeSessionProfiles(testCase.TestData.row);
    cap = 95;
    ra = managedCharging(prof, "energy_aware", "SiteCapacity_kW", cap);
    rc = managedCharging(prof, "clamp", "SiteCapacity_kW", cap);
    verifyGreaterThanOrEqual(testCase, ...
        ra.delivered_kWh + 1e-9, rc.delivered_kWh);
end

function testPriorityClassServedFirst(testCase)
    % Two overlapping sessions, capacity for only one at a time: the
    % higher-priority (lower class number) session is served first.
    prof = localTwoVehicleProfiles();
    prof.sessions.priority_class = [2; 1];   % vehicle 2 is priority
    cap = max(prof.baseLoad_kW) + 20;        % room for one 19.2 kW car
    r = managedCharging(prof, "energy_aware", "SiteCapacity_kW", cap);
    % The priority vehicle must be fully served.
    verifyTrue(testCase, r.per_vehicle.fully_served(2), ...
        "Priority class 1 vehicle must be served before class 2.");
end

function testCommsLossFailSafeProfile(testCase)
    % Comms loss: static fail-safe limit per vehicle, labeled in notes.
    prof = makeSessionProfiles(testCase.TestData.row);
    r = managedCharging(prof, "energy_aware", "SiteCapacity_kW", 500, ...
        "CommsLoss", true, "FailSafeFraction", 0.5);
    localVerifyBalance(testCase, r);
    verifyTrue(testCase, r.comms_loss);
    verifyTrue(testCase, any(contains(r.notes, "COMMS LOSS")));
    % Per-vehicle power never exceeds the fail-safe static limit:
    % aggregate EV power <= nSessions x 0.5 x charger power.
    maxStatic = height(prof.sessions) * 0.5 * ...
        max(prof.sessions.max_power_kW .* prof.sessions.weight);
    verifyLessThanOrEqual(testCase, max(r.ev_kW), maxStatic + 1e-9);
end

% =====================================================================
% Refusal paths
% =====================================================================

function testCapacityRequiredForClamp(testCase)
    prof = makeSessionProfiles(testCase.TestData.row);
    verifyError(testCase, @() managedCharging(prof, "clamp"), ...
        "managedCharging:capacityUndefined");
end

function testEnergyAwareRefusesLegacyGaussian(testCase)
    prof = makeSessionProfiles(testCase.TestData.row, ...
        "Mode", "legacy_gaussian");
    verifyError(testCase, ...
        @() managedCharging(prof, "energy_aware", ...
            "SiteCapacity_kW", 200), ...
        "managedCharging:sessionsRequired");
end

function testUnknownStrategyRejected(testCase)
    prof = makeSessionProfiles(testCase.TestData.row);
    verifyError(testCase, @() managedCharging(prof, "magic"), ...
        "managedCharging:badStrategy");
end

% =====================================================================
% Local helpers
% =====================================================================

function localVerifyBalance(testCase, r)
    tol = 1e-6 * max(1, abs(r.requested_kWh));
    verifyEqual(testCase, ...
        r.delivered_kWh + r.curtailed_kWh + r.unmet_kWh, ...
        r.requested_kWh, "AbsTol", tol, ...
        "Energy balance requested = delivered + curtailed + unmet.");
end

function row = localScenarioRow()
    row = struct();
    row.scenario_id = "TEST_MC";
    row.site_id = "TST001";
    row.site_name = "Test Site";
    row.horizon_year = 2036;
    row.case_label = "base";
    row.ports = 6;
    row.charger_power_kW = 19.2;
    row.spare_capacity_kW = NaN;
    row.service_capacity_kW = NaN;
    row.capacity_basis = "placeholder";
    row.base_load_mean_kW = 50;
    row.base_load_peak_kW = 70;
    row.arrival_start_hr = 9;
    row.arrival_end_hr = 15;
    row.dwell_hr = 6.0;
    row.sessions_per_day = 6.0;
    row.energy_per_session_kWh = 18.0;
    row.managed_charging_policy = "none";
end

function prof = localTwoVehicleProfiles()
%LOCALTWOVEHICLEPROFILES Hand-built two-session profile struct for
%   priority testing (same schema as makeSessionProfiles output).
    dt_hr = 5 / 60;
    t_hr = (0:dt_hr:24).';
    baseLoad_kW = 40 * ones(size(t_hr));

    sessions = table( ...
        [1; 2], [10.0; 10.0], [12.0; 12.0], [2.0; 2.0], ...
        [19.2; 19.2], [19.2; 19.2], [19.2; 19.2], [1.0; 1.0], ...
        [1; 1], ...
        'VariableNames', ["session_id", "arrival_hr", "departure_hr", ...
            "dwell_hr", "energy_required_kWh", ...
            "energy_required_grid_kWh", "max_power_kW", "weight", ...
            "priority_class"]);

    evRequest_kW = zeros(size(t_hr));
    inWindow = t_hr >= 10 & t_hr < 11;    % each needs 1 h at 19.2 kW
    evRequest_kW(inWindow) = 2 * 19.2;

    prof = struct();
    prof.t_hr = t_hr;
    prof.dt_hr = dt_hr;
    prof.baseLoad_kW = baseLoad_kW;
    prof.evRequest_kW = evRequest_kW;
    prof.sessions = sessions;
    prof.energyRequested_kWh = trapz(t_hr, evRequest_kW);
    prof.mode = "deterministic_sessions";
    prof.charger_efficiency = 1.0;
    prof.label = "two-vehicle priority fixture";
end
