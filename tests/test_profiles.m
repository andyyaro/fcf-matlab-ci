function tests = test_profiles
%TEST_PROFILES Unit tests for makeSessionProfiles (ML-03).
%   Verifies that dwell matters, that the peak derives from sessions and
%   energy (not ports x charger kW), and that profile energy is conserved.
    tests = functiontests(localfunctions);
end

% =====================================================================
% Fixtures
% =====================================================================

function setupOnce(testCase)
    thisDir = fileparts(mfilename("fullpath"));
    repoRoot = fileparts(thisDir);
    addpath(fullfile(repoRoot, "src"));
    testCase.TestData.baseRow = localSyntheticRow();
end

% =====================================================================
% Tests
% =====================================================================

function testDwellMateriallyChangesProfile(testCase)
    % Legacy H1: dwell_hr was loaded but unused. In the session model a
    % shorter dwell truncates charging, so the profile MUST change.
    rowLong = testCase.TestData.baseRow;
    rowLong.dwell_hr = 4.0;
    rowShort = testCase.TestData.baseRow;
    rowShort.dwell_hr = 0.25;   % 15 minutes - cannot finish a session

    pLong = makeSessionProfiles(rowLong);
    pShort = makeSessionProfiles(rowShort);

    verifyGreaterThan(testCase, ...
        max(abs(pLong.evRequest_kW - pShort.evRequest_kW)), 0.5, ...
        "Changing dwell_hr must materially change the request profile.");
    % Short dwell strictly reduces deliverable energy.
    verifyLessThan(testCase, pShort.energyRequested_kWh, ...
        pLong.energyRequested_kWh);
end

function testPeakDerivesFromSessionsNotPorts(testCase)
    % Legacy H2: request peaked at ports x charger kW regardless of
    % demand. With few sessions the session-based peak must sit well
    % below the theoretical simultaneous maximum.
    row = testCase.TestData.baseRow;   % 2.0 sessions/day, 8 ports
    row.ports = 8;
    row.sessions_per_day = 2.0;

    p = makeSessionProfiles(row);
    theoreticalMax = row.ports * row.charger_power_kW;   % 153.6 kW

    verifyLessThan(testCase, max(p.evRequest_kW), 0.5 * theoreticalMax, ...
        "Peak must reflect sessions/energy, not ports x charger kW.");
    verifyGreaterThan(testCase, max(p.evRequest_kW), 0);
end

function testEnergyConservationDeterministic(testCase)
    % Deterministic mode conserves sessions_per_day exactly via weights:
    % integral of the request equals sessions_per_day x per-session
    % deliverable grid energy.
    row = testCase.TestData.baseRow;
    % Deliberately NOT the 0.92 default. Passing a non-default value is what proves the
    % parameter is honoured rather than silently ignored -- a test that passes the default
    % would still pass if the argument were dropped on the floor.
    eta = 0.93;
    p = makeSessionProfiles(row, "ChargerEfficiency", eta);

    gridPerSession = row.energy_per_session_kWh / eta;
    deliverable = min(gridPerSession, ...
        row.dwell_hr * row.charger_power_kW);
    expected_kWh = row.sessions_per_day * deliverable;

    verifyEqual(testCase, p.energyRequested_kWh, expected_kWh, ...
        "RelTol", 1e-6, ...
        "Profile energy must equal sessions x deliverable energy.");
end

function testFractionalSessionsConserved(testCase)
    % A fractional sessions_per_day must be conserved exactly through the
    % per-session weighting. The value is SYNTHETIC and deliberately not any
    % value present in the canonical adapter CSV: these sources are mirrored
    % into a PUBLIC harness repository, so a test fixture must never carry a
    % real per-site input. See docs/operations/v4-program/MATLAB_LIBERATION.md.
    row = testCase.TestData.baseRow;
    row.sessions_per_day = 1.75;
    eta = 0.93;
    p = makeSessionProfiles(row, "ChargerEfficiency", eta);

    gridPerSession = row.energy_per_session_kWh / eta;
    deliverable = min(gridPerSession, ...
        row.dwell_hr * row.charger_power_kW);
    verifyEqual(testCase, p.energyRequested_kWh, ...
        1.75 * deliverable, "RelTol", 1e-6);
end

function testEfficiencyIncreasesGridEnergy(testCase)
    row = testCase.TestData.baseRow;
    pIdeal = makeSessionProfiles(row, "ChargerEfficiency", 1.0);
    pReal = makeSessionProfiles(row, "ChargerEfficiency", 0.90);
    % Same battery need costs more at the grid when efficiency < 1
    % (unless dwell-truncated; the base row is not truncated).
    verifyGreaterThan(testCase, pReal.energyRequested_kWh, ...
        pIdeal.energyRequested_kWh);
end

function testLegacyGaussianModeReproducesLegacyShape(testCase)
    % Presentation-continuity mode: peak = ports x charger kW at the
    % arrival-window midpoint (the legacy shape), clearly labeled.
    row = testCase.TestData.baseRow;
    p = makeSessionProfiles(row, "Mode", "legacy_gaussian");
    verifyEqual(testCase, p.mode, "legacy_gaussian");
    verifyEqual(testCase, max(p.evRequest_kW), ...
        row.ports * row.charger_power_kW, "RelTol", 1e-9);
    [~, iPeak] = max(p.evRequest_kW);
    center = (row.arrival_start_hr + row.arrival_end_hr) / 2;
    verifyEqual(testCase, p.t_hr(iPeak), center, "AbsTol", ...
        p.dt_hr + 1e-12);
    verifyEqual(testCase, height(p.sessions), 0, ...
        "Legacy mode must not fabricate a session list.");
end

function testStochasticModeReproducibleWithSeed(testCase)
    row = testCase.TestData.baseRow;
    p1 = makeSessionProfiles(row, "Mode", "stochastic", "Seed", 7);
    p2 = makeSessionProfiles(row, "Mode", "stochastic", "Seed", 7);
    p3 = makeSessionProfiles(row, "Mode", "stochastic", "Seed", 8);
    verifyEqual(testCase, p1.evRequest_kW, p2.evRequest_kW, ...
        "Same seed must reproduce the same draw.");
    % Different seed should (with overwhelming likelihood) differ.
    verifyTrue(testCase, ...
        any(abs(p1.evRequest_kW - p3.evRequest_kW) > 1e-9) || ...
        height(p1.sessions) ~= height(p3.sessions));
end

function testBaseLoadHitsMeanToPeakRange(testCase)
    row = testCase.TestData.baseRow;
    p = makeSessionProfiles(row);
    verifyEqual(testCase, max(p.baseLoad_kW), ...
        row.base_load_peak_kW, "RelTol", 1e-9);
    verifyGreaterThanOrEqual(testCase, min(p.baseLoad_kW), ...
        row.base_load_mean_kW - 1e-9);
end

% =====================================================================
% Local helpers
% =====================================================================

function row = localSyntheticRow()
%LOCALSYNTHETICROW Struct-based scenario row for profile tests.
    row = struct();
    row.scenario_id = "TEST_2036_base";
    row.site_id = "TST001";
    row.site_name = "Test Site";
    row.horizon_year = 2036;
    row.case_label = "base";
    row.ports = 4;
    row.charger_power_kW = 19.2;
    row.spare_capacity_kW = NaN;
    row.service_capacity_kW = NaN;
    row.capacity_basis = "placeholder";
    row.capacity_source = "test fixture";
    row.base_load_mean_kW = 50;
    row.base_load_peak_kW = 70;
    row.arrival_start_hr = 9;
    row.arrival_end_hr = 17;
    row.dwell_hr = 2.0;
    row.sessions_per_day = 2.0;
    row.energy_per_session_kWh = 9.5;
    row.managed_charging_policy = "none";
end
