function tests = test_regression
%TEST_REGRESSION Golden summary-metric regression harness (ML-09).
%
%   Runs a fixed panel of scenarios (fixed seeds, fixed assumed planning
%   capacity so the capacity-limited strategies execute) and compares
%   summary metrics against tests/golden/regression_golden.csv with a
%   relative tolerance.
%
%   FIRST RUN on a licensed machine: the golden file does not exist yet
%   (it can only be produced by executing MATLAB, and none was available
%   when this repository was authored - see EXECUTION_STATUS.md). The
%   harness then WRITES the golden file, logs that fact, and passes the
%   comparison against the freshly written baseline. Commit the golden
%   file; every later run compares against it and fails on drift.
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
    testCase.TestData.goldenFile = fullfile(thisDir, "golden", ...
        "regression_golden.csv");
    testCase.TestData.seed = 42;                 % fixed forever
    % Fixed planning capacity for the panel. It was 200 kW, and the first real
    % MathWorks run showed why that was wrong: at 200 the cap never binds, so
    % curtailed_clamp_kWh and unmet_energy_aware_kWh came back identically zero
    % and peak_clamp_kW equalled peak_unmanaged_kW on every row. Four of the seven
    % golden columns carried no information, and a regression baseline that cannot
    % tell the managed strategies apart from the unmanaged one would not detect a
    % regression in them.
    %
    % 100 kW binds in both trees, which matters because this test runs against the
    % real canonical CSV here and against a synthetic fixture in the public harness:
    % 10 of 20 panel rows curtail on the canonical data and 20 of 20 on the harness
    % fixture. A mix is better than all-or-nothing - it exercises the bound and the
    % unbound path in one panel.
    testCase.TestData.assumedCap_kW = 100;       % binds; see note above
    testCase.TestData.relTol = 1e-6;             % deterministic panel
end

% =====================================================================
% Tests
% =====================================================================

function testGoldenSummaryMetrics(testCase)
    current = localComputePanel(testCase);

    goldenFile = testCase.TestData.goldenFile;
    goldenDir = fileparts(goldenFile);

    if ~isfile(goldenFile)
        if ~exist(goldenDir, "dir")
            mkdir(goldenDir);
        end
        writetable(current, goldenFile);
        log(testCase, 1, sprintf("GOLDEN CREATED at %s - commit this " + ...
            "file; subsequent runs will compare against it.", ...
            goldenFile));
    end

    golden = readtable(goldenFile, "TextType", "string");

    verifyEqual(testCase, height(current), height(golden), ...
        "Panel size changed - regenerate the golden deliberately.");

    metricCols = ["energy_requested_kWh", "peak_unmanaged_kW", ...
        "peak_clamp_kW", "curtailed_clamp_kWh", ...
        "peak_energy_aware_kW", "unmet_energy_aware_kWh", ...
        "deferred_energy_aware_kWh"];

    for i = 1:height(current)
        verifyEqual(testCase, string(current.scenario_id(i)), ...
            string(golden.scenario_id(i)), ...
            "Panel ordering/composition changed.");
        for col = metricCols
            cv = current.(col)(i);
            gv = golden.(col)(i);
            if isnan(gv)
                verifyTrue(testCase, isnan(cv), sprintf( ...
                    "%s / %s: expected NaN, got %.9g.", ...
                    string(current.scenario_id(i)), col, cv));
            else
                verifyEqual(testCase, cv, gv, ...
                    "RelTol", testCase.TestData.relTol, sprintf( ...
                    "Metric drift: %s / %s.", ...
                    string(current.scenario_id(i)), col));
            end
        end
    end
end

function testPanelIsDeterministic(testCase)
    % The panel must be exactly reproducible run-to-run (fixed seed).
    a = localComputePanel(testCase);
    b = localComputePanel(testCase);
    metricCols = ["energy_requested_kWh", "peak_unmanaged_kW", ...
        "peak_clamp_kW", "peak_energy_aware_kW"];
    for col = metricCols
        verifyEqual(testCase, a.(col), b.(col), "AbsTol", 0, ...
            "Panel must be bit-for-bit reproducible with fixed seeds.");
    end
end

% =====================================================================
% Local helpers
% =====================================================================

function panel = localComputePanel(testCase)
%LOCALCOMPUTEPANEL Fixed scenario panel -> one summary row per scenario.
%   Panel: the FIRST TWO site ids in sorted order, across every horizon in
%   the data, first case per horizon in canonical order. Reading the ids from
%   the data rather than naming them keeps the panel deterministic while
%   letting the same test run against a synthetic public-harness fixture
%   without publishing a real facility id.
    allRows = loadScenarios(testCase.TestData.csvFile);
    panelSites = unique(string(allRows.site_id));
    panelSites = sort(panelSites);
    panelSites = panelSites(1:min(2, numel(panelSites))).';
    T = loadScenarios(testCase.TestData.csvFile, "SiteId", panelSites);
    horizons = unique(T.horizon_year);

    rows = {};
    for site = panelSites
        for h = horizons(:).'
            sub = T(string(T.site_id) == site & ...
                T.horizon_year == h, :);
            sub = sortrows(sub, "scenario_id");
            rows{end+1} = sub(1, :); %#ok<AGROW>
        end
    end

    n = numel(rows);
    metricStructs = cell(n, 1);
    for k = 1:n
        out = runScenario(rows{k}, ...
            "GuardMode", "planning_illustration", ...
            "ProfileMode", "deterministic_sessions", ...
            "Seed", testCase.TestData.seed, ...
            "AssumedSiteCapacity_kW", testCase.TestData.assumedCap_kW);
        m = out.metrics;
        keep = struct();
        keep.scenario_id = m.scenario_id;
        keep.energy_requested_kWh = m.energy_requested_kWh;
        keep.peak_unmanaged_kW = m.peak_unmanaged_kW;
        keep.peak_clamp_kW = m.peak_clamp_kW;
        keep.curtailed_clamp_kWh = m.curtailed_clamp_kWh;
        keep.peak_energy_aware_kW = m.peak_energy_aware_kW;
        keep.unmet_energy_aware_kWh = m.unmet_energy_aware_kWh;
        keep.deferred_energy_aware_kWh = m.deferred_energy_aware_kWh;
        metricStructs{k} = keep;
    end
    panel = struct2table([metricStructs{:}].');
end
