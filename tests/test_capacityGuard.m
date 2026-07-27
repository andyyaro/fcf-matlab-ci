function tests = test_capacityGuard
%TEST_CAPACITYGUARD Unit tests for the fail-closed capacity gate (ML-04).
    tests = functiontests(localfunctions);
end

% =====================================================================
% Fixtures
% =====================================================================

function setupOnce(testCase)
    thisDir = fileparts(mfilename("fullpath"));
    repoRoot = fileparts(thisDir);
    addpath(fullfile(repoRoot, "src"));
    testCase.TestData.row = localGuardRow("placeholder");
end

% =====================================================================
% Fail-closed behavior
% =====================================================================

function testFeasibilityFailsClosedOnPlaceholder(testCase)
    row = localGuardRow("placeholder");
    verifyError(testCase, ...
        @() capacityGuard(row, "Mode", "feasibility"), ...
        "capacityGuard:notVerified");
end

function testFeasibilityFailsClosedOnUnknown(testCase)
    row = localGuardRow("unknown");
    verifyError(testCase, ...
        @() capacityGuard(row, "Mode", "feasibility"), ...
        "capacityGuard:notVerified");
end

function testFeasibilityFailsClosedOnEngineeringEstimate(testCase)
    % Even engineer-derived estimates are NOT feasibility-grade.
    row = localGuardRow("engineering_estimate");
    verifyError(testCase, ...
        @() capacityGuard(row, "Mode", "feasibility"), ...
        "capacityGuard:notVerified");
end

function testFeasibilityDefaultsToFailClosed(testCase)
    % No Mode argument -> feasibility -> error on placeholder.
    row = localGuardRow("placeholder");
    verifyError(testCase, @() capacityGuard(row), ...
        "capacityGuard:notVerified");
end

function testUnknownVocabularyRejected(testCase)
    row = localGuardRow("confirmed_totally");   % not in vocabulary
    verifyError(testCase, ...
        @() capacityGuard(row, "Mode", "planning_illustration"), ...
        "capacityGuard:unknownBasis");
end

function testMissingBasisFieldRejected(testCase)
    row = rmfield(localGuardRow("placeholder"), "capacity_basis");
    verifyError(testCase, ...
        @() capacityGuard(row, "Mode", "planning_illustration"), ...
        "capacityGuard:missingBasis");
end

% =====================================================================
% Verified paths
% =====================================================================

function testVerifiedUtilityPassesFeasibility(testCase)
    row = localGuardRow("verified_utility");
    row.service_capacity_kW = 400;
    g = capacityGuard(row, "Mode", "feasibility");
    verifyTrue(testCase, g.is_verified);
    verifyEqual(testCase, g.capacity_kW, 400);
    verifyEqual(testCase, strlength(g.placeholder_banner), 0, ...
        "Verified capacity must carry no placeholder banner.");
end

function testVerifiedFacilityPassesFeasibility(testCase)
    row = localGuardRow("verified_facility");
    row.service_capacity_kW = 250;
    g = capacityGuard(row, "Mode", "feasibility");
    verifyTrue(testCase, g.is_verified);
    verifyEqual(testCase, g.capacity_kW, 250);
end

% =====================================================================
% Planning-illustration mode
% =====================================================================

function testPlanningModeCarriesBanner(testCase)
    row = localGuardRow("placeholder");
    row.spare_capacity_kW = 120.0;   % SYNTHETIC - never a real site value
    g = capacityGuard(row, "Mode", "planning_illustration");
    verifyFalse(testCase, g.is_verified);
    verifyGreaterThan(testCase, strlength(g.placeholder_banner), 0, ...
        "Non-verified capacity MUST carry the placeholder banner.");
    verifyTrue(testCase, ...
        contains(g.placeholder_banner, "PLACEHOLDER", ...
            "IgnoreCase", true));
    % Legacy definition: mean base + spare.
    verifyEqual(testCase, g.capacity_kW, 50 + 120.0, "RelTol", 1e-12);
end

function testUndefinedCapacityYieldsNaN(testCase)
    % Current adapter CSV state: service and spare both empty.
    row = localGuardRow("placeholder");   % both NaN in fixture
    g = capacityGuard(row, "Mode", "planning_illustration");
    verifyFalse(testCase, g.capacity_defined);
    verifyTrue(testCase, isnan(g.capacity_kW));
end

function testAssumedCapacityIsLabeledAssumption(testCase)
    row = localGuardRow("placeholder");
    g = capacityGuard(row, "Mode", "planning_illustration", ...
        "AssumedSiteCapacity_kW", 200);
    verifyTrue(testCase, g.capacity_defined);
    verifyEqual(testCase, g.capacity_kW, 200);
    verifyTrue(testCase, g.assumed_capacity_used);
    verifyFalse(testCase, g.is_verified, ...
        "An assumed value can never count as verified.");
    verifyGreaterThan(testCase, strlength(g.placeholder_banner), 0);
end

function testServiceCapacityPreferredOverLegacySum(testCase)
    row = localGuardRow("planning_proxy");
    row.service_capacity_kW = 300;
    row.spare_capacity_kW = 120.0;   % SYNTHETIC - never a real site value
    g = capacityGuard(row, "Mode", "planning_illustration");
    verifyEqual(testCase, g.capacity_kW, 300, ...
        "service_capacity_kW must take precedence over base+spare.");
end

% =====================================================================
% Local helpers
% =====================================================================

function row = localGuardRow(basis)
    row = struct();
    row.scenario_id = "TEST_GUARD";
    row.site_id = "TST001";
    row.capacity_basis = string(basis);
    row.service_capacity_kW = NaN;
    row.spare_capacity_kW = NaN;
    row.base_load_mean_kW = 50;
end
