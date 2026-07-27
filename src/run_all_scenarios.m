function outDir = run_all_scenarios(varargin)
%RUN_ALL_SCENARIOS Batch runner: all sites x horizons x cases x strategies.
%
%   outDir = RUN_ALL_SCENARIOS() runs every row of the canonical scenario
%   CSV through runScenario (unmanaged + clamp + energy_aware where a
%   capacity value exists) and writes a normalized results table plus a
%   manifest with SHA-256 hashes (ML-08, ML-12).
%
%   Headless invocation on a licensed machine:
%       matlab -batch "addpath('src'); run_all_scenarios"
%
%   Outputs, under outputs/<run_id>/ where
%   run_id = batch_<UTCyyyymmddTHHMMSSZ>:
%       results.csv   - one row per scenario (all metrics from
%                       runScenario, incl. capacity_basis and the
%                       mandatory placeholder banner text)
%       manifest.txt  - run metadata: run_id, UTC stamp, MATLAB release,
%                       input CSV path, row count, options used
%       hashes.txt    - SHA-256 of the input CSV and of results.csv
%                       (computed with java.security.MessageDigest -
%                       available in base MATLAB)
%
%   File names carry scenario/site/horizon/date wherever per-scenario
%   artifacts are produced (see plotScenario.m) - ML-12.
%
%   Name-value options:
%     'CsvFile'     - scenario CSV path. Default: resolveScenarioCsv(), which
%                     finds the canonical adapter CSV in the private repository
%                     and the synthetic fixture in the public CI harness, so the
%                     same sources run unmodified in both.
%     'OutputRoot'  - default <repo>/outputs
%     'ProfileMode' - forwarded to runScenario (default
%                     "deterministic_sessions")
%     'Seed'        - forwarded (default 42)
%     'Tariff'      - optional tariff struct, forwarded
%     'AssumedSiteCapacity_kW' - forwarded labeled planning assumption
%     'SavePlots'   - logical, default false; when true, calls
%                     plotScenario for every scenario (slower)
%
%   Part of Milestone 2 V3 implementation (items ML-08, ML-12).

    thisDir = fileparts(mfilename("fullpath"));
    repoRoot = fileparts(thisDir);

    p = inputParser;
    p.FunctionName = "run_all_scenarios";
    % Default is a sentinel, resolved AFTER parsing rather than here.
    %
    % addParameter(p, "CsvFile", resolveScenarioCsv(), ...) evaluates the resolver eagerly,
    % every call, even when the caller supplies an explicit path -- so in any tree without a
    % default CSV this function errored before it ever looked at the path it was given.
    % Found while running the model under Octave from a transformed source tree, where no
    % data directory exists at all: the run died on the default it was never going to use.
    addParameter(p, "CsvFile", "", ...
        @(v) ischar(v) || isstring(v));
    addParameter(p, "OutputRoot", fullfile(repoRoot, "outputs"), ...
        @(v) ischar(v) || isstring(v));
    addParameter(p, "ProfileMode", "deterministic_sessions", ...
        @(v) ismember(string(v), ["deterministic_sessions", ...
            "stochastic", "legacy_gaussian"]));
    addParameter(p, "Seed", 42, @(v) isnumeric(v) && isscalar(v));
    addParameter(p, "Tariff", struct.empty, @(v) isstruct(v));
    addParameter(p, "AssumedSiteCapacity_kW", NaN, ...
        @(v) isnumeric(v) && isscalar(v));
    addParameter(p, "SavePlots", false, ...
        @(v) islogical(v) && isscalar(v));
    parse(p, varargin{:});
    opt = p.Results;

    % ---------------------------------------------------------------
    % Run folder (date-stamped run_id - ML-12)
    % ---------------------------------------------------------------
    stampUtc = string(datetime("now", "TimeZone", "UTC", ...
        "Format", "yyyyMMdd'T'HHmmss'Z'"));
    runId = "batch_" + stampUtc;
    outDir = fullfile(string(opt.OutputRoot), runId);
    if ~exist(outDir, "dir")
        mkdir(outDir);
    end

    % ---------------------------------------------------------------
    % Load all scenarios (horizons/cases come from the data - ML-06)
    % ---------------------------------------------------------------
    if strlength(string(opt.CsvFile)) == 0
        opt.CsvFile = resolveScenarioCsv();
    end
    T = loadScenarios(opt.CsvFile);
    nRows = height(T);
    fprintf("run_all_scenarios: %d scenario rows loaded from %s\n", ...
        nRows, string(opt.CsvFile));
    fprintf("Horizons in data: %s\n", ...
        strjoin(string(unique(T.horizon_year)), ", "));

    % ---------------------------------------------------------------
    % Run every scenario
    % ---------------------------------------------------------------
    metricRows = cell(nRows, 1);
    for i = 1:nRows
        row = T(i, :);
        try
            out = runScenario(row, ...
                "GuardMode", "planning_illustration", ...
                "ProfileMode", opt.ProfileMode, ...
                "Seed", opt.Seed, ...
                "Tariff", opt.Tariff, ...
                "AssumedSiteCapacity_kW", opt.AssumedSiteCapacity_kW);
            m = out.metrics;
            m.run_status = "ok";
            m.run_error = "";
            if opt.SavePlots
                plotScenario(out, "OutputFolder", outDir, ...
                    "SaveFigure", true, "Visible", false, ...
                    "SourceFile", string(opt.CsvFile));
            end
        catch ME
            % A failed scenario is recorded, never silently dropped.
            m = localErrorMetricsRow(row, ME);
        end
        m.run_id = runId;
        % orderfields: success and error rows carry the same field SET;
        % normalizing order makes the struct array concatenation safe.
        metricRows{i} = orderfields(m);
        fprintf("  [%3d/%3d] %-32s %s\n", i, nRows, ...
            string(row.scenario_id), m.run_status);
    end

    results = struct2table([metricRows{:}].');

    % ---------------------------------------------------------------
    % Write results + manifest + hashes
    % ---------------------------------------------------------------
    resultsFile = fullfile(outDir, "results.csv");
    writetable(results, resultsFile);

    manifestFile = fullfile(outDir, "manifest.txt");
    fid = fopen(manifestFile, "w");
    assert(fid > 0, "Could not open manifest file for writing.");
    fprintf(fid, "run_id: %s\n", runId);
    fprintf(fid, "generated_utc: %s\n", stampUtc);
    fprintf(fid, "matlab_release: %s\n", version("-release"));
    % Record the input by NAME, not by absolute path: the manifest is an
    % artifact that travels (CI upload, public harness), and a full path leaks
    % the local filesystem layout of whoever ran it.
    [~, csvName, csvExt] = fileparts(char(string(opt.CsvFile)));
    fprintf(fid, "input_csv: %s\n", string(csvName) + string(csvExt));
    fprintf(fid, "scenario_rows: %d\n", nRows);
    fprintf(fid, "profile_mode: %s\n", string(opt.ProfileMode));
    fprintf(fid, "seed: %g\n", opt.Seed);
    fprintf(fid, "tariff_supplied: %d\n", ~isempty(opt.Tariff));
    fprintf(fid, "assumed_site_capacity_kW: %g\n", ...
        opt.AssumedSiteCapacity_kW);
    fprintf(fid, "note: capacity_basis=placeholder rows carry the\n");
    fprintf(fid, "  mandatory planning-placeholder banner; no output\n");
    fprintf(fid, "  of this run is a feasibility claim.\n");
    fclose(fid);

    hashesFile = fullfile(outDir, "hashes.txt");
    fid = fopen(hashesFile, "w");
    assert(fid > 0, "Could not open hashes file for writing.");
    % Hash by file NAME for the same reason as above. Note the input hash is a
    % confirmation oracle -- anyone holding a candidate reconstruction of a
    % private input can test it for an exact match -- so a public harness must
    % hash only the fixture it actually shipped, never a private input.
    [~, resName, resExt] = fileparts(char(string(resultsFile)));
    fprintf(fid, "%s  %s\n", localSha256(opt.CsvFile), ...
        string(csvName) + string(csvExt));
    fprintf(fid, "%s  %s\n", localSha256(resultsFile), ...
        string(resName) + string(resExt));
    fclose(fid);

    fprintf("\nBatch complete. Results: %s\n", resultsFile);
    fprintf("Manifest: %s\nHashes: %s\n", manifestFile, hashesFile);
end

% =====================================================================
% Local helpers
% =====================================================================

function m = localErrorMetricsRow(row, ME)
%LOCALERRORMETRICSROW Metrics placeholder for a failed scenario run.
    m = struct();
    m.scenario_id = string(row.scenario_id);
    m.site_id = string(row.site_id);
    m.horizon_year = double(row.horizon_year);
    m.case_label = string(row.case_label);
    m.profile_mode = "";
    m.capacity_basis = string(row.capacity_basis);
    m.capacity_verified = false;
    m.capacity_kW = NaN;
    m.energy_requested_kWh = NaN;
    m.peak_base_kW = NaN;
    m.peak_unmanaged_kW = NaN;
    m.peak_clamp_kW = NaN;
    m.curtailed_clamp_kWh = NaN;
    m.peak_energy_aware_kW = NaN;
    m.unmet_energy_aware_kWh = NaN;
    m.deferred_energy_aware_kWh = NaN;
    m.service_check = "run_failed";
    m.cost_status = "run_failed";
    m.demand_charge_savings_usd_month = NaN;
    m.placeholder_banner = "";
    m.skipped_strategies = "all";
    m.run_status = "error";
    m.run_error = string(ME.message);
end

function hexHash = localSha256(filePath)
%LOCALSHA256 SHA-256 of a file via java.security.MessageDigest
%   (works in base MATLAB; no toolbox required).
    fid = fopen(filePath, "r");
    assert(fid > 0, "Cannot open file for hashing: %s", filePath);
    bytes = fread(fid, Inf, "*uint8");
    fclose(fid);

    md = java.security.MessageDigest.getInstance("SHA-256");
    md.update(bytes);
    digest = typecast(md.digest(), "uint8");
    hexHash = lower(string(reshape(dec2hex(digest, 2).', 1, [])));
end
