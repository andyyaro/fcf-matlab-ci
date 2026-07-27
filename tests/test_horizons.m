function tests = test_horizons
%TEST_HORIZONS Horizon flexibility tests (ML-06).
%   The legacy scripts hard-coded years = ["Now","2035","2050"] (H7).
%   These tests prove the V3 pipeline runs 2036/2046/2056 with no script
%   edits, and that an arbitrary new horizon row (e.g. 2070) works.
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

function testAllCanonicalHorizonsRun(testCase)
    % 2026 / 2036 / 2046 / 2056 all run end-to-end without any edits.
    %% Site ids are read FROM THE DATA, never hard-coded. The same discipline
    %% ML-06 applies to horizons applies here: these sources are mirrored into a
    %% PUBLIC harness repository, so naming a real facility id in a test would
    %% publish client identity. Reading the id keeps the test valid against the
    %% private canonical CSV and against a synthetic harness fixture alike.
    allRows = loadScenarios(testCase.TestData.csvFile);
    siteId = string(allRows.site_id(1));
    T = loadScenarios(testCase.TestData.csvFile, "SiteId", siteId);
    horizons = unique(T.horizon_year);
    verifyEqual(testCase, sort(horizons(:)).', [2026 2036 2046 2056]);

    for h = horizons(:).'
        rows = T(T.horizon_year == h, :);
        out = runScenario(rows(1, :), ...
            "GuardMode", "planning_illustration");
        verifyEqual(testCase, out.metrics.horizon_year, double(h));
        verifyGreaterThan(testCase, out.metrics.peak_unmanaged_kW, 0);
    end
end

function testNoHardCodedYearListInSources(testCase)
    % Static guard: no source file may hard-code the legacy year list.
    thisDir = fileparts(mfilename("fullpath"));
    srcDir = fullfile(fileparts(thisDir), "src");
    files = dir(fullfile(srcDir, "*.m"));
    for k = 1:numel(files)
        txt = fileread(fullfile(files(k).folder, files(k).name));
        verifyFalse(testCase, ...
            contains(txt, 'years = ["Now"'), ...
            sprintf("%s contains a hard-coded legacy year list.", ...
                files(k).name));
    end
end

function testArbitraryNewHorizonRowRuns(testCase)
    % Append a 2070 row (a horizon that exists nowhere in the code) to a
    % copy of the CSV; loading and running it must need no script edits.
    opts = detectImportOptions(testCase.TestData.csvFile, ...
        "TextType", "string", "VariableNamingRule", "preserve");
    T = readtable(testCase.TestData.csvFile, opts);

    newRow = T(1, :);
    newRow.scenario_id = "FFX002_2070_base";
    newRow.("horizon_year") = 2070;
    newRow.("case") = "base";
    newRow.ports = 10;
    newRow.sessions_per_day = 8.0;
    T2 = [T; newRow];

    tmpCsv = fullfile(testCase.TestData.tmpDir, "with_2070.csv");
    writetable(T2, tmpCsv);

    loaded = loadScenarios(tmpCsv, "HorizonYear", 2070);
    verifyEqual(testCase, height(loaded), 1);
    verifyEqual(testCase, loaded.horizon_year(1), 2070);

    out = runScenario(loaded(1, :), ...
        "GuardMode", "planning_illustration");
    verifyEqual(testCase, out.metrics.horizon_year, 2070);
    verifyGreaterThan(testCase, out.metrics.energy_requested_kWh, 0);
end

function testHorizonFilterIsDataDriven(testCase)
    % Filtering on a horizon absent from the data errors cleanly instead
    % of silently returning a default year.
    verifyError(testCase, ...
        @() loadScenarios(testCase.TestData.csvFile, ...
            "HorizonYear", 1999), ...
        "loadScenarios:noMatch");
end
