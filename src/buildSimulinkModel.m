function modelPath = buildSimulinkModel(out, varargin)
%BUILDSIMULINKMODEL Optional, illustrative Simulink layer (ML-07).
%
%   modelPath = BUILDSIMULINKMODEL(out) builds the demonstration
%   Simulink model from a runScenario output ONCE, if and only if the
%   .slx file does not already exist. It NEVER deletes or rebuilds an
%   existing model (this reverses the legacy delete/rebuild behavior,
%   hypothesis H8, which destroyed traceability on every run).
%
%   IMPORTANT SCOPE STATEMENT: this layer is ILLUSTRATIVE, not
%   load-bearing. Every metric in this repository (profiles, strategies,
%   energy balance, economics, batch results) is computed by the plain
%   MATLAB pipeline (makeSessionProfiles / managedCharging /
%   electricalEconomics), which runs in base MATLAB without Simulink.
%   The Simulink model exists only to visualize signal flow for
%   presentations and stakeholder walkthroughs.
%
%   Behavior:
%     * Requires Simulink; errors with a clear message when the Simulink
%       license/installation is absent (the core pipeline is unaffected).
%     * Builds <ModelName>.slx in 'ModelFolder' only when missing.
%     * Externalizes scenario parameters: a params struct is written to
%       a Simulink data dictionary (<ModelName>_params.sldd) when the
%       data-dictionary API is available; the same struct is always
%       saved as <ModelName>_params.mat alongside the model so the
%       parameterization is inspectable without Simulink.
%     * Version-stamps the model Description with the repo version,
%       scenario id, and UTC build time.
%     * Loads the scenario timeseries into the base workspace for the
%       From Workspace blocks (as in the legacy model).
%
%   Name-value options:
%     'ModelName'   - default "site_grid_behavior_ev_charging_v3"
%     'ModelFolder' - default <repo>/simulink
%
%   Part of Milestone 2 V3 implementation (item ML-07).

    MODEL_VERSION = "3.0.0";

    p = inputParser;
    p.FunctionName = "buildSimulinkModel";
    addParameter(p, "ModelName", "site_grid_behavior_ev_charging_v3", ...
        @(v) ischar(v) || isstring(v));
    thisDir = fileparts(mfilename("fullpath"));
    repoRoot = fileparts(thisDir);
    addParameter(p, "ModelFolder", fullfile(repoRoot, "simulink"), ...
        @(v) ischar(v) || isstring(v));
    parse(p, varargin{:});
    modelName = char(string(p.Results.ModelName));
    modelFolder = string(p.Results.ModelFolder);

    % ---------------------------------------------------------------
    % Simulink availability check - the pipeline must not depend on it
    % ---------------------------------------------------------------
    if exist("new_system", "file") ~= 2 || ~license("test", "Simulink")
        error("buildSimulinkModel:simulinkUnavailable", ...
            "Simulink is not available in this MATLAB installation. " + ...
            "This layer is OPTIONAL and illustrative only - all " + ...
            "metrics come from the base-MATLAB pipeline (runScenario / " + ...
            "run_all_scenarios), which you can use without Simulink.");
    end

    if ~exist(modelFolder, "dir")
        mkdir(modelFolder);
    end
    modelPath = fullfile(modelFolder, modelName + ".slx");

    % ---------------------------------------------------------------
    % Externalized parameters (written regardless of build/skip)
    % ---------------------------------------------------------------
    s = out.scenario;
    prof = out.profiles;
    guard = out.guard;

    params = struct();
    params.model_version = MODEL_VERSION;
    params.scenario_id = string(s.scenario_id);
    params.site_id = string(s.site_id);
    params.horizon_year = double(s.horizon_year);
    params.capacity_basis = guard.capacity_basis;
    params.capacity_kW = guard.capacity_kW;
    params.charger_power_kW = double(s.charger_power_kW);
    params.ports = double(s.ports);
    params.profile_mode = string(prof.mode);
    params.dt_sec = prof.dt_hr * 3600;
    params.stop_time_sec = 24 * 3600;
    params.built_utc = string(datetime("now", "TimeZone", "UTC", ...
        "Format", "yyyy-MM-dd'T'HH:mm:ss'Z'"));
    params.note = "Illustrative Simulink layer; metrics are computed " + ...
        "by the base-MATLAB pipeline, not by this model.";

    % Always inspectable without Simulink:
    save(fullfile(modelFolder, modelName + "_params.mat"), "params");

    % Data dictionary when the API exists (Simulink present).
    try
        dictPath = fullfile(modelFolder, modelName + "_params.sldd");
        if ~isfile(dictPath)
            dict = Simulink.data.dictionary.create(dictPath);
        else
            dict = Simulink.data.dictionary.open(dictPath);
        end
        section = getSection(dict, "Design Data");
        try
            entry = getEntry(section, "scenario_params");
            setValue(entry, params);
        catch
            addEntry(section, "scenario_params", params);
        end
        saveChanges(dict);
        close(dict);
    catch dictME
        warning("buildSimulinkModel:dictionarySkipped", ...
            "Data dictionary not written (%s). Parameters remain " + ...
            "available in %s_params.mat.", dictME.message, modelName);
    end

    % ---------------------------------------------------------------
    % Timeseries for the From Workspace blocks (legacy interface)
    % ---------------------------------------------------------------
    t_sec = prof.t_hr * 3600;
    assignin("base", "baseLoad_ts", timeseries(prof.baseLoad_kW, t_sec));
    assignin("base", "evRequest_ts", timeseries(prof.evRequest_kW, t_sec));
    if guard.capacity_defined
        capVec = guard.capacity_kW * ones(size(t_sec));
    else
        % No capacity defined: feed NaN so the scope makes the absence
        % visible instead of implying a limit that does not exist.
        capVec = nan(size(t_sec));
    end
    assignin("base", "capacity_ts", timeseries(capVec, t_sec));

    % ---------------------------------------------------------------
    % Build ONCE; never delete or rebuild an existing model (ML-07)
    % ---------------------------------------------------------------
    if isfile(modelPath)
        fprintf("buildSimulinkModel: %s already exists - NOT rebuilt " + ...
            "(build-once policy). Parameters refreshed in the data " + ...
            "dictionary / params.mat.\n", modelPath);
        return;
    end

    fprintf("buildSimulinkModel: creating %s (one-time build)...\n", ...
        modelPath);

    new_system(modelName);
    set_param(modelName, "StopTime", num2str(params.stop_time_sec));
    set_param(modelName, "Solver", "ode3");
    set_param(modelName, "FixedStep", num2str(params.dt_sec));

    % Version stamp (ML-07): visible in Model Properties.
    set_param(modelName, "Description", sprintf( ...
        "Site-level EV charging behavior - ILLUSTRATIVE LAYER.\n" + ...
        "Version %s | built %s | scenario %s | capacity_basis %s.\n" + ...
        "All quantitative results come from the MATLAB pipeline " + ...
        "(runScenario), not from this model.", ...
        MODEL_VERSION, params.built_utc, params.scenario_id, ...
        params.capacity_basis));

    % Blocks (same topology as the reviewed legacy model).
    add_block("simulink/Sources/From Workspace", ...
        [modelName '/Base Load'], "Position", [40 70 160 100], ...
        "VariableName", "baseLoad_ts");
    add_block("simulink/Sources/From Workspace", ...
        [modelName '/EV Request'], "Position", [40 160 160 190], ...
        "VariableName", "evRequest_ts");
    add_block("simulink/Sources/From Workspace", ...
        [modelName '/Capacity Limit'], "Position", [40 250 160 280], ...
        "VariableName", "capacity_ts");

    add_block("simulink/Math Operations/Sum", ...
        [modelName '/Total Unmanaged'], ...
        "Position", [240 115 285 160], "Inputs", "++");

    add_block("simulink/Signal Routing/Mux", ...
        [modelName '/Managed Logic Inputs'], ...
        "Position", [240 215 250 295], "Inputs", "3");

    add_block("simulink/User-Defined Functions/MATLAB Function", ...
        [modelName '/Managed EV Power'], "Position", [320 230 455 280]);

    rt = sfroot;
    chart = rt.find("-isa", "Stateflow.EMChart", ...
        "Path", [modelName '/Managed EV Power']);
    chart.Script = sprintf(['function y = fcn(u)\n' ...
        '%% u(1) = EV request, u(2) = capacity, u(3) = base load\n' ...
        '%% Illustrative clamp only - see managedCharging.m for the\n' ...
        '%% authoritative strategies incl. the energy-aware scheduler.\n' ...
        'available = max(u(2) - u(3), 0);\n' ...
        'y = min(u(1), available);\n' ...
        'end']);

    add_block("simulink/Math Operations/Sum", ...
        [modelName '/Total Managed'], ...
        "Position", [530 160 575 205], "Inputs", "++");

    add_block("simulink/Signal Routing/Mux", ...
        [modelName '/Main Scope Signals'], ...
        "Position", [665 85 675 250], "Inputs", "4");

    add_block("simulink/Sinks/Scope", ...
        [modelName '/Live Scope: Load Behavior'], ...
        "Position", [760 115 900 210]);

    add_block("simulink/Sinks/To Workspace", ...
        [modelName '/toWorkspace_unmanaged'], ...
        "Position", [665 300 815 330], ...
        "VariableName", "sim_total_unmanaged", ...
        "SaveFormat", "Structure With Time");
    add_block("simulink/Sinks/To Workspace", ...
        [modelName '/toWorkspace_managed'], ...
        "Position", [665 350 815 380], ...
        "VariableName", "sim_total_managed", ...
        "SaveFormat", "Structure With Time");

    % Connections.
    add_line(modelName, "Base Load/1", "Total Unmanaged/1");
    add_line(modelName, "EV Request/1", "Total Unmanaged/2");
    add_line(modelName, "EV Request/1", "Managed Logic Inputs/1");
    add_line(modelName, "Capacity Limit/1", "Managed Logic Inputs/2");
    add_line(modelName, "Base Load/1", "Managed Logic Inputs/3");
    add_line(modelName, "Managed Logic Inputs/1", "Managed EV Power/1");
    add_line(modelName, "Base Load/1", "Total Managed/1");
    add_line(modelName, "Managed EV Power/1", "Total Managed/2");
    add_line(modelName, "Base Load/1", "Main Scope Signals/1");
    add_line(modelName, "Total Unmanaged/1", "Main Scope Signals/2");
    add_line(modelName, "Total Managed/1", "Main Scope Signals/3");
    add_line(modelName, "Capacity Limit/1", "Main Scope Signals/4");
    add_line(modelName, "Main Scope Signals/1", ...
        "Live Scope: Load Behavior/1");
    add_line(modelName, "Total Unmanaged/1", "toWorkspace_unmanaged/1");
    add_line(modelName, "Total Managed/1", "toWorkspace_managed/1");

    save_system(modelName, modelPath);
    close_system(modelName, 0);

    fprintf("buildSimulinkModel: model saved to %s (version %s).\n", ...
        modelPath, MODEL_VERSION);
end
