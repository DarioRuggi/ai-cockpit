(* =============================================================================
  aicserver — a small web server for AI Cockpit: static files + FastCGI (PHP), streaming, ranges, uploads.

    aicserver run   --config FILE           serve in the foreground (the supervisor keeps it alive)
    aicserver check --config FILE           validate the configuration and print what it would serve

  Binds to 127.0.0.1 by default.  SIGTERM/SIGINT: stop accepting, let open connections finish (5 s), exit.
  ============================================================================= *)
program aicserver;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, BaseUnix, srv_config, srv_tls, srv_main;

function OptVal(const Name: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 2 to ParamCount - 1 do if ParamStr(i) = Name then Exit(ParamStr(i + 1));
end;

var
  cfg: TServerConfig;
  err, cmd: string;
  i: Integer;
  m: TMount;

begin
  if ParamCount < 1 then begin WriteLn('usage: aicserver run|check --config FILE'); Halt(2); end;
  cmd := ParamStr(1);
  if (cmd = 'version') or (cmd = '--version') then begin WriteLn('aicserver 1.0.0 (run, check, version)'); Halt(0); end;
  cfg := LoadServerConfig(OptVal('--config'), err);
  if cfg = nil then begin WriteLn(StdErr, 'configuration is invalid:'); Write(StdErr, err); Halt(1); end;
  if cmd = 'check' then
  begin
    WriteLn('configuration OK');
    WriteLn('  listen ', cfg.Host, ':', cfg.Port, '   allowed hosts: ', cfg.AllowedHosts.CommaText);
    for i := 0 to cfg.Mounts.Count - 1 do
    begin
      m := TMount(cfg.Mounts[i]);
      WriteLn('  mount ', m.Prefix, '  ->  ', m.RootReal, '   index: ', m.Index.CommaText);
    end;
    WriteLn('  php: ', cfg.PhpExt.CommaText, ' -> ', cfg.FcgiAddr);
    WriteLn('  gzip: ', cfg.GzipOn);
    if cfg.TlsCert <> '' then
    begin
      if TlsInit(cfg.TlsCert, cfg.TlsKey, err) then WriteLn('  https: certificate and key load, and match')
      else begin WriteLn(StdErr, '  https: ', err); Halt(1); end;
    end;
    Halt(0);
  end;
  if cmd = 'run' then Halt(RunServer(cfg));
  WriteLn(StdErr, 'unknown command: ', cmd);
  Halt(2);
end.