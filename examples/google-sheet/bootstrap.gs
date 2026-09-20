/**
 * Bootstrap script for the LinkedIn Job Search automation's Google Sheet.
 *
 * What it does: creates the Config, Results, Settings, and Resume tabs
 * (renaming/reusing the default "Sheet1" for the first one) with the correct
 * headers, then populates Config with the example company list, Settings
 * with working Bengaluru/4yr defaults, and Resume with either your own data
 * (if you fill in RESUME_JSON below) or placeholder values you're expected
 * to edit afterward. Results is left with headers only — the workflow
 * writes rows there at runtime.
 *
 * The Settings tab is a live, edit-anytime override for the location/
 * experience/match-threshold env vars documented in SETUP_GUIDE.md — the
 * workflow reads it fresh on every run, no container restart needed. Leave
 * a Settings row's Value blank to fall back to the matching env var, or to
 * the hardcoded default if that's blank too.
 *
 * How to use:
 *   1. Create a new blank Google Sheet.
 *   2. Extensions -> Apps Script.
 *   3. Delete the placeholder code, paste this whole file in, save.
 *   4. (Optional) Run your resume through the prompt in the README's "Resume
 *      → Sheet" section against any LLM, and paste the JSON it returns as
 *      the value of RESUME_JSON below (keep the quotes, it's a JS string).
 *      Skip this and leave it blank to get placeholder values instead.
 *   5. Run the `bootstrap` function once (Run menu, or the ▶ button).
 *      First run will prompt for authorization (this script only touches
 *      the sheet it's bound to, plus a public raw.githubusercontent.com
 *      fetch to pull the example CSVs — no other network or Drive access).
 *   6. Refresh the spreadsheet tab in your browser — Config/Results/
 *      Settings/Resume tabs should now exist and be populated.
 *   7. If you left RESUME_JSON blank, edit the Resume tab with your own
 *      profile by hand. Edit the Config tab with the companies you actually
 *      want to track, and the Settings tab if you want different location/
 *      experience/match-threshold values than the Bengaluru/4yr defaults.
 *
 * If you forked this repo and changed examples/google-sheet/config_data.csv,
 * settings_template.csv, or resume_template.csv, update REPO_RAW_BASE below
 * to point at your fork (or your branch) before running.
 */

var REPO_RAW_BASE =
  'https://raw.githubusercontent.com/Jatin17Solanki/linkedin_automation/main/examples/google-sheet';

var RESULTS_HEADERS = [
  'JobID', 'Title', 'Company', 'Location', 'Link', 'ExperienceReq',
  'PrimaryTag', 'FirstSeen', 'Notified', 'Score', 'Status'
];

// Paste the JSON returned by the README's resume-conversion prompt here
// (e.g. RESUME_JSON = '{"name": "...", ...}') to auto-populate the Resume
// tab from your own resume instead of getting placeholder values. Leave as
// an empty string to skip this and use placeholders (matches pre-Phase-8
// behavior exactly).
var RESUME_JSON = '';

// Exact keys the workflow's Code nodes read by name — order here is the
// order they'll appear in the Resume tab. Keep in sync with CLAUDE.md's
// "Resume Tab" section and examples/google-sheet/resume_template.csv.
var RESUME_KEYS = [
  'name', 'title', 'years_experience', 'target_roles', 'skills_languages',
  'skills_frameworks', 'skills_databases', 'skills_cloud', 'skills_other',
  'experience_summary', 'education', 'highlights'
];

function bootstrap() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  var configSheet = getOrCreateSheet_(ss, 'Config', true);
  var resultsSheet = getOrCreateSheet_(ss, 'Results', false);
  var settingsSheet = getOrCreateSheet_(ss, 'Settings', false);
  var resumeSheet = getOrCreateSheet_(ss, 'Resume', false);

  populateFromCsv_(configSheet, fetchCsv_('config_data.csv'));
  resultsSheet.getRange(1, 1, 1, RESULTS_HEADERS.length).setValues([RESULTS_HEADERS]);
  populateFromCsv_(settingsSheet, fetchCsv_('settings_template.csv'));

  var resumeSource = 'placeholders';
  if (RESUME_JSON && RESUME_JSON.trim()) {
    populateResumeFromJson_(resumeSheet, RESUME_JSON);
    resumeSource = 'RESUME_JSON';
  } else {
    populateFromCsv_(resumeSheet, fetchCsv_('resume_template.csv'));
  }

  SpreadsheetApp.flush();
  Logger.log('Bootstrap complete: Config (%s rows), Results (headers only), Settings (%s rows), Resume (%s rows, from %s).',
    configSheet.getLastRow() - 1, settingsSheet.getLastRow() - 1, resumeSheet.getLastRow() - 1, resumeSource);
}

/**
 * Populates the Resume tab from a JSON string (the README prompt's output)
 * instead of the placeholder CSV. Writes a Key/Value header row, then exactly
 * RESUME_KEYS.length rows in RESUME_KEYS order regardless of what's in the
 * JSON, so the sheet's shape always matches what the workflow expects: known
 * keys get their parsed value, missing keys get an empty string, and any keys in the JSON that
 * aren't in RESUME_KEYS are logged and dropped rather than silently kept
 * (they'd just be inert extra data the workflow never reads).
 */
function populateResumeFromJson_(sheet, jsonString) {
  var parsed;
  try {
    parsed = JSON.parse(jsonString);
  } catch (e) {
    throw new Error('RESUME_JSON is not valid JSON: ' + e.message +
      '. Check you pasted the LLM\'s raw JSON output (and nothing else) between the quotes.');
  }

  var missing = [];
  var rows = RESUME_KEYS.map(function (key) {
    var hasValue = Object.prototype.hasOwnProperty.call(parsed, key) && parsed[key] !== null && parsed[key] !== undefined;
    if (!hasValue) missing.push(key);
    return [key, hasValue ? String(parsed[key]) : ''];
  });

  var extra = Object.keys(parsed).filter(function (k) { return RESUME_KEYS.indexOf(k) === -1; });

  if (missing.length) {
    Logger.log('RESUME_JSON is missing keys (left blank in the sheet, edit manually if needed): %s', missing.join(', '));
  }
  if (extra.length) {
    Logger.log('RESUME_JSON had unexpected keys (ignored, not written to the sheet): %s', extra.join(', '));
  }

  // Row 1 MUST be the literal Key/Value header: n8n's Google Sheets node treats
  // row 1 as column names, so writing data straight into row 1 makes the first
  // pair (`name` + your name) become the headers and every workflow read sees no
  // Key/Value columns -- `Prepare LLM Input` then reports resume_empty even though
  // every row is filled in. (The CSV path below gets this right because the
  // template CSVs already start with a Key,Value row.)
  var values = [['Key', 'Value']].concat(rows);
  sheet.getRange(1, 1, values.length, 2).setValues(values);
}

/**
 * Reuses the sheet named "Sheet1" for the first tab (default in a blank
 * spreadsheet) instead of leaving it dangling; creates the rest normally.
 */
function getOrCreateSheet_(ss, name, reuseSheet1) {
  var existing = ss.getSheetByName(name);
  if (existing) {
    existing.clear();
    return existing;
  }
  if (reuseSheet1) {
    var sheet1 = ss.getSheetByName('Sheet1');
    if (sheet1) {
      sheet1.setName(name);
      sheet1.clear();
      return sheet1;
    }
  }
  return ss.insertSheet(name);
}

function fetchCsv_(filename) {
  var url = REPO_RAW_BASE + '/' + filename;
  var response = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
  if (response.getResponseCode() !== 200) {
    throw new Error('Failed to fetch ' + url + ' (HTTP ' + response.getResponseCode() + ')');
  }
  return Utilities.parseCsv(response.getContentText());
}

function populateFromCsv_(sheet, rows) {
  if (rows.length === 0) return;
  var width = rows.reduce(function (max, row) { return Math.max(max, row.length); }, 0);
  var padded = rows.map(function (row) {
    var copy = row.slice();
    while (copy.length < width) copy.push('');
    return copy;
  });
  sheet.getRange(1, 1, padded.length, width).setValues(padded);
}
