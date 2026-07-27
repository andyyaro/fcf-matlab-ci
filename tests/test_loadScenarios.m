function tests = test_loadScenarios
%TEST_LOADSCENARIOS Unit tests for loadScenarios (ML-01/ML-06).
%   Run with: runtests("tests")
    tests = functiontests(localfunctions);
end

% =====================================================================
% Fixtures
% =====================================================================

function setupOnce(testCase)
    thisDir = fileparts(mfilename("fullpath"));
    repoRoot = fileparts(thisDir);
    addpath(fullfile(repoRoot, "src"));
    testCase.TestData.csvFile = resolveScenarioCsv();
    testCase.TestData.tmpDir = tempname;
    mkdir(testCase.TestData.tmpDir);
end

function teardownOnce(testCase)
    if exist(testCase.TestData.tmpDir, "dir")
        rmdir(testCase.TestData.tmpDir, "s");
    end
end

% =====================================================================
% Tests
% =====================================================================

function testLoadsCanonicalCsv(testCase)
    T = loadScenarios(testCase.TestData.csvFile);
    verifyGreaterThan(testCase, height(T), 0);
    % Canonical adapter emits 120 rows (12 sites x 10 horizon-case combos).
    verifyEqual(testCase, height(T), 120);
    verifyTrue(testCase, ismember("case_label", ...
        string(T.Properties.VariableNames)), ...
        "CSV column 'case' must be exposed as case_label.");
end

function testHorizonsComeFromData(testCase)
    % Horizon set must be discovered from the data, never hard-coded.
    T = loadScenarios(testCase.TestData.csvFile);
    horizons = unique(T.horizon_year);
    verifyEqual(testCase, sort(horizons(:)).', [2026 2036 2046 2056]);
    % Metadata carries the same discovered set.
    verifyEqual(testCase, ...
        sort(T.Properties.UserData.horizons_in_data), ...
        [2026 2036 2046 2056]);
end

function testFilterBySiteHorizonCase(testCase)
    %% Site ids are read FROM THE DATA, never hard-coded. The same discipline
    %% ML-06 applies to horizons applies here: these sources are mirrored into a
    %% PUBLIC harness repository, so naming a real facility id in a test would
    %% publish client identity. Reading the id keeps the test valid against the
    %% private canonical CSV and against a synthetic harness fixture alike.
    allRows = loadScenarios(testCase.TestData.csvFile);
    siteId = string(allRows.site_id(1));
    T = loadScenarios(testCase.TestData.csvFile, ...
        "SiteId", siteId, "HorizonYear", 2036, "Case", "high");
    verifyEqual(testCase, height(T), 1);
    verifyEqual(testCase, string(T.site_id(1)), siteId);
    verifyEqual(testCase, T.horizon_year(1), 2036);
    verifyEqual(testCase, string(T.case_label(1)), "high");
end

function testNoMatchErrors(testCase)
    verifyError(testCase, ...
        @() loadScenarios(testCase.TestData.csvFile, ...
            "SiteId", "NOPE999"), ...
        "loadScenarios:noMatch");
end

function testMissingFileErrors(testCase)
    verifyError(testCase, ...
        @() loadScenarios(fullfile(testCase.TestData.tmpDir, ...
            "does_not_exist.csv")), ...
        "loadScenarios:fileNotFound");
end

function testMissingColumnErrors(testCase)
    % Drop capacity_basis entirely -> hard error on required columns.
    T = readtable(testCase.TestData.csvFile, ...
        detectImportOptions(testCase.TestData.csvFile, ...
            "TextType", "string", "VariableNamingRule", "preserve"));
    T = removevars(T, "capacity_basis");
    badCsv = fullfile(testCase.TestData.tmpDir, "missing_col.csv");
    writetable(T, badCsv);
    verifyError(testCase, @() loadScenarios(badCsv), ...
        "loadScenarios:missingColumns");
end

function testEmptyCapacityBasisErrors(testCase)
    % Blank a single capacity_basis value -> fail-closed load error.
    opts = detectImportOptions(testCase.TestData.csvFile, ...
        "TextType", "string", "VariableNamingRule", "preserve");
    T = readtable(testCase.TestData.csvFile, opts);
    T.capacity_basis(3) = "";
    badCsv = fullfile(testCase.TestData.tmpDir, "blank_basis.csv");
    writetable(T, badCsv);
    verifyError(testCase, @() loadScenarios(badCsv), ...
        "loadScenarios:missingCapacityBasis");
end

function testBadArrivalWindowErrors(testCase)
    opts = detectImportOptions(testCase.TestData.csvFile, ...
        "TextType", "string", "VariableNamingRule", "preserve");
    T = readtable(testCase.TestData.csvFile, opts);
    T.arrival_end_hr(1) = T.arrival_start_hr(1);  % zero-width window
    badCsv = fullfile(testCase.TestData.tmpDir, "bad_window.csv");
    writetable(T, badCsv);
    verifyError(testCase, @() loadScenarios(badCsv), ...
        "loadScenarios:badArrivalWindow");
end

function testCapacityBasisIsPlaceholderEverywhere(testCase)
    % Documents the current data state: ALL rows are placeholder, so no
    % feasibility claim is possible anywhere in the portfolio (ML-04).
    T = loadScenarios(testCase.TestData.csvFile);
    verifyTrue(testCase, ...
        all(string(T.capacity_basis) == "placeholder"), ...
        "Adapter CSV is expected to declare placeholder capacity on " + ...
        "every row until utility/facility confirmation lands.");
end
