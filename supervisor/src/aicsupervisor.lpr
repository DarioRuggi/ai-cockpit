(* =============================================================================
  aicsupervisor — keeps AI Cockpit's background pieces running.

    aicsupervisor run     --config FILE            run in the foreground (a service manager keeps THIS alive)
    aicsupervisor check   --config FILE            validate the configuration, print what it would do
    aicsupervisor ctl     --config FILE OP [NAME]  talk to the running supervisor:
                            status | ping | start NAME | stop NAME | restart NAME | run-job NAME |
                            signal NAME [--sig INT] [--scope children|group|leader] |
                            logs NAME [--lines N] | guard-check | reload | shutdown
                          (--socket PATH --token-file F instead of --config also works)
    aicsupervisor service-file systemd-user|systemd-system|launchd --config FILE [--binary PATH]
                                                  print the unit file that starts the supervisor at login/boot

  Signals: SIGTERM / SIGINT  stop everything in reverse start order (graceful, then SIGKILL) and exit;
           SIGHUP            re-read the configuration (a broken new file is refused, the old one stays).
  ============================================================================= *)
program aicsupervisor;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, BaseUnix, Unix, Sockets, fpjson, jsonparser,
  sup_util, sup_sched, sup_config, sup_proc, sup_guard, sup_core;

var
  GSup: TSupervisor;

{ "text" when the condition holds, else nothing (the default marks an adopted service with a star) }
function IfThen_(C: Boolean; const T: string = '*'): string;
begin
  if C then Result := T else Result := '';
end;

procedure OnTerm(Sig: cint); cdecl;
begin
  if GSup <> nil then GSup.RequestShutdown;
end;

procedure OnHup(Sig: cint); cdecl;
begin
  if GSup <> nil then GSup.RequestReload;
end;

function OptVal(const Name: string; const Def: string = ''): string;
var
  i: Integer;
begin
  Result := Def;
  for i := 2 to ParamCount - 1 do
    if ParamStr(i) = Name then Exit(ParamStr(i + 1));
end;

{ the first argument after the command that is not an option or an option's value }
function Positional(Index: Integer): string;
var
  i, n: Integer;
begin
  Result := '';
  n := 0;
  i := 2;
  while i <= ParamCount do
  begin
    if Copy(ParamStr(i), 1, 2) = '--' then Inc(i, 2)
    else begin Inc(n); if n = Index then Exit(ParamStr(i)); Inc(i); end;
  end;
end;

function Ctl(const Sock, Token, Op, Name: string; Lines: Integer; const Sig, Scope: string; out Reply: string): Boolean;
var
  fd: cint;
  addr: sockaddr_un;
  req: TJSONObject;
  s, buf: string;
  tmp: array[0..16383] of Byte;
  n: Integer;
begin
  Result := False;
  Reply := '';
  fd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  FillChar(addr, SizeOf(addr), 0);
  addr.sun_family := AF_UNIX;
  StrPCopy(addr.sun_path, Sock);
  if fpConnect(fd, @addr, SizeOf(addr)) <> 0 then begin Reply := 'cannot connect to ' + Sock + ' (is the supervisor running?)'; fpClose(fd); Exit; end;
  req := TJSONObject.Create(['token', Token, 'op', Op, 'name', Name, 'lines', Lines]);
  if Sig <> '' then req.Add('sig', Sig);
  if Scope <> '' then req.Add('scope', Scope);
  s := req.FormatJSON([foSingleLineArray, foSingleLineObject, foSkipWhiteSpace], 0) + #10;
  req.Free;
  fpWrite(fd, s[1], Length(s));
  buf := '';
  repeat
    n := fpRead(fd, tmp, SizeOf(tmp));
    if n > 0 then begin SetString(s, PChar(@tmp[0]), n); buf := buf + s; end;
  until (n <= 0) or (Pos(#10, buf) > 0);
  fpClose(fd);
  Reply := Trim(buf);
  Result := Reply <> '';
end;

procedure PrintStatus(const Reply: string);
var
  d: TJSONData;
  o: TJSONObject;
  a: TJSONArray;
  i: Integer;
  x: TJSONObject;
  h: string;
begin
  d := GetJSON(Reply);
  try
    o := TJSONObject(d);
    if not o.Get('ok', False) then begin WriteLn('error: ', o.Get('error', '?')); Exit; end;
    WriteLn('aicsupervisor ', o.Get('version', ''), '  pid ', o.Get('pid', 0), '  up ', o.Get('uptime_s', 0), ' s');
    WriteLn;
    WriteLn(Format('%-18s %-9s %-7s %-8s %-9s %s', ['service', 'state', 'pid', 'health', 'restarts', 'last exit']));
    a := o.Get('services', TJSONArray(nil));
    if a <> nil then
      for i := 0 to a.Count - 1 do
      begin
        x := TJSONObject(a[i]);
        case x.Get('healthy', -1) of 1: h := 'ok'; 0: h := 'BAD'; else h := '-'; end;
        WriteLn(Format('%-18s %-9s %-7s %-8s %-9d %s', [x.Get('name', ''), x.Get('state', '') + IfThen_(x.Get('adopted', False)), IntToStr(x.Get('pid', 0)),
          h, x.Get('restarts', 0), x.Get('last_exit', '') + ' ' + x.Get('reason', '')]));
      end;
    WriteLn;
    WriteLn(Format('%-18s %-18s %-8s %-7s %-6s %s', ['job', 'schedule', 'status', 'runs', 'skipd', 'next due']));
    a := o.Get('jobs', TJSONArray(nil));
    if a <> nil then
      for i := 0 to a.Count - 1 do
      begin
        x := TJSONObject(a[i]);
        WriteLn(Format('%-18s %-18s %-8s %-7d %-6d %s', [x.Get('name', ''), x.Get('schedule', ''), x.Get('last_status', ''), x.Get('runs', 0), x.Get('skipped', 0), x.Get('next_due', '')]));
      end;
    a := o.Get('guards', TJSONArray(nil));
    if (a <> nil) and (a.Count > 0) then
    begin
      WriteLn;
      WriteLn(Format('%-18s %-7s %-7s %-11s %s', ['guard', 'files', 'checks', 'violations', 'restored']));
      for i := 0 to a.Count - 1 do
      begin
        x := TJSONObject(a[i]);
        WriteLn(Format('%-18s %-7d %-7d %-11d %d', [x.Get('name', ''), x.Get('files', 0), x.Get('checks', 0), x.Get('violations', 0), x.Get('restored', 0)]));
      end;
    end;
  finally
    d.Free;
  end;
end;

procedure PrintServiceFile(const Kind, Cfg, Bin: string);
var
  b: string;
begin
  b := Bin;
  if b = '' then b := ExpandFileName(ParamStr(0));
  if Kind = 'systemd-user' then
  begin
    WriteLn('# ~/.config/systemd/user/aicockpit-supervisor.service   (systemctl --user enable --now aicockpit-supervisor)');
    WriteLn('[Unit]');
    WriteLn('Description=AI Cockpit supervisor (engine, jobs, guard)');
    WriteLn('After=network.target');
    WriteLn;
    WriteLn('[Service]');
    WriteLn('Type=simple');
    WriteLn('ExecStart=', b, ' run --config ', Cfg);
    WriteLn('ExecReload=/bin/kill -HUP $MAINPID');
    WriteLn('Restart=on-failure');
    WriteLn('RestartSec=3');
    WriteLn('# the supervisor stops its children itself, in order; only SIGTERM it, and give it time');
    WriteLn('KillMode=mixed');
    WriteLn('TimeoutStopSec=60');
    WriteLn;
    WriteLn('[Install]');
    WriteLn('WantedBy=default.target');
  end
  else if Kind = 'systemd-system' then
  begin
    WriteLn('# /etc/systemd/system/aicockpit-supervisor.service   (run as a dedicated unprivileged user)');
    WriteLn('[Unit]');
    WriteLn('Description=AI Cockpit supervisor (engine, jobs, guard)');
    WriteLn('After=network.target');
    WriteLn;
    WriteLn('[Service]');
    WriteLn('Type=simple');
    WriteLn('User=aicockpit');
    WriteLn('ExecStart=', b, ' run --config ', Cfg);
    WriteLn('ExecReload=/bin/kill -HUP $MAINPID');
    WriteLn('Restart=on-failure');
    WriteLn('RestartSec=3');
    WriteLn('KillMode=mixed');
    WriteLn('TimeoutStopSec=60');
    WriteLn('NoNewPrivileges=true');
    WriteLn('ProtectSystem=full');
    WriteLn;
    WriteLn('[Install]');
    WriteLn('WantedBy=multi-user.target');
  end
  else if Kind = 'launchd' then
  begin
    WriteLn('<?xml version="1.0" encoding="UTF-8"?>');
    WriteLn('<!-- ~/Library/LaunchAgents/site.aicockpit.supervisor.plist   (launchctl load -w <file>) -->');
    WriteLn('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">');
    WriteLn('<plist version="1.0"><dict>');
    WriteLn('  <key>Label</key><string>site.aicockpit.supervisor</string>');
    WriteLn('  <key>ProgramArguments</key><array><string>', b, '</string><string>run</string><string>--config</string><string>', Cfg, '</string></array>');
    WriteLn('  <key>RunAtLoad</key><true/>');
    WriteLn('  <key>KeepAlive</key><true/>');
    WriteLn('  <key>StandardErrorPath</key><string>/tmp/aicockpit-supervisor.log</string>');
    WriteLn('</dict></plist>');
  end
  else begin WriteLn(StdErr, 'service-file kinds: systemd-user | systemd-system | launchd   (Windows: not yet available)'); Halt(2); end;
end;

var
  cmd, cfgFile, err, reply, sock, tokFile, tok, op, name: string;
  Cfg: TSupConfig;
  i: Integer;
  sd: TServiceDef;
  jd: TJobDef;
  gd: TGuardDef;
  d: TJSONData;

begin
  Randomize;
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  if ParamCount < 1 then
  begin
    WriteLn('usage: aicsupervisor run|check|ctl|service-file --config FILE ...');
    Halt(2);
  end;
  cmd := ParamStr(1);
  cfgFile := OptVal('--config');

  if cmd = 'service-file' then begin PrintServiceFile(ParamStr(2), ExpandFileName(cfgFile), OptVal('--binary')); Halt(0); end;

  if (cmd = 'run') or (cmd = 'check') then
  begin
    if cfgFile = '' then begin WriteLn(StdErr, cmd, ' needs --config FILE'); Halt(2); end;
    Cfg := LoadConfig(cfgFile, err);
    if Cfg = nil then begin WriteLn(StdErr, 'configuration is invalid:'); Write(StdErr, err); Halt(1); end;
    if cmd = 'check' then
    begin
      WriteLn('configuration OK: ', Cfg.ConfigFile);
      WriteLn('  state ', Cfg.StateDir, '   logs ', Cfg.LogDir, '   control ', Cfg.CtlSocket);
      WriteLn('  services, in start order:');
      for i := 0 to Cfg.Services.Count - 1 do
      begin
        sd := TServiceDef(Cfg.Services[i]);
        WriteLn('    ', sd.Name, '  restart=', sd.Restart, '  health=', sd.Health.Kind, IfThen_(sd.StartAfter.Count > 0, '  after ' + sd.StartAfter.CommaText), IfThen_(sd.AdoptIfHealthy, '  adopt-if-healthy'));
      end;
      WriteLn('  jobs:');
      for i := 0 to Cfg.Jobs.Count - 1 do
      begin
        jd := TJobDef(Cfg.Jobs[i]);
        WriteLn('    ', jd.Name, '  ', ScheduleToText(jd.Sched), '  timeout ', jd.TimeoutS, ' s', IfThen_(jd.Persistent, '  persistent'), '  overlap=', jd.Overlap);
      end;
      WriteLn('  guards:');
      for i := 0 to Cfg.Guards.Count - 1 do
      begin
        gd := TGuardDef(Cfg.Guards[i]);
        WriteLn('    ', gd.Name, '  root ', gd.Root, '  every ', gd.IntervalS, ' s  restore=', gd.Restore);
      end;
      Halt(0);
    end;
    GSup := TSupervisor.Create(Cfg);
    fpSignal(SIGTERM, @OnTerm);
    fpSignal(SIGINT, @OnTerm);
    fpSignal(SIGHUP, @OnHup);
    try
      Halt(GSup.Run);
    except
      on E: Exception do begin WriteLn(StdErr, 'aicsupervisor: ', E.Message); Halt(1); end;
    end;
  end;

  if cmd = 'ctl' then
  begin
    sock := OptVal('--socket'); tokFile := OptVal('--token-file');
    if cfgFile <> '' then
    begin
      Cfg := LoadConfig(cfgFile, err);
      if Cfg = nil then begin WriteLn(StdErr, err); Halt(1); end;
      if sock = '' then sock := Cfg.CtlSocket;
      if tokFile = '' then tokFile := Cfg.StateDir + '/token';
    end;
    if (sock = '') or (tokFile = '') then begin WriteLn(StdErr, 'ctl needs --config FILE (or --socket and --token-file)'); Halt(2); end;
    tok := Trim(ReadFileString(tokFile));
    op := StringReplace(Positional(1), '-', '_', [rfReplaceAll]);
    name := Positional(2);
    if op = '' then begin WriteLn(StdErr, 'ctl needs an operation'); Halt(2); end;
    if not Ctl(sock, tok, op, name, StrToIntDef(OptVal('--lines'), 50), OptVal('--sig'), OptVal('--scope'), reply) then begin WriteLn(StdErr, reply); Halt(1); end;
    if op = 'status' then PrintStatus(reply)
    else if op = 'logs' then
    begin
      d := GetJSON(reply);
      if TJSONObject(d).Get('ok', False) then Write(TJSONObject(d).Get('text', '')) else begin WriteLn(StdErr, TJSONObject(d).Get('error', '?')); Halt(1); end;
    end
    else
    begin
      WriteLn(reply);
      d := GetJSON(reply);
      if not TJSONObject(d).Get('ok', False) then Halt(1);
    end;
    Halt(0);
  end;

  WriteLn(StdErr, 'unknown command: ', cmd);
  Halt(2);
end.
