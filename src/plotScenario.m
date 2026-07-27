function figHandle = plotScenario(out, varargin)
%PLOTSCENARIO Professional scenario figure with mandatory provenance text.
%
%   figHandle = PLOTSCENARIO(out) renders the runScenario output as a
%   presentation-grade figure:
%       Tile 1 (wide) - 24-hour load: base load, unmanaged total,
%                       clamp total, energy-aware total, capacity limit
%                       (when defined).
%       Tile 2        - EV request vs managed EV output.
%       Tile 3        - summary bars: peaks, curtailed, unmet energy.
%
%   NON-NEGOTIABLE LABELING RULES (ML-01/ML-04):
%     * EVERY figure that shows a capacity value prints capacity_basis
%       on the capacity line label AND renders the guard's
%       placeholder_banner as a highlighted banner across the figure
%       whenever capacity is not verified. There is no option to
%       disable the banner while a capacity line is drawn.
%     * Every figure carries a source/date footer: canonical CSV name,
%       scenario_id, profile mode, generation timestamp (ML-12).
%
%   Name-value options:
%     'OutputFolder' - folder for the saved PNG (default: no save)
%     'SaveFigure'   - logical, default false
%     'Visible'      - logical, default true (set false for batch runs)
%
%   Saved file name pattern (ML-12):
%     scenario_<scenario_id>_<site_id>_<horizon>_<yyyymmddTHHMMSSZ>.png
%
%   Part of Milestone 2 V3 implementation (visual layer).

    p = inputParser;
    p.FunctionName = "plotScenario";
    addParameter(p, "OutputFolder", "", @(v) ischar(v) || isstring(v));
    addParameter(p, "SaveFigure", false, ...
        @(v) islogical(v) && isscalar(v));
    addParameter(p, "Visible", true, @(v) islogical(v) && isscalar(v));
    % The footer must report the file this run ACTUALLY read. It used to
    % hardcode the canonical adapter path, so a run against any other input --
    % a synthetic harness fixture, for instance -- produced figures asserting a
    % provenance that was not true. A figure that names a source it did not use
    % is a fabricated citation, which is the one thing this project may never do.
    addParameter(p, "SourceFile", "", @(v) ischar(v) || isstring(v));
    parse(p, varargin{:});
    opt = p.Results;

    s = out.scenario;
    guard = out.guard;
    prof = out.profiles;
    res = out.results;

    % Palette (colorblind-considerate, consistent with legacy visuals).
    cBase = [0.12 0.32 0.65];
    cUnmanaged = [0.82 0.20 0.16];
    cClamp = [0.90 0.43 0.14];
    cEnergyAware = [0.13 0.55 0.36];
    cCapacity = [0.32 0.22 0.55];
    cEV = [0.95 0.58 0.16];

    visibility = "on";
    if ~opt.Visible
        visibility = "off";
    end

    figHandle = figure("Name", "Site-Level EV Charging Analysis (V3)", ...
        "Color", "w", "Units", "pixels", ...
        "Position", [80 60 1450 860], "Visible", visibility);

    tl = tiledlayout(figHandle, 2, 2, ...
        "TileSpacing", "compact", "Padding", "compact");

    title(tl, "EV Charging Site-Load Behavior (Session-Based V3 Model)", ...
        "FontWeight", "bold", "FontSize", 18);
    % Interpreter "none" on every string that carries an identifier, a file name or a
    % controlled vocabulary value.
    %
    % MATLAB text defaults to the TeX interpreter, which reads "_" as "subscript the next
    % character". Every one of those strings is full of underscores, so the first real
    % figure this project ever generated rendered its own provenance footer as
    % "harness_scenarios_ynthetic.csv" -- with the s subscripted out of the file name -- and
    % the mandatory placeholder banner as "CAPACITY_BASIS=PLACEHOLDER" with the B dropped
    % below the line. A figure whose stated source is not the actual file name is a
    % provenance defect, not a typographical one, in a repository whose entire claim is that
    % every number can be traced.
    subtitle(tl, sprintf("%s | %s | horizon %d | case %s | " + ...
        "%d ports x %.1f kW | profile mode: %s", ...
        string(s.site_name), string(s.site_id), double(s.horizon_year), ...
        string(localFieldOr(s, "case_label", "unknown")), ...
        double(s.ports), double(s.charger_power_kW), prof.mode), ...
        "Interpreter", "none");

    % ---------------------------------------------------------------
    % Tile 1: 24-hour total load
    % ---------------------------------------------------------------
    ax1 = nexttile(tl, [1 2]);
    hold(ax1, "on"); grid(ax1, "on"); box(ax1, "on");

    plot(ax1, prof.t_hr, prof.baseLoad_kW, "Color", cBase, ...
        "LineWidth", 2.4, "DisplayName", "Base building load");
    plot(ax1, res.unmanaged.t_hr, res.unmanaged.total_kW, ...
        "Color", cUnmanaged, "LineWidth", 2.8, ...
        "DisplayName", "Total, unmanaged charging");
    if isfield(res, "clamp")
        plot(ax1, res.clamp.t_hr, res.clamp.total_kW, ...
            "Color", cClamp, "LineWidth", 2.4, ...
            "DisplayName", "Total, legacy clamp");
    end
    if isfield(res, "energy_aware")
        plot(ax1, res.energy_aware.t_hr, res.energy_aware.total_kW, ...
            "Color", cEnergyAware, "LineWidth", 2.8, ...
            "DisplayName", "Total, energy-aware managed");
    end
    if guard.capacity_defined
        % Capacity line label ALWAYS carries capacity_basis.
        plot(ax1, prof.t_hr, ...
            guard.capacity_kW * ones(size(prof.t_hr)), "--", ...
            "Color", cCapacity, "LineWidth", 2.8, ...
            "DisplayName", sprintf("Capacity limit [basis: %s]", ...
                guard.capacity_basis));
    end

    xlabel(ax1, "Hour of day", "FontWeight", "bold");
    ylabel(ax1, "Power (kW)", "FontWeight", "bold");
    title(ax1, "24-Hour Site Load Profile", "FontWeight", "bold");
    xlim(ax1, [0 24]); xticks(ax1, 0:2:24);
    legend(ax1, "Location", "northoutside", ...
        "Orientation", "horizontal", "NumColumns", 3);

    % ---------------------------------------------------------------
    % Tile 2: EV request vs managed output
    % ---------------------------------------------------------------
    ax2 = nexttile(tl);
    hold(ax2, "on"); grid(ax2, "on"); box(ax2, "on");

    plot(ax2, prof.t_hr, prof.evRequest_kW, "Color", cEV, ...
        "LineWidth", 2.6, "DisplayName", "EV request (session-based)");
    if isfield(res, "energy_aware")
        plot(ax2, res.energy_aware.t_hr, res.energy_aware.ev_kW, ...
            "Color", cEnergyAware, "LineWidth", 2.6, ...
            "DisplayName", "Energy-aware EV output");
    elseif isfield(res, "clamp")
        plot(ax2, res.clamp.t_hr, res.clamp.ev_kW, ...
            "Color", cClamp, "LineWidth", 2.6, ...
            "DisplayName", "Clamp EV output");
    end
    xlabel(ax2, "Hour of day", "FontWeight", "bold");
    ylabel(ax2, "EV power (kW)", "FontWeight", "bold");
    title(ax2, "EV Request vs Managed Output", "FontWeight", "bold");
    xlim(ax2, [0 24]); xticks(ax2, 0:4:24);
    legend(ax2, "Location", "northoutside", "Orientation", "horizontal");

    % ---------------------------------------------------------------
    % Tile 3: summary metrics
    % ---------------------------------------------------------------
    ax3 = nexttile(tl);
    hold(ax3, "on"); grid(ax3, "on"); box(ax3, "on");

    labels = "Peak unmanaged (kW)";
    values = res.unmanaged.peak_total_kW;
    if isfield(res, "clamp")
        labels(end+1) = "Peak clamp (kW)";
        values(end+1) = res.clamp.peak_total_kW;
        labels(end+1) = "Curtailed, clamp (kWh)";
        values(end+1) = res.clamp.curtailed_kWh;
    end
    if isfield(res, "energy_aware")
        labels(end+1) = "Peak energy-aware (kW)";
        values(end+1) = res.energy_aware.peak_total_kW;
        labels(end+1) = "Unmet, energy-aware (kWh)";
        values(end+1) = res.energy_aware.unmet_kWh;
    end

    cats = categorical(labels);
    cats = reordercats(cats, cellstr(labels));
    bar(ax3, cats, values, "FaceColor", cBase);
    ylabel(ax3, "kW / kWh", "FontWeight", "bold");
    title(ax3, "Scenario Summary Metrics", "FontWeight", "bold");
    xtickangle(ax3, 20);

    % ---------------------------------------------------------------
    % MANDATORY placeholder banner (whenever capacity is not verified)
    % ---------------------------------------------------------------
    if strlength(guard.placeholder_banner) > 0
        annotation(figHandle, "textbox", [0.05 0.955 0.90 0.040], ...
            "String", upper(string(guard.placeholder_banner)), ...
            "FitBoxToText", "off", ...
            "BackgroundColor", [1.00 0.92 0.80], ...
            "EdgeColor", [0.80 0.45 0.10], ...
            "FontSize", 10, "FontWeight", "bold", ...
            "HorizontalAlignment", "center", ...
            "VerticalAlignment", "middle", ...
            "Interpreter", "none");
    end

    % ---------------------------------------------------------------
    % Source/date footer on every figure (ML-12)
    % ---------------------------------------------------------------
    stampUtc = string(datetime("now", "TimeZone", "UTC", ...
        "Format", "yyyy-MM-dd'T'HH:mm:ss'Z'"));
    sourceLabel = string(opt.SourceFile);
    if strlength(sourceLabel) == 0
        sourceLabel = "source not recorded by caller";
    else
        [~, srcName, srcExt] = fileparts(char(sourceLabel));
        sourceLabel = string(srcName) + string(srcExt);
    end
    footer = sprintf("Source: %s | scenario %s | capacity basis: %s " + ...
        "| generated %s | Milestone 2 V3 MATLAB model", ...
        sourceLabel, string(s.scenario_id), guard.capacity_basis, stampUtc);
    annotation(figHandle, "textbox", [0.02 0.001 0.96 0.028], ...
        "String", footer, "FitBoxToText", "off", ...
        "EdgeColor", "none", "FontSize", 8, ...
        "Color", [0.35 0.35 0.35], "HorizontalAlignment", "center", ...
        "Interpreter", "none");

    % ---------------------------------------------------------------
    % Save (scenario/site/horizon/date in the file name - ML-12)
    % ---------------------------------------------------------------
    if opt.SaveFigure
        outFolder = string(opt.OutputFolder);
        if outFolder == ""
            error("plotScenario:noOutputFolder", ...
                "SaveFigure=true requires 'OutputFolder'.");
        end
        if ~exist(outFolder, "dir")
            mkdir(outFolder);
        end
        fileStamp = string(datetime("now", "TimeZone", "UTC", ...
            "Format", "yyyyMMdd'T'HHmmss'Z'"));
        outFile = fullfile(outFolder, sprintf( ...
            "scenario_%s_%s_%d_%s.png", ...
            localSafeName(s.scenario_id), localSafeName(s.site_id), ...
            double(s.horizon_year), fileStamp));
        exportgraphics(figHandle, outFile, "Resolution", 200);
        fprintf("Saved figure: %s\n", outFile);
    end
end

% =====================================================================
% Local helpers
% =====================================================================

function v = localFieldOr(s, fieldName, defaultValue)
    if isfield(s, fieldName)
        v = s.(fieldName);
    else
        v = defaultValue;
    end
end

function nameOut = localSafeName(nameIn)
%LOCALSAFENAME File-system-safe token.
    nameOut = string(regexprep(char(string(nameIn)), ...
        '[^a-zA-Z0-9]+', '_'));
end
