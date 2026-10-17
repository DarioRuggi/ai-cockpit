(* =============================================================================
  sup_core — the supervisor: services, jobs, guard and the control socket, in ONE single-threaded loop.

  SERVICES   started in dependency order; "running" means the process lives AND (when a health check is
             configured) it answered; a crash restarts it after an exponential backoff (1s,2s,4s ... capped),
             the backoff resets once it has stayed up stable_after_s; more than max_restarts crashes inside
             restart_window_s = state "failed": it stays down until someone says start (a crash loop must
             not burn the CPU forever).  Stop = SIGTERM to the whole process group, SIGKILL after
             stop_timeout_s.  A health check that fails `failures` times in a row restarts the service.
             adopt_if_healthy: a service that is already up (the system's own Ollama, say) is left alone and
             never killed at shutdown.
  JOBS       interval or calendar schedules; overlap=skip (default) or kill; a timeout kills the whole tree;
             persistent jobs run once when a slot was missed while the supervisor was down.
  GUARD      see sup_guard.
  CONTROL    a Unix socket, JSON lines, per-install token (same protocol shape as aicengine's).

  Everything runs in one loop that sleeps in poll() on the control socket for at most 100 ms, so there are
  no threads, no locks, and a stuck child can never block the supervisor (probes are forked children too).
  ============================================================================= *)
unit sup_core;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils, Classes, BaseUnix, Unix, Sockets, Users, fpjson, jsonparser,
  sup_util, sup_sched, sup_config, sup_proc, sup_guard;

type
  TSvcState = (ssStopped, ssWaiting, ssStarting, ssRunning, ssBackoff, ssStopping, ssFailed, ssDisabled);

  TSvcRt = class
  public
    Def, NewDef: TServiceDef;
    State: TSvcState;
    Pid, ProbePid: Integer;
    Adopted, WantRun, RestartAfterStop, Removing, Killing, AdoptTried: Boolean;
    Orphan: Boolean;                   // recovered after a supervisor crash: running, but not OUR child (no wait(), only kill -0)
    StartedMs, NextStartMs, StopSentMs, NextProbeMs, ProbeStartMs: QWord;
    Backoff, Restarts, Fails: Integer;
    Healthy: Integer;                  // -1 unknown, 0 bad, 1 good
    Crashes: TList;                    // crash timestamps (ms) inside the window, stored as pointers' worth of QWord
    LastExit, Reason: string;
    LogPath: string;
    constructor Create(ADef: TServiceDef);
    destructor Destroy; override;
  end;

  TJobRt = class
  public
    Def: TJobDef;
    Pid: Integer;
    StartedMs, KillSentMs: QWord;
    LastStart, LastEnd: Int64;         // unix seconds, persisted
    LastExit: Integer;
    LastStatus: string;
    Runs, Skipped: Integer;
    Base: TDateTime;                   // the time the next slot is computed from
    NextDue: TDateTime;
    DueComputed: Boolean;
    PendingStart: Boolean;             // overlap=kill: start again as soon as the old run is gone
    ManualRun: Boolean;
    LogPath: string;
    constructor Create(ADef: TJobDef);
    destructor Destroy; override;
  end;

  TSupervisor = class
  private
    FCfg: TSupConfig;
    FSvcs, FJobs, FGuards: TList;
    FToken: string;
    FListenFd: cint;
    FSupLog, FStateFile: string;
    FDirty: Boolean;
    FLoadTime: TDateTime;
    FShutdown, FReload: Boolean;
    FStartMs: QWord;
    function SvcByName(const N: string): TSvcRt;
    function JobByName(const N: string): TJobRt;
    procedure Log(const Msg: string);
    procedure LoadState;
    procedure SaveState;
    procedure AdoptConfig(NewCfg: TSupConfig; First: Boolean);
    // services
    procedure StartService(S: TSvcRt; Now_: QWord);
    procedure ServiceExited(S: TSvcRt; const E: TChildEnd; Now_: QWord);
    procedure ServicesTick(Now_: QWord);
    function PidFileOf(S: TSvcRt): string;
    function ChildEnd(S: TSvcRt): TChildEnd;           // wait() for our children, kill -0 for recovered orphans
    procedure RecoverOrphans;
    function DepsReady(S: TSvcRt): Boolean;
    procedure BeginStop(S: TSvcRt; Now_: QWord);
    procedure HealthTick(S: TSvcRt; Now_: QWord);
    function ProbeNow(S: TSvcRt): Boolean;                 // synchronous, for adoption only
    function StartProbe(S: TSvcRt): Integer;
    // jobs
    procedure JobsTick(Now_: QWord);
    procedure StartJob(J: TJobRt; Now_: QWord);
    procedure ComputeDue(J: TJobRt);
    // control
    procedure OpenControl;
    procedure ControlTick(TimeoutMs: Integer);
    procedure HandleControl(Fd: cint);
    function StatusJson: TJSONObject;
    function TailFile(const Path: string; Lines: Integer): string;
    procedure DoReload;
    procedure ShutdownAll;
  public
    constructor Create(ACfg: TSupConfig);
    destructor Destroy; override;
    function Run: Integer;
    procedure RequestShutdown;
    procedure RequestReload;
  end;

function StateName(S: TSvcState): string;

implementation

const
  VERSION = '0.1.0';
  FD_CLOEXEC = 1;                     // fcntl(F_SETFD): not exported by FPC's BaseUnix; the value is 1 on Linux and macOS

function UptimeOf(S: TSvcRt; NowMs: QWord): Integer;
begin
  if S.State in [ssRunning, ssStarting] then Result := Integer((NowMs - S.StartedMs) div 1000) else Result := 0;
end;

function StateName(S: TSvcState): string;
begin
  case S of
    ssStopped: Result := 'stopped';
    ssWaiting: Result := 'waiting';
    ssStarting: Result := 'starting';
    ssRunning: Result := 'running';
    ssBackoff: Result := 'backoff';
    ssStopping: Result := 'stopping';
    ssFailed: Result := 'failed';
    ssDisabled: Result := 'disabled';
  else
    Result := '?';
  end;
end;

{ ---- runtime records ---------------------------------------------------------------------------- }

constructor TSvcRt.Create(ADef: TServiceDef);
begin
  Def := ADef;
  State := ssStopped;
  WantRun := ADef.Enabled;
  if not ADef.Enabled then State := ssDisabled;
  Healthy := -1;
  Crashes := TList.Create;
end;

destructor TSvcRt.Destroy;
begin
  Crashes.Free;
  Def.Free;
  NewDef.Free;
  inherited Destroy;
end;

constructor TJobRt.Create(ADef: TJobDef);
begin
  Def := ADef;
  LastExit := -1;
  LastStatus := 'never';
end;

destructor TJobRt.Destroy;
begin
  Def.Free;
  inherited Destroy;
end;

{ ---- construction ------------------------------------------------------------------------------- }

constructor TSupervisor.Create(ACfg: TSupConfig);
begin
  inherited Create;
  FCfg := ACfg;
  FSvcs := TList.Create;
  FJobs := TList.Create;
  FGuards := TList.Create;
  FListenFd := -1;
  FLoadTime := Now;
  FStartMs := GetTickCount64;
  FSupLog := FCfg.LogDir + '/supervisor.log';
  FStateFile := FCfg.StateDir + '/state.json';
end;

destructor TSupervisor.Destroy;
var
  i: Integer;
begin
  for i := 0 to FSvcs.Count - 1 do TSvcRt(FSvcs[i]).Free;
  for i := 0 to FJobs.Count - 1 do TJobRt(FJobs[i]).Free;
  for i := 0 to FGuards.Count - 1 do TGuardRunner(FGuards[i]).Free;
  FSvcs.Free; FJobs.Free; FGuards.Free;
  FCfg.Free;
  inherited Destroy;
end;

procedure TSupervisor.Log(const Msg: string);
begin
  LogLine(FSupLog, Msg, 2048, 3);
  WriteLn(StdErr, NowStamp, '  ', Msg);
  Flush(StdErr);
end;

function TSupervisor.SvcByName(const N: string): TSvcRt;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FSvcs.Count - 1 do if TSvcRt(FSvcs[i]).Def.Name = N then Exit(TSvcRt(FSvcs[i]));
end;

function TSupervisor.JobByName(const N: string): TJobRt;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FJobs.Count - 1 do if TJobRt(FJobs[i]).Def.Name = N then Exit(TJobRt(FJobs[i]));
end;

procedure TSupervisor.RequestShutdown;
begin
  FShutdown := True;
end;

procedure TSupervisor.RequestReload;
begin
  FReload := True;
end;

{ ---- persistent state (job last-run times) ------------------------------------------------------ }

procedure TSupervisor.LoadState;
var
  d: TJSONData;
  jobs, o: TJSONObject;
  i: Integer;
  j: TJobRt;
begin
  if not FileExists(FStateFile) then Exit;
  try d := GetJSON(ReadFileString(FStateFile)); except d := nil; end;
  if (d = nil) or (d.JSONType <> jtObject) then begin d.Free; Exit; end;
  try
    jobs := TJSONObject(d).Get('jobs', TJSONObject(nil));
    if jobs = nil then Exit;
    for i := 0 to jobs.Count - 1 do
    begin
      j := JobByName(jobs.Names[i]);
      if (j = nil) or (jobs.Items[i].JSONType <> jtObject) then Continue;
      o := TJSONObject(jobs.Items[i]);
      j.LastStart := o.Get('last_start', Int64(0));
      j.LastEnd := o.Get('last_end', Int64(0));
      j.LastExit := o.Get('last_exit', -1);
      j.LastStatus := o.Get('last_status', 'never');
      j.Runs := o.Get('runs', 0);
    end;
  finally
    d.Free;
  end;
end;

procedure TSupervisor.SaveState;
var
  root, jobs, o: TJSONObject;
  i: Integer;
  j: TJobRt;
begin
  root := TJSONObject.Create;
  jobs := TJSONObject.Create;
  try
    for i := 0 to FJobs.Count - 1 do
    begin
      j := TJobRt(FJobs[i]);
      o := TJSONObject.Create(['last_start', j.LastStart, 'last_end', j.LastEnd, 'last_exit', j.LastExit,
        'last_status', j.LastStatus, 'runs', j.Runs]);
      jobs.Add(j.Def.Name, o);
    end;
    root.Add('jobs', jobs);
    jobs := nil;
    WriteFileAtomic(FStateFile, root.FormatJSON + #10, &600);
    FDirty := False;
  finally
    jobs.Free;
    root.Free;
  end;
end;

{ ---- taking over a (re)loaded configuration ------------------------------------------------------ }

procedure TSupervisor.AdoptConfig(NewCfg: TSupConfig; First: Boolean);
var
  i, k: Integer;
  nd: TServiceDef;
  rt: TSvcRt;
  nj: TJobDef;
  jr: TJobRt;
  gd: TGuardDef;
  newSvcs, newJobs, newGuards: TList;
  found: TGuardRunner;
begin
  // ---- services: rebuild the list in the NEW start order, keeping the runtime of every service that stays ----
  newSvcs := TList.Create;
  for i := 0 to NewCfg.Services.Count - 1 do
  begin
    nd := TServiceDef(NewCfg.Services[i]);
    rt := SvcByName(nd.Name);
    if rt = nil then
    begin
      rt := TSvcRt.Create(nd);
      rt.LogPath := NewCfg.LogDir + '/' + SafeName(nd.Name) + '.log';
      newSvcs.Add(rt);
      if not First then Log('config: service "' + nd.Name + '" added');
    end
    else
    begin
      FSvcs.Remove(rt);
      if rt.Def.SameAs(nd) then
      begin
        // unchanged: keep running, just take the new definition's tuning (timeouts, backoff...)
        rt.Def.Free; rt.Def := nd;
      end
      else
      begin
        Log('config: service "' + nd.Name + '" changed: restarting it');
        rt.NewDef.Free; rt.NewDef := nd;
        rt.RestartAfterStop := True;
      end;
      newSvcs.Add(rt);
    end;
  end;
  for i := 0 to FSvcs.Count - 1 do                  // whatever is left was removed from the config
  begin
    rt := TSvcRt(FSvcs[i]);
    Log('config: service "' + rt.Def.Name + '" removed: stopping it');
    rt.Removing := True; rt.WantRun := False;
    newSvcs.Add(rt);
  end;
  FSvcs.Free;
  FSvcs := newSvcs;
  NewCfg.Services.Clear;                            // ownership of the definitions moved to the runtimes

  // ---- jobs ----
  newJobs := TList.Create;
  for i := 0 to NewCfg.Jobs.Count - 1 do
  begin
    nj := TJobDef(NewCfg.Jobs[i]);
    jr := JobByName(nj.Name);
    if jr = nil then
    begin
      jr := TJobRt.Create(nj);
      jr.LogPath := NewCfg.LogDir + '/jobs/' + SafeName(nj.Name) + '.log';
      jr.Base := Now;
      newJobs.Add(jr);
    end
    else
    begin
      FJobs.Remove(jr);
      if not jr.Def.SameAs(nj) then jr.DueComputed := False;
      jr.Def.Free; jr.Def := nj;
      jr.LogPath := NewCfg.LogDir + '/jobs/' + SafeName(nj.Name) + '.log';
      newJobs.Add(jr);
    end;
  end;
  for i := 0 to FJobs.Count - 1 do
  begin
    jr := TJobRt(FJobs[i]);
    if jr.Pid > 0 then KillTree(jr.Pid, False);
    jr.Free;
  end;
  FJobs.Free;
  FJobs := newJobs;
  NewCfg.Jobs.Clear;

  // ---- guards ----
  newGuards := TList.Create;
  for i := 0 to NewCfg.Guards.Count - 1 do
  begin
    gd := TGuardDef(NewCfg.Guards[i]);
    found := nil;
    for k := 0 to FGuards.Count - 1 do
      if TGuardRunner(FGuards[k]).Def.Name = gd.Name then found := TGuardRunner(FGuards[k]);
    if (found <> nil) and found.Def.SameAs(gd) then
    begin
      FGuards.Remove(found); newGuards.Add(found); gd.Free;
    end
    else newGuards.Add(TGuardRunner.Create(gd));
  end;
  for i := 0 to FGuards.Count - 1 do TGuardRunner(FGuards[i]).Free;   // replaced or removed ones (they own their defs? no: defs are freed with the config)
  FGuards.Free;
  FGuards := newGuards;
  NewCfg.Guards.Clear;

  if NewCfg <> FCfg then begin FCfg.Free; FCfg := NewCfg; end;     // at startup the supervisor adopts its own config
end;

procedure TSupervisor.DoReload;
var
  err: string;
  nc: TSupConfig;
begin
  nc := LoadConfig(FCfg.ConfigFile, err);
  if nc = nil then
  begin
    Log('reload refused: the new configuration is invalid, the old one stays in force:' + #10 + Trim(err));
    Exit;
  end;
  AdoptConfig(nc, False);
  Log('configuration reloaded');
end;

{ ---- services ------------------------------------------------------------------------------------ }

function TSupervisor.StartProbe(S: TSvcRt): Integer;
var
  h: THealthDef;
  args: TStringList;
  err: string;
begin
  h := S.Def.Health;
  Result := -1;
  if h.Kind = 'tcp' then Result := ForkProbeTcp(h.Host, h.Port, h.TimeoutS * 1000)
  else if h.Kind = 'unix' then Result := ForkProbeUnix(h.Sock, h.TimeoutS * 1000)
  else if h.Kind = 'http' then Result := ForkProbeHttp(h.Url, h.TimeoutS * 1000)
  else if h.Kind = 'command' then
  begin
    args := TStringList.Create;
    try
      args.AddStrings(h.Args);
      Result := SpawnProcess(h.Command, args, nil, S.Def.Cwd, FCfg.LogDir + '/' + SafeName(S.Def.Name) + '.health.log', err);
    finally
      args.Free;
    end;
  end;
end;

{ Synchronous probe, used ONCE per start to decide whether to adopt an already-running service. }
function TSupervisor.ProbeNow(S: TSvcRt): Boolean;
var
  pid: Integer;
  e: TChildEnd;
  t0: QWord;
begin
  Result := False;
  pid := StartProbe(S);
  if pid <= 0 then Exit;
  t0 := GetTickCount64;
  repeat
    e := PollChild(pid);
    if e.Ended then Exit((e.ExitCode = 0) and (e.Signal = 0));
    Sleep(20);
  until GetTickCount64 - t0 > QWord(S.Def.Health.TimeoutS + 1) * 1000;
  KillTree(pid, True);
  PollChild(pid);
end;

function TSupervisor.DepsReady(S: TSvcRt): Boolean;
var
  i: Integer;
  d: TSvcRt;
begin
  Result := True;
  for i := 0 to S.Def.StartAfter.Count - 1 do
  begin
    d := SvcByName(S.Def.StartAfter[i]);
    if (d = nil) or (d.State <> ssRunning) then Exit(False);
    if (d.Def.Health.Kind <> 'none') and (d.Healthy <> 1) then Exit(False);
  end;
end;

function TSupervisor.PidFileOf(S: TSvcRt): string;
begin
  Result := FCfg.StateDir + '/pids/' + SafeName(S.Def.Name) + '.pid';
end;

function TSupervisor.ChildEnd(S: TSvcRt): TChildEnd;
begin
  if S.Orphan then
  begin
    FillChar(Result, SizeOf(Result), 0);
    if not PidAlive(S.Pid) then begin Result.Ended := True; Result.ExitCode := -1; end;
  end
  else Result := PollChild(S.Pid);
end;

{ The first argument of a process's command line (Linux /proc); '' when it cannot be read. }
function ProcExe(Pid: Integer): string;
var
  data: string;
  p: Integer;
begin
  data := ReadFileString('/proc/' + IntToStr(Pid) + '/cmdline');
  p := Pos(#0, data);
  if p > 0 then Result := Copy(data, 1, p - 1) else Result := data;
end;

{ After a supervisor crash the services it started are still running (each lives in its own session).
  A pid file per service lets the NEXT supervisor take them back instead of starting duplicates.  The pid
  is trusted only if that process still runs the service's own program. }
procedure TSupervisor.RecoverOrphans;
var
  i: Integer;
  s: TSvcRt;
  pf, want, have: string;
  sl: TStringList;
  pid: Integer;
begin
  for i := 0 to FSvcs.Count - 1 do
  begin
    s := TSvcRt(FSvcs[i]);
    pf := PidFileOf(s);
    if not FileExists(pf) then Continue;
    sl := TStringList.Create;
    try
      try sl.LoadFromFile(pf); except sl.Clear; end;
      pid := 0;
      if sl.Count > 0 then pid := StrToIntDef(sl[0], 0);
      if (pid > 1) and PidAlive(pid) then
      begin
        want := FindExe(s.Def.Command, GetEnvironmentVariable('PATH'));
        have := ProcExe(pid);
        if (have = '') or (have = want) then
        begin
          s.Pid := pid; s.Orphan := True; s.StartedMs := GetTickCount64; s.Healthy := -1;
          if s.Def.Health.Kind = 'none' then s.State := ssRunning else s.State := ssStarting;
          s.NextProbeMs := GetTickCount64 + 300;
          Log('service "' + s.Def.Name + '": recovered after a supervisor restart (pid ' + IntToStr(pid) + ' is still running)');
          Continue;
        end;
        Log('service "' + s.Def.Name + '": pid file names pid ' + IntToStr(pid) + ' but it runs "' + have + '", not "' + want + '": ignored');
      end;
      DeleteFile(pf);
    finally
      sl.Free;
    end;
  end;
end;

procedure TSupervisor.StartService(S: TSvcRt; Now_: QWord);
var
  err: string;
  pid: Integer;
  fe: TChildEnd;
begin
  // adoption: something already answers on this service's health check -> leave it alone
  if S.Def.AdoptIfHealthy and not S.AdoptTried then
  begin
    S.AdoptTried := True;
    if ProbeNow(S) then
    begin
      S.Adopted := True; S.Pid := 0; S.State := ssRunning; S.StartedMs := Now_; S.Healthy := 1; S.Fails := 0;
      S.NextProbeMs := Now_ + QWord(S.Def.Health.IntervalS) * 1000;
      Log('service "' + S.Def.Name + '": already running and healthy: adopted, not started, will not be stopped');
      Exit;
    end;
  end;
  RotateFile(S.LogPath, S.Def.LogMaxKB, 3);
  pid := SpawnProcess(S.Def.Command, S.Def.Args, S.Def.Env, S.Def.Cwd, S.LogPath, err);
  if pid < 0 then
  begin
    Log('service "' + S.Def.Name + '": could not start: ' + err);
    S.StartedMs := Now_;
    FillChar(fe, SizeOf(fe), 0);
    fe.Ended := True; fe.ExitCode := 127;                   // a program that cannot start counts as a crash: backoff, crash loop limit
    ServiceExited(S, fe, Now_);
    S.LastExit := 'could not start: ' + err;
    Exit;
  end;
  S.Pid := pid; S.Adopted := False; S.Orphan := False; S.StartedMs := Now_; S.Killing := False; S.Fails := 0; S.Healthy := -1;
  ForceDirectories(FCfg.StateDir + '/pids');
  WriteFileAtomic(PidFileOf(S), IntToStr(pid) + #10 + IntToStr(UnixNow) + #10 + S.Def.Command + #10, &600);
  S.NextProbeMs := Now_ + 500;
  if S.Def.Health.Kind = 'none' then S.State := ssRunning else S.State := ssStarting;
  Log('service "' + S.Def.Name + '": started, pid ' + IntToStr(pid));
end;

procedure TSupervisor.BeginStop(S: TSvcRt; Now_: QWord);
begin
  if S.Adopted then
  begin
    S.State := ssStopped; S.Adopted := False; S.Healthy := -1;
    Log('service "' + S.Def.Name + '": was adopted, left running');
    Exit;
  end;
  if S.Pid > 0 then
  begin
    KillTree(S.Pid, False);
    S.State := ssStopping; S.StopSentMs := Now_;
    Log('service "' + S.Def.Name + '": stopping (SIGTERM to pid ' + IntToStr(S.Pid) + ')');
  end
  else S.State := ssStopped;
end;

procedure TSupervisor.ServiceExited(S: TSvcRt; const E: TChildEnd; Now_: QWord);
var
  i: Integer;
  ranFor: QWord;
  wantRestart, crash: Boolean;
  recent: Integer;
  t: QWord;
begin
  ranFor := Now_ - S.StartedMs;
  S.Pid := 0; S.Orphan := False;
  DeleteFile(PidFileOf(S));
  if E.Signal <> 0 then S.LastExit := 'killed by signal ' + IntToStr(E.Signal) else S.LastExit := 'exit ' + IntToStr(E.ExitCode);
  if S.Killing then S.LastExit := S.LastExit + ' (' + S.Reason + ')';

  if S.State = ssStopping then
  begin
    S.State := ssStopped;
    Log('service "' + S.Def.Name + '": stopped (' + S.LastExit + ')');
    if S.RestartAfterStop and not S.Removing then
    begin
      if S.NewDef <> nil then begin S.Def.Free; S.Def := S.NewDef; S.NewDef := nil; end;
      S.State := ssBackoff; S.NextStartMs := Now_; S.Backoff := 0; S.AdoptTried := False;
      S.RestartAfterStop := False; S.WantRun := S.Def.Enabled;
    end;
    Exit;
  end;

  crash := (E.Signal <> 0) or (E.ExitCode <> 0) or S.Killing;
  Log('service "' + S.Def.Name + '": ended after ' + IntToStr(ranFor div 1000) + ' s (' + S.LastExit + ')');
  S.Killing := False;
  if ranFor >= QWord(S.Def.StableAfterS) * 1000 then begin S.Backoff := 0; S.Crashes.Clear; end;
  wantRestart := (S.Def.Restart = 'always') or ((S.Def.Restart = 'on-failure') and crash);
  if (not wantRestart) or (not S.WantRun) then
  begin
    S.State := ssStopped;
    if not wantRestart then begin S.WantRun := False; Log('service "' + S.Def.Name + '": finished, not restarting (restart=' + S.Def.Restart + ')'); end;
    Exit;
  end;
  // crash accounting inside the window
  S.Crashes.Add(Pointer(PtrUInt(Now_)));
  recent := 0;
  for i := S.Crashes.Count - 1 downto 0 do
  begin
    t := QWord(PtrUInt(S.Crashes[i]));
    if Now_ - t > QWord(S.Def.RestartWindowS) * 1000 then S.Crashes.Delete(i) else Inc(recent);
  end;
  if recent > S.Def.MaxRestarts then
  begin
    S.State := ssFailed;
    S.Reason := IntToStr(recent) + ' crashes within ' + IntToStr(S.Def.RestartWindowS) + ' s';
    Log('service "' + S.Def.Name + '": FAILED, crash loop (' + S.Reason + '); it stays down until started by hand');
    Exit;
  end;
  if S.Backoff = 0 then S.Backoff := S.Def.BackoffMinS else S.Backoff := S.Backoff * 2;
  if S.Backoff > S.Def.BackoffMaxS then S.Backoff := S.Def.BackoffMaxS;
  S.NextStartMs := Now_ + QWord(S.Backoff) * 1000;
  S.State := ssBackoff;
  Inc(S.Restarts);
  Log('service "' + S.Def.Name + '": restarting in ' + IntToStr(S.Backoff) + ' s (restart #' + IntToStr(S.Restarts) + ')');
end;

procedure TSupervisor.HealthTick(S: TSvcRt; Now_: QWord);
var
  e: TChildEnd;
  h: THealthDef;
  good: Boolean;
  inGrace: Boolean;
begin
  h := S.Def.Health;
  if h.Kind = 'none' then Exit;
  if (S.State <> ssStarting) and (S.State <> ssRunning) then Exit;
  inGrace := (not S.Adopted) and (Now_ - S.StartedMs < QWord(h.StartGraceS) * 1000);

  if S.ProbePid > 0 then
  begin
    e := PollChild(S.ProbePid);
    if (not e.Ended) and (Now_ - S.ProbeStartMs > QWord(h.TimeoutS + 1) * 1000) then
    begin
      KillTree(S.ProbePid, True); e := PollChild(S.ProbePid);
      if not e.Ended then begin e.Ended := True; e.ExitCode := 1; end;
    end;
    if e.Ended then
    begin
      S.ProbePid := 0;
      good := (e.ExitCode = 0) and (e.Signal = 0);
      if good then
      begin
        S.Fails := 0;
        if S.Healthy <> 1 then Log('service "' + S.Def.Name + '": healthy');
        S.Healthy := 1;
        if S.State = ssStarting then S.State := ssRunning;
      end
      else
      begin
        S.Healthy := 0;
        if not inGrace then Inc(S.Fails);
        if (not inGrace) and (S.Fails >= h.Failures) then
        begin
          Log('service "' + S.Def.Name + '": health check failed ' + IntToStr(S.Fails) + ' times in a row');
          S.Fails := 0;
          if S.Adopted then
          begin
            Log('service "' + S.Def.Name + '": the adopted instance is gone; starting our own');
            S.Adopted := False; S.State := ssBackoff; S.NextStartMs := Now_; S.AdoptTried := True;
          end
          else if S.Pid > 0 then
          begin
            S.Killing := True; S.Reason := 'unhealthy';
            KillTree(S.Pid, False);                   // the reaper sees the exit and restarts per policy
            S.StopSentMs := Now_;
          end;
        end;
      end;
    end;
    Exit;
  end;
  if Now_ >= S.NextProbeMs then
  begin
    S.ProbePid := StartProbe(S);
    S.ProbeStartMs := Now_;
    S.NextProbeMs := Now_ + QWord(h.IntervalS) * 1000;
    if S.ProbePid <= 0 then S.ProbePid := 0;
  end;
end;

procedure TSupervisor.ServicesTick(Now_: QWord);
var
  i: Integer;
  s: TSvcRt;
  e: TChildEnd;
begin
  for i := 0 to FSvcs.Count - 1 do
  begin
    s := TSvcRt(FSvcs[i]);
    // 1. reap
    if s.Pid > 0 then
    begin
      e := ChildEnd(s);
      if e.Ended then ServiceExited(s, e, Now_)
      else if (s.State = ssStopping) and (Now_ - s.StopSentMs > QWord(s.Def.StopTimeoutS) * 1000) then
      begin
        Log('service "' + s.Def.Name + '": did not stop within ' + IntToStr(s.Def.StopTimeoutS) + ' s, SIGKILL');
        KillTree(s.Pid, True);
        s.StopSentMs := Now_ + 3600000;               // do not repeat
      end
      else if s.Killing and (Now_ - s.StopSentMs > QWord(s.Def.StopTimeoutS) * 1000) then
      begin
        KillTree(s.Pid, True); s.StopSentMs := Now_ + 3600000;
      end;
    end;
    // 2. a service waiting to (re)start
    if (s.State in [ssStopped, ssWaiting, ssBackoff]) and s.WantRun and not s.Removing and (s.State <> ssFailed) then
    begin
      if (s.State = ssBackoff) and (Now_ < s.NextStartMs) then Continue;
      if s.State = ssStopped then s.NextStartMs := Now_;
      if DepsReady(s) then
      begin
        if s.State = ssWaiting then Log('service "' + s.Def.Name + '": dependencies are up');
        StartService(s, Now_);
      end
      else if s.State <> ssWaiting then
      begin
        s.State := ssWaiting;
        Log('service "' + s.Def.Name + '": waiting for ' + Trim(StringReplace(s.Def.StartAfter.CommaText, ',', ' ', [rfReplaceAll])));
      end;
    end;
    // 3. a service that was asked to go away and has
    if s.Removing and (s.State in [ssStopped, ssBackoff, ssWaiting, ssFailed]) then
    begin
      s.State := ssStopped;
    end
    else if s.Removing and (s.State in [ssRunning, ssStarting]) then BeginStop(s, Now_);
    if s.RestartAfterStop and (s.State in [ssRunning, ssStarting]) then BeginStop(s, Now_);
    if s.RestartAfterStop and (s.State in [ssStopped, ssBackoff, ssWaiting, ssFailed]) and (s.Pid = 0) then
    begin
      if s.NewDef <> nil then begin s.Def.Free; s.Def := s.NewDef; s.NewDef := nil; end;
      s.RestartAfterStop := False; s.AdoptTried := False; s.Backoff := 0; s.NextStartMs := Now_;
      s.State := ssBackoff; s.WantRun := s.Def.Enabled;
      if not s.Def.Enabled then s.State := ssDisabled;
    end;
    // 4. health
    HealthTick(s, Now_);
  end;
  // remove services whose removal has completed
  for i := FSvcs.Count - 1 downto 0 do
  begin
    s := TSvcRt(FSvcs[i]);
    if s.Removing and (s.Pid = 0) and (s.State = ssStopped) then begin FSvcs.Delete(i); s.Free; end;
  end;
end;

{ ---- jobs ---------------------------------------------------------------------------------------- }

procedure TSupervisor.ComputeDue(J: TJobRt);
var
  basis: TDateTime;
  d: Integer;
begin
  if J.Def.Sched.Kind = skEvery then
  begin
    if J.LastStart > 0 then J.NextDue := UnixToDateTime(J.LastStart, False) + J.Def.Sched.EverySecs / 86400
    else if J.Def.RunAtStart then J.NextDue := Now - 1 / 86400
    else J.NextDue := FLoadTime + J.Def.Sched.EverySecs / 86400;
  end
  else
  begin
    // a persistent job counts from its last real run (so a slot missed while we were down is still due);
    // a non-persistent one counts from now (missed slots are skipped)
    if J.Def.Persistent and (J.LastStart > 0) then basis := UnixToDateTime(J.LastStart, False) else basis := J.Base;
    J.NextDue := FirstSlotAfter(J.Def.Sched, basis);
  end;
  if J.Def.RandomDelayS > 0 then
  begin
    d := Random(J.Def.RandomDelayS + 1);
    J.NextDue := J.NextDue + d / 86400;
  end;
  J.DueComputed := True;
end;

procedure TSupervisor.StartJob(J: TJobRt; Now_: QWord);
var
  err: string;
  pid: Integer;
begin
  RotateFile(J.LogPath, J.Def.LogMaxKB, 3);
  pid := SpawnProcess(J.Def.Command, J.Def.Args, J.Def.Env, J.Def.Cwd, J.LogPath, err);
  J.LastStart := UnixNow;
  J.Base := Now;
  J.DueComputed := False;
  Inc(J.Runs);
  if pid < 0 then
  begin
    J.Pid := 0; J.LastEnd := UnixNow; J.LastExit := 127; J.LastStatus := 'could not start';
    Log('job "' + J.Def.Name + '": could not start: ' + err);
  end
  else
  begin
    J.Pid := pid; J.StartedMs := Now_; J.KillSentMs := 0; J.LastStatus := 'running'; J.LastExit := -1;
    Log('job "' + J.Def.Name + '": started, pid ' + IntToStr(pid));
  end;
  FDirty := True;
end;

procedure TSupervisor.JobsTick(Now_: QWord);
var
  i: Integer;
  j: TJobRt;
  e: TChildEnd;
begin
  for i := 0 to FJobs.Count - 1 do
  begin
    j := TJobRt(FJobs[i]);
    if not j.Def.Enabled then Continue;
    // running: reap, enforce the timeout
    if j.Pid > 0 then
    begin
      e := PollChild(j.Pid);
      if e.Ended then
      begin
        j.LastEnd := UnixNow; j.LastExit := e.ExitCode; j.Pid := 0;
        if j.KillSentMs > 0 then j.LastStatus := 'timeout' else if e.ExitCode = 0 then j.LastStatus := 'ok' else j.LastStatus := 'failed';
        Log('job "' + j.Def.Name + '": finished, ' + j.LastStatus + ', exit ' + IntToStr(e.ExitCode) + ', ' + IntToStr((Now_ - j.StartedMs) div 1000) + ' s');
        FDirty := True;
        j.KillSentMs := 0;
        if j.PendingStart then begin j.PendingStart := False; StartJob(j, Now_); end;
      end
      else if (j.KillSentMs = 0) and (Now_ - j.StartedMs > QWord(j.Def.TimeoutS) * 1000) then
      begin
        Log('job "' + j.Def.Name + '": timed out after ' + IntToStr(j.Def.TimeoutS) + ' s, killing its process tree');
        KillTree(j.Pid, False); j.KillSentMs := Now_;
      end
      else if (j.KillSentMs > 0) and (Now_ - j.KillSentMs > 3000) then begin KillTree(j.Pid, True); j.KillSentMs := Now_ + 3600000; end;
    end;
    // due?
    if not j.DueComputed then ComputeDue(j);
    if Now >= j.NextDue then
    begin
      if j.Pid > 0 then
      begin
        if j.Def.Overlap = 'kill' then
        begin
          if not j.PendingStart then begin Log('job "' + j.Def.Name + '": due while running: killing the old run'); KillTree(j.Pid, False); j.KillSentMs := Now_; j.PendingStart := True; end;
        end
        else
        begin
          Inc(j.Skipped);
          Log('job "' + j.Def.Name + '": due while still running: skipped (overlap=skip)');
          j.Base := Now; j.DueComputed := False;
          if j.Def.Sched.Kind = skEvery then begin j.NextDue := Now + j.Def.Sched.EverySecs / 86400; j.DueComputed := True; end;
        end;
      end
      else StartJob(j, Now_);
    end;
  end;
end;

{ ---- control socket ------------------------------------------------------------------------------ }

procedure TSupervisor.OpenControl;
var
  addr: sockaddr_un;
  probe: cint;
  gid: TGid;
  path: string;
begin
  path := FCfg.CtlSocket;
  ForceDirectories(ExtractFilePath(path));
  if FileExists(path) then
  begin
    probe := fpSocket(AF_UNIX, SOCK_STREAM, 0);
    FillChar(addr, SizeOf(addr), 0); addr.sun_family := AF_UNIX; StrPCopy(addr.sun_path, path);
    if fpConnect(probe, @addr, SizeOf(addr)) = 0 then begin fpClose(probe); raise Exception.Create('another supervisor is already running on ' + path); end;
    fpClose(probe);
    DeleteFile(path);
  end;
  FListenFd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  FillChar(addr, SizeOf(addr), 0); addr.sun_family := AF_UNIX; StrPCopy(addr.sun_path, path);
  fpUmask(&077);
  if fpBind(FListenFd, @addr, SizeOf(addr)) <> 0 then raise Exception.Create('cannot bind ' + path);
  if FCfg.CtlGroup <> '' then
  begin
    gid := GetGroupId(FCfg.CtlGroup);
    if gid <> TGid(-1) then fpChown(path, TUid(-1), gid);
  end;
  fpChmod(path, FCfg.CtlMode);
  fpListen(FListenFd, 16);
  fpFcntl(FListenFd, F_SETFD, FD_CLOEXEC);
  fpFcntl(FListenFd, F_SETFL, fpFcntl(FListenFd, F_GETFL) or O_NONBLOCK);
end;

function TSupervisor.TailFile(const Path: string; Lines: Integer): string;
var
  data: string;
  sl: TStringList;
  i, from: Integer;
begin
  Result := '';
  data := ReadFileString(Path);
  if Length(data) > 262144 then data := Copy(data, Length(data) - 262143, MaxInt);
  sl := TStringList.Create;
  try
    sl.Text := data;
    from := sl.Count - Lines;
    if from < 0 then from := 0;
    for i := from to sl.Count - 1 do Result := Result + sl[i] + #10;
  finally
    sl.Free;
  end;
end;

function TSupervisor.StatusJson: TJSONObject;
var
  sv, jb, gd: TJSONArray;
  i: Integer;
  s: TSvcRt;
  j: TJobRt;
  g: TGuardRunner;
  nxt: string;
  nowMs: QWord;
begin
  nowMs := GetTickCount64;
  sv := TJSONArray.Create; jb := TJSONArray.Create; gd := TJSONArray.Create;
  for i := 0 to FSvcs.Count - 1 do
  begin
    s := TSvcRt(FSvcs[i]);
    if s.Removing then Continue;
    sv.Add(TJSONObject.Create(['name', s.Def.Name, 'state', StateName(s.State), 'pid', s.Pid, 'adopted', s.Adopted,
      'healthy', s.Healthy, 'restarts', s.Restarts, 'uptime_s', UptimeOf(s, nowMs),
      'last_exit', s.LastExit, 'reason', s.Reason, 'backoff_s', s.Backoff, 'want_run', s.WantRun]));
  end;
  for i := 0 to FJobs.Count - 1 do
  begin
    j := TJobRt(FJobs[i]);
    if j.DueComputed then nxt := FormatDateTime('yyyy-mm-dd hh:nn:ss', j.NextDue) else nxt := '';
    jb.Add(TJSONObject.Create(['name', j.Def.Name, 'schedule', ScheduleToText(j.Def.Sched), 'enabled', j.Def.Enabled, 'running', j.Pid > 0,
      'last_start', j.LastStart, 'last_end', j.LastEnd, 'last_exit', j.LastExit, 'last_status', j.LastStatus,
      'runs', j.Runs, 'skipped', j.Skipped, 'next_due', nxt]));
  end;
  for i := 0 to FGuards.Count - 1 do
  begin
    g := TGuardRunner(FGuards[i]);
    gd.Add(TJSONObject.Create(['name', g.Def.Name, 'enabled', g.Def.Enabled, 'files', g.FilesCount, 'checks', g.Checks,
      'violations', g.Violations, 'restored', g.Restored, 'last_check', g.LastCheckAt, 'last_violation', g.LastViolation]));
  end;
  Result := TJSONObject.Create(['ok', True, 'version', VERSION, 'pid', Int64(fpGetpid), 'uptime_s', Integer((nowMs - FStartMs) div 1000),
    'config', FCfg.ConfigFile, 'services', sv, 'jobs', jb, 'guards', gd]);
end;

procedure SendJson(fd: cint; O: TJSONObject);
var
  s: string;
  p, n: Integer;
begin
  s := O.FormatJSON([foSingleLineArray, foSingleLineObject, foSkipWhiteSpace], 0) + #10;
  O.Free;
  p := 1;
  while p <= Length(s) do
  begin
    n := fpWrite(fd, s[p], Length(s) - p + 1);
    if n <= 0 then Exit;
    Inc(p, n);
  end;
end;

procedure SendErr(fd: cint; const Msg: string);
begin
  SendJson(fd, TJSONObject.Create(['ok', False, 'error', Msg]));
end;

{ the signals a control client may send: the polite ones, never KILL (that is what "stop" is for) }
function SignalNumber(const N: string): Integer;
begin
  Result := 0;
  if (N = 'INT') or (N = 'SIGINT') then Result := SIGINT
  else if (N = 'TERM') or (N = 'SIGTERM') then Result := SIGTERM
  else if (N = 'HUP') or (N = 'SIGHUP') then Result := SIGHUP
  else if (N = 'USR1') or (N = 'SIGUSR1') then Result := SIGUSR1
  else if (N = 'USR2') or (N = 'SIGUSR2') then Result := SIGUSR2;
end;

procedure TSupervisor.HandleControl(Fd: cint);
var
  buf: array[0..65535] of Byte;
  line: string;
  n, rc: Integer;
  pfd: TPollFd;
  d: TJSONData;
  req: TJSONObject;
  op, name, tok: string;
  s: TSvcRt;
  j: TJobRt;
  g: Integer;
  t0: QWord;
  nowMs: QWord;
  ok: Boolean;
begin
  line := '';
  t0 := GetTickCount64;
  repeat
    pfd.fd := Fd; pfd.events := POLLIN; pfd.revents := 0;
    rc := fpPoll(@pfd, 1, 100);
    if rc > 0 then
    begin
      n := fpRead(Fd, buf, SizeOf(buf));
      if n <= 0 then Exit;
      SetString(tok, PChar(@buf[0]), n);
      line := line + tok;
    end;
  until (Pos(#10, line) > 0) or (GetTickCount64 - t0 > 400) or (Length(line) > 65536);
  if Pos(#10, line) = 0 then begin SendErr(Fd, 'incomplete request'); Exit; end;
  line := Copy(line, 1, Pos(#10, line) - 1);
  try d := GetJSON(line); except SendErr(Fd, 'not valid JSON'); Exit; end;
  if d.JSONType <> jtObject then begin d.Free; SendErr(Fd, 'must be a JSON object'); Exit; end;
  req := TJSONObject(d);
  try
    tok := req.Get('token', '');
    if tok <> FToken then begin Sleep(150); SendErr(Fd, 'unauthorized'); Exit; end;
    op := req.Get('op', '');
    name := req.Get('name', '');
    nowMs := GetTickCount64;
    if op = 'ping' then SendJson(Fd, TJSONObject.Create(['ok', True, 'version', VERSION, 'pid', Int64(fpGetpid)]))
    else if op = 'status' then SendJson(Fd, StatusJson)
    else if (op = 'start') or (op = 'stop') or (op = 'restart') then
    begin
      s := SvcByName(name);
      if (s = nil) or s.Removing then begin SendErr(Fd, 'no such service: ' + name); Exit; end;
      if op = 'start' then
      begin
        s.WantRun := True; s.Crashes.Clear; s.Backoff := 0; s.Reason := ''; s.AdoptTried := False;
        if s.State in [ssFailed, ssStopped, ssDisabled] then begin s.State := ssBackoff; s.NextStartMs := nowMs; end;
        Log('control: start "' + name + '"');
      end
      else if op = 'stop' then
      begin
        s.WantRun := False;
        if s.State in [ssRunning, ssStarting] then BeginStop(s, nowMs) else if s.State <> ssStopping then s.State := ssStopped;
        Log('control: stop "' + name + '"');
      end
      else
      begin
        s.WantRun := True; s.RestartAfterStop := True;
        Log('control: restart "' + name + '"');
      end;
      SendJson(Fd, TJSONObject.Create(['ok', True]));
    end
    else if op = 'signal' then
    begin
      // {"op":"signal","name":"svc","sig":"INT","scope":"children|group|leader"}: "Stop" for the work a service is doing, without stopping the service.
      s := SvcByName(name);
      if (s = nil) or s.Removing then begin SendErr(Fd, 'no such service: ' + name); Exit; end;
      if not (s.State in [ssRunning, ssStarting]) or (s.Pid <= 1) then begin SendErr(Fd, 'service is not running: ' + name); Exit; end;
      g := SignalNumber(req.Get('sig', 'INT'));
      if g <= 0 then begin SendErr(Fd, 'signal not allowed (INT, TERM, HUP, USR1, USR2): ' + req.Get('sig', '')); Exit; end;
      j := nil;
      rc := SignalTree(s.Pid, g, req.Get('scope', 'children'));
      if rc < 0 then begin SendErr(Fd, 'scope must be children, group or leader'); Exit; end;
      Log('control: signal ' + req.Get('sig', 'INT') + ' (' + req.Get('scope', 'children') + ') to "' + name + '": ' + IntToStr(rc) + ' process(es)');
      SendJson(Fd, TJSONObject.Create(['ok', True, 'signalled', rc]));
    end
    else if op = 'run_job' then
    begin
      j := JobByName(name);
      if j = nil then begin SendErr(Fd, 'no such job: ' + name); Exit; end;
      if j.Pid > 0 then begin SendErr(Fd, 'job is already running'); Exit; end;
      StartJob(j, nowMs);
      SendJson(Fd, TJSONObject.Create(['ok', True, 'pid', j.Pid]));
    end
    else if op = 'logs' then
    begin
      ok := False;
      s := SvcByName(name);
      if s <> nil then begin SendJson(Fd, TJSONObject.Create(['ok', True, 'text', TailFile(s.LogPath, req.Get('lines', 50))])); ok := True; end
      else
      begin
        j := JobByName(name);
        if j <> nil then begin SendJson(Fd, TJSONObject.Create(['ok', True, 'text', TailFile(j.LogPath, req.Get('lines', 50))])); ok := True; end
        else if name = 'supervisor' then begin SendJson(Fd, TJSONObject.Create(['ok', True, 'text', TailFile(FSupLog, req.Get('lines', 50))])); ok := True; end;
      end;
      if not ok then SendErr(Fd, 'no such service or job: ' + name);
    end
    else if op = 'guard_check' then
    begin
      g := 0;
      while g < FGuards.Count do begin TGuardRunner(FGuards[g]).Pass; Inc(g); end;
      SendJson(Fd, TJSONObject.Create(['ok', True]));
    end
    else if op = 'reload' then begin RequestReload; SendJson(Fd, TJSONObject.Create(['ok', True])); end
    else if op = 'shutdown' then begin RequestShutdown; SendJson(Fd, TJSONObject.Create(['ok', True])); end
    else SendErr(Fd, 'unknown op: ' + op);
  finally
    req.Free;
  end;
end;

procedure TSupervisor.ControlTick(TimeoutMs: Integer);
var
  pfd: TPollFd;
  cfd: cint;
  addr: sockaddr_un;
  alen: TSockLen;
  k: Integer;
begin
  pfd.fd := FListenFd; pfd.events := POLLIN; pfd.revents := 0;
  if fpPoll(@pfd, 1, TimeoutMs) <= 0 then Exit;
  for k := 1 to 8 do                                   // at most a handful per tick, so the loop stays responsive
  begin
    alen := SizeOf(addr);
    cfd := fpAccept(FListenFd, @addr, @alen);
    if cfd < 0 then Break;
    try
      HandleControl(cfd);
    finally
      fpClose(cfd);
    end;
  end;
end;

{ ---- main loop and shutdown ---------------------------------------------------------------------- }

procedure TSupervisor.ShutdownAll;
var
  i: Integer;
  s: TSvcRt;
  j: TJobRt;
  t0, nowMs: QWord;
  e: TChildEnd;
begin
  Log('shutting down');
  for i := 0 to FJobs.Count - 1 do
  begin
    j := TJobRt(FJobs[i]);
    if j.Pid > 0 then KillTree(j.Pid, False);
  end;
  for i := FSvcs.Count - 1 downto 0 do                 // reverse start order: dependents first
  begin
    s := TSvcRt(FSvcs[i]);
    s.WantRun := False;
    if s.Adopted then begin Log('service "' + s.Def.Name + '": adopted, left running'); Continue; end;
    if s.Pid <= 0 then Continue;
    KillTree(s.Pid, False);
    Log('service "' + s.Def.Name + '": stopping');
    t0 := GetTickCount64;
    repeat
      e := ChildEnd(s);
      if e.Ended then Break;
      Sleep(30);
      nowMs := GetTickCount64;
      if nowMs - t0 > QWord(s.Def.StopTimeoutS) * 1000 then
      begin
        Log('service "' + s.Def.Name + '": SIGKILL');
        KillTree(s.Pid, True);
        Sleep(100);
        ChildEnd(s);
        Break;
      end;
    until False;
    KillTree(s.Pid, True);                             // sweep any leftover group members
    DeleteFile(PidFileOf(s));
    s.Pid := 0; s.State := ssStopped;
  end;
  t0 := GetTickCount64;
  for i := 0 to FJobs.Count - 1 do
  begin
    j := TJobRt(FJobs[i]);
    if j.Pid <= 0 then Continue;
    while (GetTickCount64 - t0 < 2000) and not PollChild(j.Pid).Ended do Sleep(30);
    KillTree(j.Pid, True);
    PollChild(j.Pid);
    j.LastEnd := UnixNow; j.LastStatus := 'interrupted'; j.Pid := 0;
  end;
  SaveState;
end;

function TSupervisor.Run: Integer;
var
  nowMs: QWord;
  i: Integer;
  tokFile: string;
  fs: TFileStream;
  b: Byte;
begin
  Result := 0;
  ForceDirectories(FCfg.StateDir);
  // Private by default. With a control group (the web server's account shares the owner's group, as it does for the tmux socket today) the
  // state directory must also be SEARCHABLE by that group, or it could never reach the socket and token inside it. Only the directory opens up:
  // the token is 0640, the socket 0660 (or the configured mode), and every other file keeps the mode it was written with.
  if FCfg.CtlGroup <> '' then begin
    if GetGroupId(FCfg.CtlGroup) <> TGid(-1) then fpChown(FCfg.StateDir, TUid(-1), GetGroupId(FCfg.CtlGroup));
    fpChmod(FCfg.StateDir, &750);
  end else fpChmod(FCfg.StateDir, &700);
  ForceDirectories(FCfg.LogDir);
  AdoptConfig(FCfg, True);                             // takes ownership of the definitions the loader parsed
  LoadState;
  RecoverOrphans;
  tokFile := FCfg.StateDir + '/token';
  if not FileExists(tokFile) then
  begin
    FToken := '';
    fs := nil;
    try
      fs := TFileStream.Create('/dev/urandom', fmOpenRead or fmShareDenyNone);
      for i := 1 to 32 do begin fs.ReadBuffer(b, 1); FToken := FToken + LowerCase(IntToHex(b, 2)); end;
    except
      FToken := '';                                    // no urandom: refuse rather than invent a weak token
    end;
    fs.Free;
    if Length(FToken) <> 64 then raise Exception.Create('cannot read /dev/urandom to create a control token');
    if FCfg.CtlGroup <> '' then
    begin
      WriteFileAtomic(tokFile, FToken + #10, &640);
      if GetGroupId(FCfg.CtlGroup) <> TGid(-1) then fpChown(tokFile, TUid(-1), GetGroupId(FCfg.CtlGroup));
    end
    else WriteFileAtomic(tokFile, FToken + #10, &600);
  end;
  FToken := Trim(ReadFileString(tokFile));
  OpenControl;
  Log('aicsupervisor ' + VERSION + ' started: ' + IntToStr(FSvcs.Count) + ' services, ' + IntToStr(FJobs.Count) + ' jobs, ' + IntToStr(FGuards.Count) + ' guards; control ' + FCfg.CtlSocket);
  WriteFileAtomic(FCfg.StateDir + '/supervisor.pid', IntToStr(fpGetpid) + #10, &644);

  while not FShutdown do
  begin
    if FReload then begin FReload := False; DoReload; end;
    nowMs := GetTickCount64;
    ServicesTick(nowMs);
    JobsTick(nowMs);
    for i := 0 to FGuards.Count - 1 do TGuardRunner(FGuards[i]).Tick(nowMs);
    if FDirty then SaveState;
    ControlTick(100);                                  // also the loop's sleep
  end;

  ShutdownAll;
  if FListenFd >= 0 then fpClose(FListenFd);
  DeleteFile(FCfg.CtlSocket);
  DeleteFile(FCfg.StateDir + '/supervisor.pid');
end;

end.
