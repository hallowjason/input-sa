/**
 * input-sa 道場共編詞庫 API
 *
 * doGet  → 回傳 status=approved 的詞條 JSON（App 啟動同步用）
 * doPost → {action:"submit", entry:{correct,wrong,tier,phonetic,note}, submitter}
 *          寫入一列 status=pending，待管理者在 Sheet 上審核改 approved
 *
 * 注意：Web App 執行環境下 SpreadsheetApp.openById 會失敗，
 * 必須用 Sheets 進階服務（appsscript.json 已宣告 Sheets v4）。
 */

var SPREADSHEET_ID = '1XHEQahuFD5lWM87JQIZGMYNsTdSWtICHFe814SlwMbI';
var SHEET_NAME = 'vocab';
var MAX_TERM_LEN = 30;   // correct / wrong 單欄上限
var MAX_NOTE_LEN = 100;
var MAX_SUBMITTER_LEN = 20;
var DAILY_SUBMIT_CAP = 200; // GAS 拿不到客戶端 IP，用全域每日上限粗略防灌水

function doGet() {
  var resp = Sheets.Spreadsheets.Values.get(SPREADSHEET_ID, SHEET_NAME + '!A2:H');
  var rows = (resp && resp.values) || [];
  var entries = [];
  var version = '';
  rows.forEach(function (r) {
    var correct = (r[0] || '').toString().trim();
    var status = (r[7] || '').toString().trim();
    if (!correct || status !== 'approved') return;
    entries.push({
      correct: correct,
      wrong: (r[1] || '').toString().trim(),
      tier: r[2] === 'dojoOnly' ? 'dojoOnly' : 'always',
      phonetic: String(r[3]).toUpperCase() !== 'FALSE',
    });
    var ts = (r[6] || '').toString();
    if (ts > version) version = ts;
  });
  return jsonOut({ status: 'ok', version: version, count: entries.length, entries: entries });
}

function doPost(e) {
  var payload;
  try {
    payload = JSON.parse(e.postData.contents);
  } catch (err) {
    return jsonOut({ status: 'error', message: 'invalid JSON' });
  }
  if (payload.action !== 'submit') {
    return jsonOut({ status: 'error', message: 'unknown action' });
  }

  var entry = payload.entry || {};
  var correct = String(entry.correct || '').trim();
  var wrong = String(entry.wrong || '').trim();
  if (!correct) return jsonOut({ status: 'error', message: 'correct required' });
  if (correct.length > MAX_TERM_LEN || wrong.length > MAX_TERM_LEN) {
    return jsonOut({ status: 'error', message: 'term too long' });
  }
  var tier = entry.tier === 'dojoOnly' ? 'dojoOnly' : 'always';
  var phonetic = entry.phonetic === false ? 'FALSE' : 'TRUE';
  var note = String(entry.note || '').slice(0, MAX_NOTE_LEN);
  var submitter = String(payload.submitter || '').slice(0, MAX_SUBMITTER_LEN);

  var props = PropertiesService.getScriptProperties();
  var today = Utilities.formatDate(new Date(), 'Asia/Taipei', 'yyyy-MM-dd');
  var capKey = 'submits_' + today;
  var count = Number(props.getProperty(capKey) || 0);
  if (count >= DAILY_SUBMIT_CAP) {
    return jsonOut({ status: 'error', message: 'daily limit reached' });
  }

  // 同一 correct+wrong 已存在（不論審核狀態）就不重複收
  var existing = Sheets.Spreadsheets.Values.get(SPREADSHEET_ID, SHEET_NAME + '!A2:B');
  var dup = ((existing && existing.values) || []).some(function (r) {
    return (r[0] || '') === correct && (r[1] || '') === wrong;
  });
  if (dup) return jsonOut({ status: 'duplicate' });

  props.setProperty(capKey, String(count + 1));
  Sheets.Spreadsheets.Values.append(
    { values: [[correct, wrong, tier, phonetic, note, submitter, new Date().toISOString(), 'pending']] },
    SPREADSHEET_ID,
    SHEET_NAME + '!A:H',
    { valueInputOption: 'RAW' }
  );
  return jsonOut({ status: 'ok' });
}

function jsonOut(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(
    ContentService.MimeType.JSON
  );
}
