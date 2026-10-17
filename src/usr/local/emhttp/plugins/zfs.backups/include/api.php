<?php
/*
 * ZFS Backups - WebGUI backend.
 * Called by the plugin pages with POST {action, csrf_token, ...}. Unraid's
 * local_prepend.php rejects POSTs without a valid csrf_token before we get here.
 */
$plugin  = 'zfs.backups';
$cfg_dir = getenv('ZFSB_CFG_DIR') ?: "/boot/config/plugins/$plugin";
$jobs_dir = "$cfg_dir/jobs";
$state_dir = getenv('ZFSB_STATE_DIR') ?: "/var/local/$plugin";
$log_dir = getenv('ZFSB_LOG_DIR') ?: "/var/log/$plugin";
$zfsb = getenv('ZFSB_BIN') ?: '/usr/local/sbin/zfsb';

header('Content-Type: application/json');

function reply($data, $code = 200) { http_response_code($code); echo json_encode($data); exit; }
function fail($msg, $code = 400)   { reply(['ok' => false, 'error' => $msg], $code); }

// ---------------------------------------------------------------- validation
const RE_DATASET = '/^[A-Za-z0-9][A-Za-z0-9_.:\/-]*$/';
const RE_CRON    = '/^[0-9*\/,-]+(\s+[0-9*\/,-]+){4}$/';

// field => [regex or list of allowed values, default]
$JOB_FIELDS = [
  'NAME'            => ['/^[A-Za-z0-9][A-Za-z0-9 _.()-]{0,47}$/', ''],
  'ENABLED'         => [['yes', 'no'], 'yes'],
  'DATASETS'        => ['datasets', ''],
  'RECURSIVE'       => [['yes', 'zfs', 'no'], 'yes'],
  'EXCLUDE'         => ['datasets', ''],
  'HOURLY'          => ['/^\d{1,4}$/', '0'],
  'DAILY'           => ['/^\d{1,4}$/', '7'],
  'WEEKLY'          => ['/^\d{1,4}$/', '0'],
  'MONTHLY'         => ['/^\d{1,4}$/', '0'],
  'YEARLY'          => ['/^\d{1,4}$/', '0'],
  'SCHEDULE'        => [['disabled', 'hourly', 'daily', 'weekly', 'custom'], 'daily'],
  'SCHEDULE_TIME'   => ['/^([01]\d|2[0-3]):[0-5]\d$/', '00:30'],
  'SCHEDULE_DOW'    => ['/^[0-6]$/', '0'],
  'SCHEDULE_CRON'   => ['cron', ''],
  'WAKE_DISKS'      => [['yes', 'no'], 'yes'],
  'NOTIFY'          => [['all', 'error', 'none'], 'all'],
  'REPL_METHOD'     => [['none', 'zfs', 'rsync'], 'none'],
  'REPL_TARGET'     => ['/^[A-Za-z0-9\/][A-Za-z0-9_.:\/-]*$/', ''],
  'REPL_HOST'       => ['/^[A-Za-z0-9][A-Za-z0-9.-]*$/', ''],
  'REPL_USER'       => ['/^[a-z_][a-z0-9_-]{0,31}$/', 'root'],
  'REPL_PORT'       => ['/^\d{1,5}$/', '22'],
  'REPL_SSH_KEY'    => ['/^\/[A-Za-z0-9_.\/-]+$/', ''],
  'REPL_ZFS_MODE'   => [['strict-mirror', 'basic'], 'strict-mirror'],
  'REPL_RSYNC_MODE' => [['incremental', 'mirror'], 'incremental'],
  'REPL_RSYNC_KEEP' => ['/^\d{1,4}$/', '14'],
];

$CONVERT_FIELDS = [
  'ENABLED'         => [['yes', 'no'], 'no'],
  'PARENTS'         => ['datasets', ''],
  'MODE'            => [['before_jobs', 'schedule', 'manual'], 'before_jobs'],
  'STOP_CONTAINERS' => [['yes', 'no'], 'yes'],
  'STOP_VMS'        => [['yes', 'no'], 'no'],
  'VM_WAIT'         => ['/^\d{1,4}$/', '90'],
  'REPLACE_SPACES'  => [['yes', 'no'], 'no'],
  'DRY_RUN'         => [['yes', 'no'], 'no'],
  'NOTIFY'          => [['all', 'error', 'none'], 'all'],
  'SCHEDULE'        => [['disabled', 'hourly', 'daily', 'weekly', 'custom'], 'daily'],
  'SCHEDULE_TIME'   => ['/^([01]\d|2[0-3]):[0-5]\d$/', '00:15'],
  'SCHEDULE_DOW'    => ['/^[0-6]$/', '0'],
  'SCHEDULE_CRON'   => ['cron', ''],
];

/** Validate posted values against a field spec. Returns [clean, errors]. */
function clean_fields(array $spec, array $in) {
  $out = []; $errors = [];
  foreach ($spec as $key => [$rule, $default]) {
    $v = isset($in[$key]) ? trim((string)$in[$key]) : $default;
    if ($rule === 'datasets') {
      $list = preg_split('/[\s,]+/', $v, -1, PREG_SPLIT_NO_EMPTY);
      foreach ($list as $d) {
        if (!preg_match(RE_DATASET, $d) || str_contains($d, '//') || str_ends_with($d, '/'))
          $errors[] = "$key: '$d' is not a valid dataset name (no spaces or special characters)";
      }
      $v = implode(' ', array_unique($list));
    } elseif ($rule === 'cron') {
      $v = preg_replace('/\s+/', ' ', $v);
      if ($v !== '' && !preg_match(RE_CRON, $v)) $errors[] = "$key: not a valid 5-field cron expression";
    } elseif (is_array($rule)) {
      if (!in_array($v, $rule, true)) $errors[] = "$key: must be one of ".implode(', ', $rule);
    } elseif ($v !== '' && !preg_match($rule, $v)) {
      $errors[] = "$key: invalid value";
    }
    $out[$key] = $v;
  }
  return [$out, $errors];
}

function read_cfg($file) {
  if (!is_file($file)) return [];
  $out = [];
  foreach (file($file, FILE_IGNORE_NEW_LINES) as $line) {
    if (preg_match('/^\s*([A-Z][A-Z0-9_]*)="?(.*?)"?\s*$/', $line, $m)) $out[$m[1]] = $m[2];
  }
  return $out;
}

function write_cfg($file, array $values) {
  $body = '';
  foreach ($values as $k => $v) $body .= "$k=\"$v\"\n";   // values are whitelisted: never contain quotes or newlines
  @mkdir(dirname($file), 0755, true);
  $tmp = "$file.tmp";
  if (file_put_contents($tmp, $body) === false || !rename($tmp, $file)) fail("could not write $file", 500);
}

function zfsb(array $args, &$rc = null) {
  global $zfsb;
  $cmd = escapeshellarg($zfsb).' '.implode(' ', array_map('escapeshellarg', $args)).' 2>&1';
  exec($cmd, $out, $rc);
  return implode("\n", $out);
}

function zfsb_background(array $args) {
  global $zfsb;
  $cmd = 'setsid '.escapeshellarg($zfsb).' '.implode(' ', array_map('escapeshellarg', $args)).' >/dev/null 2>&1 &';
  exec($cmd);
}

function valid_id($id) { return is_string($id) && preg_match('/^[a-z0-9][a-z0-9_-]{0,47}$/', $id); }

function job_ids() {
  global $jobs_dir;
  $ids = array_map(fn($f) => basename($f, '.cfg'), glob("$jobs_dir/*.cfg") ?: []);
  sort($ids);
  return $ids;
}

function job_status($id) {
  global $state_dir, $cfg_dir;
  foreach (["$state_dir/status/$id.json", "$cfg_dir/status/$id.json"] as $f) {
    if (is_file($f)) return json_decode(file_get_contents($f), true);
  }
  return null;
}

function running_jobs() {
  exec("pgrep -af 'zfsb (run|run-all|convert)( |$)'", $lines);
  $running = [];
  foreach ($lines as $l) {
    if (preg_match('/zfsb run ([a-z0-9_-]+)/', $l, $m)) $running[] = $m[1];
    if (preg_match('/zfsb convert/', $l)) $running[] = '_convert';
  }
  return array_values(array_unique($running));
}

// ---------------------------------------------------------------- actions
$action = $_POST['action'] ?? '';

switch ($action) {

  case 'datasets':
    exec('zfs list -H -p -o name,used,mountpoint -t filesystem,volume 2>/dev/null', $lines);
    $ds = [];
    foreach ($lines as $l) {
      [$name, $used, $mp] = array_pad(explode("\t", $l), 3, '');
      $ds[] = ['name' => $name, 'used' => (int)$used, 'mountpoint' => $mp, 'valid' => (bool)preg_match(RE_DATASET, $name)];
    }
    reply(['ok' => true, 'datasets' => $ds]);

  case 'jobs':
    $running = running_jobs();
    $jobs = [];
    foreach (job_ids() as $id) {
      $cfg = read_cfg("$jobs_dir/$id.cfg");
      $jobs[] = ['id' => $id, 'cfg' => $cfg, 'status' => job_status($id), 'running' => in_array($id, $running, true)];
    }
    reply(['ok' => true, 'jobs' => $jobs, 'convert_running' => in_array('_convert', $running, true)]);

  case 'save_job':
    [$cfg, $errors] = clean_fields($JOB_FIELDS, $_POST['cfg'] ?? []);
    if ($cfg['NAME'] === '') $errors[] = 'NAME: give the job a name';
    if ($cfg['DATASETS'] === '') $errors[] = 'DATASETS: pick at least one dataset';
    if ($cfg['SCHEDULE'] === 'custom' && $cfg['SCHEDULE_CRON'] === '') $errors[] = 'SCHEDULE_CRON: enter a cron expression';
    if ($cfg['REPL_METHOD'] !== 'none' && $cfg['REPL_TARGET'] === '') $errors[] = 'REPL_TARGET: choose where to replicate to';
    $id = $_POST['id'] ?? '';
    if ($id === '') {   // new job: derive an id from the name
      $base = trim(preg_replace('/[^a-z0-9]+/', '-', strtolower($cfg['NAME'])), '-') ?: 'job';
      $base = substr($base, 0, 40); $id = $base; $n = 2;
      while (is_file("$jobs_dir/$id.cfg")) $id = "$base-".$n++;
    }
    if (!valid_id($id)) $errors[] = 'invalid job id';
    if ($errors) reply(['ok' => false, 'errors' => $errors]);
    write_cfg("$jobs_dir/$id.cfg", $cfg);
    zfsb(['cron']);
    $check = zfsb(['validate'], $rc);
    reply(['ok' => true, 'id' => $id, 'validate' => $check]);

  case 'delete_job':
    $id = $_POST['id'] ?? '';
    if (!valid_id($id) || !is_file("$jobs_dir/$id.cfg")) fail('unknown job');
    unlink("$jobs_dir/$id.cfg");
    @unlink("$cfg_dir/status/$id.json"); @unlink("$state_dir/status/$id.json");
    zfsb(['cron']);
    reply(['ok' => true]);

  case 'run_job':
    $id = $_POST['id'] ?? '';
    if (!valid_id($id) || !is_file("$jobs_dir/$id.cfg")) fail('unknown job');
    $args = ['run', $id];
    if (($_POST['dry'] ?? '') === 'yes') $args[] = '--dry-run';
    zfsb_background($args);
    reply(['ok' => true]);

  case 'plan_job':
    $id = $_POST['id'] ?? '';
    if (!valid_id($id) || !is_file("$jobs_dir/$id.cfg")) fail('unknown job');
    reply(['ok' => true, 'text' => zfsb(['plan', $id])]);

  case 'conflicts':
    reply(['ok' => true, 'text' => zfsb(['conflicts'])]);

  case 'get_convert':
    reply(['ok' => true, 'cfg' => read_cfg("$cfg_dir/convert.cfg") + array_map(fn($f) => $f[1], $CONVERT_FIELDS)]);

  case 'save_convert':
    [$cfg, $errors] = clean_fields($CONVERT_FIELDS, $_POST['cfg'] ?? []);
    if ($cfg['ENABLED'] === 'yes' && $cfg['PARENTS'] === '') $errors[] = 'PARENTS: pick at least one dataset to watch';
    if ($errors) reply(['ok' => false, 'errors' => $errors]);
    write_cfg("$cfg_dir/convert.cfg", $cfg);
    zfsb(['cron']);
    reply(['ok' => true]);

  case 'run_convert':
    $args = ['convert'];
    if (($_POST['dry'] ?? '') === 'yes') $args[] = '--dry-run';
    zfsb_background($args);
    reply(['ok' => true]);

  case 'log':
    $name = $_POST['name'] ?? '';
    if ($name !== '_convert' && !valid_id($name)) fail('unknown log');
    $file = "$log_dir/$name.log";
    $lines = max(50, min(5000, (int)($_POST['lines'] ?? 400)));
    $text = is_file($file) ? shell_exec('tail -n '.(int)$lines.' '.escapeshellarg($file)) : '';
    reply(['ok' => true, 'text' => $text ?? '', 'running' => in_array($name, running_jobs(), true)]);

  case 'logs':
    $names = array_map(fn($f) => basename($f, '.log'), glob("$log_dir/*.log") ?: []);
    reply(['ok' => true, 'logs' => $names]);

  default:
    fail('unknown action');
}
