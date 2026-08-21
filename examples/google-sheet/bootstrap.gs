/**
 * Bootstrap script for the LinkedIn Job Search automation's Google Sheet.
 *
 * What it does: creates the Config, Results, and Resume tabs (renaming/reusing
 * the default "Sheet1" for the first one) with the correct headers, then
 * populates Config with the example company list and Resume with placeholder
 * values you're expected to edit afterward. Results is left with headers only
 * — the workflow writes rows there at runtime.
 *
 * How to use:
 *   1. Create a new blank Google Sheet.
 *   2. Extensions -> Apps Script.
 *   3. Delete the placeholder code, paste this whole file in, save.
 *   4. Run the `bootstrap` function once (Run menu, or the ▶ button).
 *      First run will prompt for authorization (this script only touches
 *      the sheet it's bound to, plus a public raw.githubusercontent.com
 *      fetch to pull the example CSVs — no other network or Drive access).
 *   5. Refresh the spreadsheet tab in your browser — Config/Results/Resume
 *      tabs should now exist and be populated.
 *   6. Edit the Resume tab with your own profile, and the Config tab with
 *      the companies you actually want to track.
 *
 * If you forked this repo and changed examples/google-sheet/config_data.csv
 * or resume_template.csv, update REPO_RAW_BASE below to point at your fork
 * (or your branch) before running.
 */

var REPO_RAW_BASE =
  'https://raw.githubusercontent.com/Jatin17Solanki/linkedin_automation/main/examples/google-sheet';

var RESULTS_HEADERS = [
  'JobID', 'Title', 'Company', 'Location', 'Link', 'ExperienceReq',
  'PrimaryTag', 'FirstSeen', 'Notified', 'Score', 'Status'
];

function bootstrap() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  var configSheet = getOrCreateSheet_(ss, 'Config', true);
  var resultsSheet = getOrCreateSheet_(ss, 'Results', false);
  var resumeSheet = getOrCreateSheet_(ss, 'Resume', false);

  populateFromCsv_(configSheet, fetchCsv_('config_data.csv'));
  resultsSheet.getRange(1, 1, 1, RESULTS_HEADERS.length).setValues([RESULTS_HEADERS]);
  populateFromCsv_(resumeSheet, fetchCsv_('resume_template.csv'));

  SpreadsheetApp.flush();
  Logger.log('Bootstrap complete: Config (%s rows), Results (headers only), Resume (%s rows).',
    configSheet.getLastRow() - 1, resumeSheet.getLastRow() - 1);
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
