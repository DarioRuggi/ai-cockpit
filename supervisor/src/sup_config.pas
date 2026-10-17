(* =============================================================================
  sup_config — the supervisor's configuration (one JSON file) and its validation.

  {
    "state_dir": "${CONFIG_DIR}/state",      "log_dir": "${STATE}/logs",
    "control": {"socket": "${STATE}/sup.sock", "mode": "600", "group": ""},
    "vars": {"ENGINE": "/opt/aicockpit/bin/aicengine"},               extra ${NAMES}
    "services": [
      {"name": "engine", "command": "${ENGINE}", "args": ["serve", "--socket", "${STATE}/engine.sock"],
       "cwd": "", "env": {}, "restart": "always|on-failure|never",
       "start_after": ["other"], "stop_timeout_s": 8,
       "backoff_min_s": 1, "backoff_max_s": 60, "stable_after_s": 30,
       "max_restarts": 5, "restart_window_s": 120,            more than that in the window = "failed", stays down
       "adopt_if_healthy": false, "log_max_kb": 1024, "enabled": true,
       "health": {"type": "none|tcp|unix|http|command", "host": "127.0.0.1", "port": 0, "socket": "", "url": "",
                  "command": "", "args": [], "interval_s": 5, "timeout_s": 2, "failures": 3, "start_grace_s": 10}}
    ],
    "jobs": [
      {"name": "scheduler", "schedule": "every 60s", "command": "php", "args": ["scheduler.php"],
       "timeout_s": 55, "overlap": "skip|kill", "persistent": false, "random_delay_s": 0,
       "run_at_start": false, "log_max_kb": 512, "enabled": true}
    ],
    "guard": {"enabled": false, "manifest": "", "roots": ["..."], "interval_s": 5, "log": "", "flag_file": "",
              "restore": "none|copy", "restore_from": ""}
  }
  ============================================================================= *)
unit sup_config;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, sup_util, sup_sched;

type
  THealthDef = class
    Kind: string;                // none | tcp | unix | http | command
    Host: string;
    Port: Integer;
    Sock: string;
    Url: string;
    Command: string;
    Args: TStringList;
    IntervalS, TimeoutS, Failures, StartGraceS: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TServiceDef = class
    Name, Command, Cwd, Restart: string;
    Args, Env, StartAfter: TStringList;
    StopTimeoutS, BackoffMinS, BackoffMaxS, StableAfterS, MaxRestarts, RestartWindowS, LogMaxKB: Integer;
    AdoptIfHealthy, Enabled: Boolean;
    Health: THealthDef;
    constructor Create;
    destructor Destroy; override;
    function SameAs(Other: TServiceDef): Boolean;     // would a reload need to restart it?
  end;

  TJobDef = class
    Name, Command, Cwd, ScheduleText, Overlap: string;
    Sched: TSchedule;
    Args, Env: TStringList;
    TimeoutS, RandomDelayS, LogMaxKB: Integer;
    Persistent, RunAtStart, Enabled: Boolean;
    constructor Create;
    destructor Destroy; override;
    function SameAs(Other: TJobDef): Boolean;
  end;

  TGuardDef = class                  // one watched tree: its files are listed with sha256 in a manifest
    Name: string;
    Enabled: Boolean;
    Root, Manifest, LogFile, FlagFile, Restore, RestoreFrom: string;
    IntervalS: Integer;
    constructor Create;
    destructor Destroy; override;
    function SameAs(Other: TGuardDef): Boolean;
  end;

  TSupConfig = class
  public
    ConfigFile, ConfigDir, StateDir, LogDir: string;
    CtlSocket, CtlGroup: string;
    CtlMode: Integer;
    Vars: TStringList;
    Services: TList;             // TServiceDef, in a valid START order (dependencies first)
    Jobs: TList;
    Guards: TList;                // TGuardDef
    constructor Create;
    destructor Destroy; override;
    function Svc(const Name: string): TServiceDef;
    function Job(const Name: string): TJobDef;
  end;

{ Load + validate.  On failure returns nil and Errors holds one problem per line. }
function LoadConfig(const FileName: string; out Errors: string): TSupConfig;

implementation

constructor THealthDef.Create;
begin
  Kind := 'none'; Host := '127.0.0.1'; IntervalS := 5; TimeoutS := 2; Failures := 3; StartGraceS := 10;
  Args := TStringList.Create;
end;

destructor THealthDef.Destroy;
begin
  Args.Free;
  inherited Destroy;
end;

constructor TServiceDef.Create;
begin
  Restart := 'on-failure'; StopTimeoutS := 8; BackoffMinS := 1; BackoffMaxS := 60; StableAfterS := 30;
  MaxRestarts := 5; RestartWindowS := 120; LogMaxKB := 1024; Enabled := True;
  Args := TStringList.Create; Env := TStringList.Create; StartAfter := TStringList.Create;
  Health := THealthDef.Create;
end;

destructor TServiceDef.Destroy;
begin
  Args.Free; Env.Free; StartAfter.Free; Health.Free;
  inherited Destroy;
end;

function TServiceDef.SameAs(Other: TServiceDef): Boolean;
begin
  Result := (Command = Other.Command) and (Cwd = Other.Cwd) and (Args.Text = Other.Args.Text) and (Env.Text = Other.Env.Text)
    and (Health.Kind = Other.Health.Kind) and (Health.Port = Other.Health.Port) and (Health.Sock = Other.Health.Sock)
    and (Health.Url = Other.Health.Url) and (Health.Command = Other.Health.Command) and (Enabled = Other.Enabled)
    and (AdoptIfHealthy = Other.AdoptIfHealthy);
end;

constructor TJobDef.Create;
begin
  Overlap := 'skip'; TimeoutS := 300; LogMaxKB := 512; Enabled := True;
  Args := TStringList.Create; Env := TStringList.Create;
end;

destructor TJobDef.Destroy;
begin
  Args.Free; Env.Free;
  inherited Destroy;
end;

function TJobDef.SameAs(Other: TJobDef): Boolean;
begin
  Result := (Command = Other.Command) and (Cwd = Other.Cwd) and (Args.Text = Other.Args.Text) and (Env.Text = Other.Env.Text)
    and (ScheduleText = Other.ScheduleText) and (TimeoutS = Other.TimeoutS) and (Overlap = Other.Overlap) and (Enabled = Other.Enabled)
    and (Persistent = Other.Persistent) and (RunAtStart = Other.RunAtStart) and (RandomDelayS = Other.RandomDelayS);
end;

constructor TGuardDef.Create;
begin
  IntervalS := 5; Restore := 'none'; Enabled := True;
end;

destructor TGuardDef.Destroy;
begin
  inherited Destroy;
end;

function TGuardDef.SameAs(Other: TGuardDef): Boolean;
begin
  Result := (Enabled = Other.Enabled) and (Manifest = Other.Manifest) and (Root = Other.Root) and (IntervalS = Other.IntervalS)
    and (Restore = Other.Restore) and (RestoreFrom = Other.RestoreFrom) and (LogFile = Other.LogFile) and (FlagFile = Other.FlagFile);
end;

constructor TSupConfig.Create;
begin
  Vars := TStringList.Create;
  Services := TList.Create;
  Jobs := TList.Create;
  Guards := TList.Create;
  CtlMode := &600;
end;

destructor TSupConfig.Destroy;
var
  i: Integer;
begin
  for i := 0 to Services.Count - 1 do TServiceDef(Services[i]).Free;
  for i := 0 to Jobs.Count - 1 do TJobDef(Jobs[i]).Free;
  for i := 0 to Guards.Count - 1 do TGuardDef(Guards[i]).Free;
  Services.Free; Jobs.Free; Guards.Free; Vars.Free;
  inherited Destroy;
end;

function TSupConfig.Svc(const Name: string): TServiceDef;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to Services.Count - 1 do if TServiceDef(Services[i]).Name = Name then Exit(TServiceDef(Services[i]));
end;

function TSupConfig.Job(const Name: string): TJobDef;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to Jobs.Count - 1 do if TJobDef(Jobs[i]).Name = Name then Exit(TJobDef(Jobs[i]));
end;

{ ---- reading helpers ---------------------------------------------------------------------------- }

procedure ReadStrList(O: TJSONObject; const Key: string; Dest: TStringList; Vars: TStringList);
var
  a: TJSONData;
  i: Integer;
begin
  a := O.Find(Key);
  if (a <> nil) and (a.JSONType = jtArray) then
    for i := 0 to TJSONArray(a).Count - 1 do Dest.Add(ExpandVars(TJSONArray(a)[i].AsString, Vars));
end;

procedure ReadEnv(O: TJSONObject; Dest: TStringList; Vars: TStringList);
var
  e: TJSONData;
  i: Integer;
begin
  e := O.Find('env');
  if (e <> nil) and (e.JSONType = jtObject) then
    for i := 0 to TJSONObject(e).Count - 1 do
      Dest.Add(TJSONObject(e).Names[i] + '=' + ExpandVars(TJSONObject(e).Items[i].AsString, Vars));
end;

function Str(O: TJSONObject; const K, Def: string; Vars: TStringList): string;
begin
  Result := ExpandVars(O.Get(K, Def), Vars);
end;

{ Order services so each comes after everything it starts_after; report cycles / unknown names. }
function TopoSort(Cfg: TSupConfig; var Errors: string): Boolean;
var
  sorted, pending: TList;
  i, j, k: Integer;
  d: TServiceDef;
  ready, progressed: Boolean;
  found: Boolean;
begin
  Result := True;
  sorted := TList.Create;
  pending := TList.Create;
  try
    for i := 0 to Cfg.Services.Count - 1 do
    begin
      d := TServiceDef(Cfg.Services[i]);
      for j := 0 to d.StartAfter.Count - 1 do
        if Cfg.Svc(d.StartAfter[j]) = nil then
        begin
          Errors := Errors + 'service "' + d.Name + '" starts after unknown service "' + d.StartAfter[j] + '"' + #10;
          Result := False;
        end;
      pending.Add(d);
    end;
    if not Result then Exit;
    repeat
      progressed := False;
      for i := pending.Count - 1 downto 0 do
      begin
        d := TServiceDef(pending[i]);
        ready := True;
        for j := 0 to d.StartAfter.Count - 1 do
        begin
          found := False;
          for k := 0 to sorted.Count - 1 do if TServiceDef(sorted[k]).Name = d.StartAfter[j] then found := True;
          if not found then ready := False;
        end;
        if ready then begin sorted.Add(d); pending.Delete(i); progressed := True; end;
      end;
    until (pending.Count = 0) or not progressed;
    if pending.Count > 0 then
    begin
      Errors := Errors + 'start_after forms a cycle involving:';
      for i := 0 to pending.Count - 1 do Errors := Errors + ' ' + TServiceDef(pending[i]).Name;
      Errors := Errors + #10;
      Exit(False);
    end;
    Cfg.Services.Clear;
    for i := 0 to sorted.Count - 1 do Cfg.Services.Add(sorted[i]);
  finally
    sorted.Free; pending.Free;
  end;
end;

function LoadConfig(const FileName: string; out Errors: string): TSupConfig;
var
  doc: TJSONData;
  root, o, h, ctl, vv, gd: TJSONObject;
  gdef: TGuardDef;
  a: TJSONData;
  i, j: Integer;
  cfg: TSupConfig;
  sd: TServiceDef;
  jd: TJobDef;
  sch: TSchedule;
  err, s: string;
  names: TStringList;
begin
  Result := nil;
  Errors := '';
  if not FileExists(FileName) then begin Errors := 'config file not found: ' + FileName; Exit; end;
  try
    doc := GetJSON(ReadFileString(FileName));
  except
    on E: Exception do begin Errors := 'config is not valid JSON: ' + E.Message; Exit; end;
  end;
  if doc.JSONType <> jtObject then begin doc.Free; Errors := 'config must be a JSON object'; Exit; end;
  root := TJSONObject(doc);
  cfg := TSupConfig.Create;
  names := TStringList.Create;
  try
    cfg.ConfigFile := ExpandFileName(FileName);
    cfg.ConfigDir := ExtractFileDir(cfg.ConfigFile);
    cfg.Vars.Values['CONFIG_DIR'] := cfg.ConfigDir;
    cfg.Vars.Values['HOME'] := GetEnvironmentVariable('HOME');
    vv := root.Get('vars', TJSONObject(nil));
    if vv <> nil then
      for i := 0 to vv.Count - 1 do cfg.Vars.Values[vv.Names[i]] := ExpandVars(vv.Items[i].AsString, cfg.Vars);
    cfg.StateDir := ExpandVars(root.Get('state_dir', '${CONFIG_DIR}/state'), cfg.Vars);
    cfg.Vars.Values['STATE'] := cfg.StateDir;
    cfg.LogDir := ExpandVars(root.Get('log_dir', '${STATE}/logs'), cfg.Vars);
    cfg.Vars.Values['LOG'] := cfg.LogDir;
    ctl := root.Get('control', TJSONObject(nil));
    cfg.CtlSocket := '${STATE}/sup.sock'; cfg.CtlGroup := '';
    if ctl <> nil then
    begin
      cfg.CtlSocket := ctl.Get('socket', cfg.CtlSocket);
      cfg.CtlGroup := ctl.Get('group', '');
      cfg.CtlMode := StrToIntDef('&' + ctl.Get('mode', '600'), &600);
    end;
    cfg.CtlSocket := ExpandVars(cfg.CtlSocket, cfg.Vars);

    // ---- services ----
    a := root.Find('services');
    if (a <> nil) and (a.JSONType = jtArray) then
      for i := 0 to TJSONArray(a).Count - 1 do
      begin
        o := TJSONObject(TJSONArray(a)[i]);
        sd := TServiceDef.Create;
        sd.Name := o.Get('name', '');
        sd.Command := Str(o, 'command', '', cfg.Vars);
        sd.Cwd := Str(o, 'cwd', '', cfg.Vars);
        sd.Restart := o.Get('restart', 'on-failure');
        ReadStrList(o, 'args', sd.Args, cfg.Vars);
        ReadStrList(o, 'start_after', sd.StartAfter, nil);
        ReadEnv(o, sd.Env, cfg.Vars);
        sd.StopTimeoutS := o.Get('stop_timeout_s', 8);
        sd.BackoffMinS := o.Get('backoff_min_s', 1);
        sd.BackoffMaxS := o.Get('backoff_max_s', 60);
        sd.StableAfterS := o.Get('stable_after_s', 30);
        sd.MaxRestarts := o.Get('max_restarts', 5);
        sd.RestartWindowS := o.Get('restart_window_s', 120);
        sd.LogMaxKB := o.Get('log_max_kb', 1024);
        sd.AdoptIfHealthy := o.Get('adopt_if_healthy', False);
        sd.Enabled := o.Get('enabled', True);
        h := o.Get('health', TJSONObject(nil));
        if h <> nil then
        begin
          sd.Health.Kind := h.Get('type', 'none');
          sd.Health.Host := Str(h, 'host', '127.0.0.1', cfg.Vars);
          sd.Health.Port := h.Get('port', 0);
          sd.Health.Sock := Str(h, 'socket', '', cfg.Vars);
          sd.Health.Url := Str(h, 'url', '', cfg.Vars);
          sd.Health.Command := Str(h, 'command', '', cfg.Vars);
          ReadStrList(h, 'args', sd.Health.Args, cfg.Vars);
          sd.Health.IntervalS := h.Get('interval_s', 5);
          sd.Health.TimeoutS := h.Get('timeout_s', 2);
          sd.Health.Failures := h.Get('failures', 3);
          sd.Health.StartGraceS := h.Get('start_grace_s', 10);
        end;
        // validation
        if sd.Name = '' then Errors := Errors + 'service #' + IntToStr(i + 1) + ' has no name' + #10
        else if names.IndexOf('s:' + sd.Name) >= 0 then Errors := Errors + 'duplicate service name "' + sd.Name + '"' + #10;
        names.Add('s:' + sd.Name);
        if sd.Command = '' then Errors := Errors + 'service "' + sd.Name + '" has no command' + #10;
        if (sd.Restart <> 'always') and (sd.Restart <> 'on-failure') and (sd.Restart <> 'never') then
          Errors := Errors + 'service "' + sd.Name + '": restart must be always, on-failure or never' + #10;
        if Pos(sd.Health.Kind, '|none|tcp|unix|http|command|') = 0 then Errors := Errors + 'service "' + sd.Name + '": unknown health type "' + sd.Health.Kind + '"' + #10;
        if (sd.Health.Kind = 'tcp') and (sd.Health.Port <= 0) then Errors := Errors + 'service "' + sd.Name + '": tcp health needs a port' + #10;
        if (sd.Health.Kind = 'unix') and (sd.Health.Sock = '') then Errors := Errors + 'service "' + sd.Name + '": unix health needs a socket' + #10;
        if (sd.Health.Kind = 'http') and (sd.Health.Url = '') then Errors := Errors + 'service "' + sd.Name + '": http health needs a url' + #10;
        if (sd.Health.Kind = 'command') and (sd.Health.Command = '') then Errors := Errors + 'service "' + sd.Name + '": command health needs a command' + #10;
        if sd.AdoptIfHealthy and (sd.Health.Kind = 'none') then Errors := Errors + 'service "' + sd.Name + '": adopt_if_healthy needs a health check' + #10;
        cfg.Services.Add(sd);
      end;

    // ---- jobs ----
    a := root.Find('jobs');
    if (a <> nil) and (a.JSONType = jtArray) then
      for i := 0 to TJSONArray(a).Count - 1 do
      begin
        o := TJSONObject(TJSONArray(a)[i]);
        jd := TJobDef.Create;
        jd.Name := o.Get('name', '');
        jd.Command := Str(o, 'command', '', cfg.Vars);
        jd.Cwd := Str(o, 'cwd', '', cfg.Vars);
        jd.ScheduleText := o.Get('schedule', '');
        jd.Overlap := o.Get('overlap', 'skip');
        ReadStrList(o, 'args', jd.Args, cfg.Vars);
        ReadEnv(o, jd.Env, cfg.Vars);
        jd.TimeoutS := o.Get('timeout_s', 300);
        jd.RandomDelayS := o.Get('random_delay_s', 0);
        jd.LogMaxKB := o.Get('log_max_kb', 512);
        jd.Persistent := o.Get('persistent', False);
        jd.RunAtStart := o.Get('run_at_start', False);
        jd.Enabled := o.Get('enabled', True);
        if jd.Name = '' then Errors := Errors + 'job #' + IntToStr(i + 1) + ' has no name' + #10
        else if names.IndexOf('j:' + jd.Name) >= 0 then Errors := Errors + 'duplicate job name "' + jd.Name + '"' + #10;
        names.Add('j:' + jd.Name);
        if jd.Command = '' then Errors := Errors + 'job "' + jd.Name + '" has no command' + #10;
        if not ParseSchedule(jd.ScheduleText, sch, err) then Errors := Errors + 'job "' + jd.Name + '": ' + err + #10
        else jd.Sched := sch;
        if (jd.Overlap <> 'skip') and (jd.Overlap <> 'kill') then Errors := Errors + 'job "' + jd.Name + '": overlap must be skip or kill' + #10;
        if jd.TimeoutS < 1 then Errors := Errors + 'job "' + jd.Name + '": timeout_s must be at least 1' + #10;
        cfg.Jobs.Add(jd);
      end;

    // ---- guards (one per watched tree) ----
    a := root.Find('guards');
    if (a <> nil) and (a.JSONType = jtArray) then
      for i := 0 to TJSONArray(a).Count - 1 do
      begin
        gd := TJSONObject(TJSONArray(a)[i]);
        gdef := TGuardDef.Create;
        gdef.Name := gd.Get('name', 'guard' + IntToStr(i + 1));
        gdef.Enabled := gd.Get('enabled', True);
        gdef.Root := Str(gd, 'root', '', cfg.Vars);
        gdef.Manifest := Str(gd, 'manifest', '', cfg.Vars);
        gdef.IntervalS := gd.Get('interval_s', 5);
        gdef.LogFile := Str(gd, 'log', '${LOG}/guard.log', cfg.Vars);
        gdef.FlagFile := Str(gd, 'flag_file', '${STATE}/integrity_flag.json', cfg.Vars);
        gdef.Restore := gd.Get('restore', 'none');
        gdef.RestoreFrom := Str(gd, 'restore_from', '', cfg.Vars);
        if gdef.Enabled then
        begin
          if gdef.Root = '' then Errors := Errors + 'guard "' + gdef.Name + '" needs a root' + #10;
          if gdef.Manifest = '' then Errors := Errors + 'guard "' + gdef.Name + '" needs a manifest' + #10;
          if (gdef.Restore <> 'none') and (gdef.Restore <> 'copy') then Errors := Errors + 'guard "' + gdef.Name + '": restore must be none or copy' + #10;
          if (gdef.Restore = 'copy') and (gdef.RestoreFrom = '') then Errors := Errors + 'guard "' + gdef.Name + '": restore=copy needs restore_from' + #10;
          if gdef.IntervalS < 1 then Errors := Errors + 'guard "' + gdef.Name + '": interval_s must be at least 1' + #10;
        end;
        cfg.Guards.Add(gdef);
      end;
    if Errors = '' then TopoSort(cfg, Errors);
    if Errors <> '' then begin cfg.Free; cfg := nil; Exit; end;       // nil: the finally block below frees cfg too
    Result := cfg;
    cfg := nil;
  finally
    names.Free;
    cfg.Free;
    root.Free;
  end;
end;

end.
