function opts = scenarioImportOptions(csvFile)
%SCENARIOIMPORTOPTIONS Import options for the canonical scenario CSV. One definition.
%
%   The delimiter, the header line and the first data line are SPECIFIED, not detected.
%   The Python producer writes comma-separated data with a header on line 1; there is
%   nothing to guess, and guessing was actively wrong.
%
%   The first real MathWorks runs proved it twice over. detectImportOptions inspected a
%   row whose free-text columns carry more spaces than the row has commas and concluded
%   the delimiter was whitespace: 51 variables instead of 22, header taken from line 2,
%   119 rows instead of 120. loadScenarios then reported every required column missing,
%   which is a confusing way to be told the file was never parsed as a CSV.
%
%   Fixing that in loadScenarios alone was not enough: three tests built their own
%   options inline and kept the bug, so removevars(T,"capacity_basis") failed on a table
%   that had no such column. Hence one definition, used by the loader and by every test
%   that needs to read the same file. A shared parser cannot drift from itself.
%
%   Note DataLines and VariableNamesLine are PROPERTIES of the returned object, not
%   constructor arguments - passing DataLines to detectImportOptions raises
%   "Unknown Parameter 'DataLines'", which is how the harness found this.

    opts = detectImportOptions(csvFile, ...
        "Delimiter", ",", ...
        "TextType", "string", ...
        "VariableNamingRule", "preserve");
    opts.VariableNamesLine = 1;
    opts.DataLines = [2 Inf];

    % "case" is a MATLAB keyword; the column name is preserved on import and renamed to
    % case_label by loadScenarios for safe dot access (see DATA_DICTIONARY.md).
    stringCols = ["scenario_id", "site_id", "site_name", "case", ...
                  "capacity_basis", "capacity_source", ...
                  "managed_charging_policy", "electrical_risk_level", ...
                  "source_note"];
    present = intersect(stringCols, string(opts.VariableNames));
    if ~isempty(present)
        opts = setvartype(opts, present, "string");
    end
end
