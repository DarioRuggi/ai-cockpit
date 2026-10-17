(* =============================================================================
  aic_service — `aicengine serve`: the control API over a Unix socket.

  WHY a service: PHP (Cockpit's backend) must start agents, stream their output to a browser, cancel
  them and ask what is running — without tmux, without queue/ and responses/ files, without sudo.  PHP
  connects to this socket and speaks one JSON object per line.

  PROTOCOL (all lines are UTF-8 JSON objects; a client sends ONE request line per connection)

    request    {"token":"...","op":"run","adapter":"claude","request":{...}}
    response   {"type":"response","ok":true,...}        for every operation except a run that started
    events     {"type":"start",...} ... {"type":"done",...}     the run's event stream, then the server closes

    ops:  ping   adapters   detect   status   sessions   session_clear   cancel   run   fs   exec   sandbox
    run request fields (all optional except prompt/messages): prompt system messages model session chat cwd
      tier timeout_s max_output_kb env{K:V} record
      A `chat` name with no `session` resumes that chat's conversation (see aic_sessions).

  PROCESS MODEL — one forked child per connection.  The accept loop never runs an agent; each connection
  becomes its own process running the same single-threaded runner the CLI uses (already tested).  So:
    * a crashed or runaway run cannot take the service down;
    * cancel is a signal to that child (SIGTERM -> the runner kills the agent's whole tree, emits
      `cancelled` and `done`);
    * a CLIENT THAT DISCONNECTS CANCELS ITS RUN (a closed browser tab must not leave an agent running);
    * no threads, so fork() is safe.

  SECURITY (local only, see also the spec's section 11)
    * the socket is a file: mode and group are options (0600 by default; 0660 + group www-data while PHP
      runs as www-data), and nothing listens on TCP at all;
    * every request must carry the per-install TOKEN (a random 256-bit value in a file whose mode is 0600,
      or 0640 with a group); compared in constant time; a wrong token is answered after a short delay;
    * `cwd` must lie under one of --allowed-roots when that option is given (symlinks resolved);
    * request `env` may not set LD_*, DYLD_*, BASH_ENV, ENV, IFS;
    * limits: request size, concurrent runs, idle time before a request line arrives.
  ============================================================================= *)
unit aic_service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils, Classes, BaseUnix, Unix, Sockets, Users, fpjson, jsonparser,
  aic_events, aic_adapter, aic_run, aic_proc, aic_http, aic_sessions, aic_fs, aic_exec;

type
  TServiceOptions = record
    SocketPath: string;
    StateDir: string;
    TokenFile: string;
    AdaptersDir: string;
    SocketMode: Integer;        // octal value, e.g. &660
    SocketGroup: string;
    AllowedRoots: TStringList;  // empty = any directory
    MaxRuns: Integer;
    MaxRequestBytes: Integer;
    ReadTimeoutMs: Integer;     // how long a client may take to send its request line
  end;

function ServeForever(var O: TServiceOptions): Integer;

implementation

const
  ENGINE_VERSION = '0.2.0';
  FD_CLOEXEC = 1;                     // fcntl(F_SETFD): not exported by FPC's BaseUnix; the value is 1 on Linux and macOS

var
  GShutdown: Boolean;
  GChildRunner: TRunner;       // set only inside a forked child, so a signal can cancel its run

{ ---- tiny helpers ------------------------------------------------------------------------------- }

function c_realpath(path, resolved: PChar): PChar; cdecl; external 'c' name 'realpath';

function RealPathOf(const P: string): string;
var
  buf: array[0..4095] of Char;
begin
  FillChar(buf, SizeOf(buf), 0);
  if c_realpath(PChar(P), @buf[0]) = nil then Result := '' else Result := StrPas(@buf[0]);
end;

function WriteAll(fd: cint; const S: string): Boolean;
var
  p, n: Integer;
begin
  Result := True;
  p := 1;
  while p <= Length(S) do
  begin
    n := fpWrite(fd, S[p], Length(S) - p + 1);
    if n < 0 then
    begin
      if fpGetErrno = ESysEINTR then Continue;
      Exit(False);                                      // EPIPE etc: the client is gone
    end;
    Inc(p, n);
  end;
end;

function ConstTimeEq(const A, B: string): Boolean;
var
  i, d: Integer;
begin
  d := Length(A) xor Length(B);
  for i := 1 to Length(A) do
    if i <= Length(B) then d := d or (Ord(A[i]) xor Ord(B[i]));
  Result := d = 0;
end;

function RandomToken: string;
var
  f: file of Byte;
  b: array[0..31] of Byte;
  i: Integer;
begin
  FillChar(b, SizeOf(b), 0);
  AssignFile(f, '/dev/urandom');
  {$I-} Reset(f); {$I+}
  if IOResult = 0 then begin BlockRead(f, b, SizeOf(b)); CloseFile(f); end
  else for i := 0 to 31 do b[i] := Random(256);          // never reached on Linux/macOS
  Result := '';
  for i := 0 to 31 do Result := Result + LowerCase(IntToHex(b[i], 2));
end;

function ReadWholeFile(const F: string): string;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.LoadFromFile(F);
    Result := Trim(sl.Text);
  finally
    sl.Free;
  end;
end;

procedure Respond(fd: cint; Fields: TJSONObject);
var
  o: TJSONObject;
  i: Integer;
begin
  o := TJSONObject.Create;
  try
    o.Add('type', 'response');
    for i := 0 to Fields.Count - 1 do o.Add(Fields.Names[i], Fields.Items[i].Clone);
    WriteAll(fd, o.FormatJSON([foSingleLineArray, foSingleLineObject, foSkipWhiteSpace], 0) + #10);
  finally
    o.Free;
    Fields.Free;
  end;
end;

procedure Fail(fd: cint; const Msg: string);
begin
  Respond(fd, TJSONObject.Create(['ok', False, 'error', Msg]));
end;

{ ---- run registry: one small file per live run ------------------------------------------------- }

function RunsDir(const O: TServiceOptions): string;
begin
  Result := IncludeTrailingPathDelimiter(O.StateDir) + 'runs';
end;

procedure WriteRunFile(const O: TServiceOptions; const RunId, Adapter, Chat: string);
var
  sl: TStringList;
begin
  ForceDirectories(RunsDir(O));
  sl := TStringList.Create;
  try
    sl.Add(IntToStr(fpGetpid));
    sl.Add(Adapter);
    sl.Add(IntToStr(DateTimeToUnix(Now)));
    sl.Add(Chat);
    // atomic: another connection may be listing this folder right now and must never see a half-written file
    sl.SaveToFile(RunsDir(O) + '/' + RunId + '.tmp');
    RenameFile(RunsDir(O) + '/' + RunId + '.tmp', RunsDir(O) + '/' + RunId + '.run');
  finally
    sl.Free;
  end;
end;

function RunChat(sl: TStringList): string;
begin
  if sl.Count >= 4 then Result := sl[3] else Result := '';
end;

{ Live runs as a JSON array; stale files (the process is gone) are removed on the way. }
function ListRuns(const O: TServiceOptions; out Count: Integer): TJSONArray;
var
  sr: TSearchRec;
  sl: TStringList;
  pid: Integer;
  rid: string;
begin
  Result := TJSONArray.Create;
  Count := 0;
  if FindFirst(RunsDir(O) + '/*.run', faAnyFile, sr) = 0 then
  begin
    repeat
      rid := ChangeFileExt(sr.Name, '');
      sl := TStringList.Create;
      try
        try sl.LoadFromFile(RunsDir(O) + '/' + sr.Name); except sl.Clear; end;
        if sl.Count < 3 then Continue;            // unreadable / not complete yet: never delete what we cannot judge
        pid := StrToIntDef(sl.Strings[0], 0);
        if (pid > 1) and (fpKill(pid, 0) = 0) then
        begin
          Result.Add(TJSONObject.Create(['run_id', rid, 'pid', pid, 'adapter', sl[1], 'started', StrToInt64Def(sl[2], 0),
            'chat', RunChat(sl)]));
          Inc(Count);
        end
        else DeleteFile(RunsDir(O) + '/' + sr.Name);
      finally
        sl.Free;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ ---- request validation ------------------------------------------------------------------------ }

function EnvKeyAllowed(const K: string): Boolean;
var
  u: string;
  i: Integer;
begin
  u := UpperCase(K);
  Result := (K <> '') and (Pos('=', K) = 0);
  if not Result then Exit;
  for i := 1 to Length(K) do
    if not (K[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then Exit(False);
  if (Copy(u, 1, 3) = 'LD_') or (Copy(u, 1, 5) = 'DYLD_') or (u = 'BASH_ENV') or (u = 'ENV') or (u = 'IFS') then Result := False;
end;

function CwdAllowed(const O: TServiceOptions; const Cwd: string; out Err: string): Boolean;
var
  rp, root: string;
  i: Integer;
begin
  Err := '';
  if Cwd = '' then Exit(True);
  rp := RealPathOf(Cwd);
  if (rp = '') or not DirectoryExists(rp) then begin Err := 'cwd does not exist: ' + Cwd; Exit(False); end;
  if O.AllowedRoots.Count = 0 then Exit(True);
  for i := 0 to O.AllowedRoots.Count - 1 do
  begin
    root := RealPathOf(O.AllowedRoots[i]);
    if root = '' then Continue;
    if (rp = root) or (Copy(rp, 1, Length(root) + 1) = IncludeTrailingPathDelimiter(root)) then Exit(True);
  end;
  Err := 'cwd is outside the allowed roots';
  Result := False;
end;

{ ---- the sink for one run: event lines go to the client; a dead client cancels the run ----------- }

type
  TSocketSink = class
    Fd: cint;
    Dead: Boolean;
    Runner: TRunner;
    procedure Write(const Line: string);
    function Gone: Boolean;
  end;

{ Has the client closed its end?  A peek that returns 0 bytes is EOF.  The client never sends anything after
  its request line, so any byte or EAGAIN means "still there".  This catches an IDLE run (an agent that is
  thinking and printing nothing), where a failed write would never reveal the disconnect. }
function TSocketSink.Gone: Boolean;
var
  b: Byte;
  n: TSsize;
begin
  if Dead then Exit(True);
  n := fpRecv(Fd, @b, 1, MSG_PEEK or MSG_DONTWAIT);
  if n = 0 then Dead := True
  else if (n < 0) and (fpGetErrno <> ESysEAGAIN) and (fpGetErrno <> ESysEINTR) then Dead := True;
  Result := Dead;
end;

procedure TSocketSink.Write(const Line: string);
begin
  if Dead then Exit;
  if not WriteAll(Fd, Line + #10) then
  begin
    Dead := True;
    if Assigned(Runner) then Runner.Cancel;        // nobody is listening: stop the agent and its tree
  end;
end;

{ The child's signal handler: SIGTERM/SIGINT = cancel this run (the runner then emits cancelled + done). }
procedure OnChildSignal(Sig: cint); cdecl;
begin
  if Assigned(GChildRunner) then GChildRunner.Cancel;
end;

{ ---- one connection ---------------------------------------------------------------------------- }

function ReadRequestLine(fd: cint; MaxBytes, TimeoutMs: Integer; out Line: string; out Err: string): Boolean;
var
  pfd: TPollFd;
  buf: array[0..16383] of Byte;
  n, rc: Integer;
  s: string;
  deadline: QWord;
begin
  Result := False;
  Line := '';
  Err := '';
  deadline := GetTickCount64 + QWord(TimeoutMs);
  while True do
  begin
    if GetTickCount64 > deadline then begin Err := 'timed out waiting for the request line'; Exit; end;
    pfd.fd := fd; pfd.events := POLLIN; pfd.revents := 0;
    rc := fpPoll(@pfd, 1, 200);
    if rc < 0 then begin if fpGetErrno = ESysEINTR then Continue; Err := 'poll failed'; Exit; end;
    if rc = 0 then Continue;
    n := fpRead(fd, buf, SizeOf(buf));
    if n <= 0 then begin Err := 'connection closed before a complete request'; Exit; end;
    SetString(s, PChar(@buf[0]), n);
    Line := Line + s;
    if Length(Line) > MaxBytes then begin Err := 'request too large'; Exit; end;
    if Pos(#10, Line) > 0 then
    begin
      Line := Copy(Line, 1, Pos(#10, Line) - 1);
      Exit(True);
    end;
  end;
end;

procedure HandleConnection(fd: cint; var O: TServiceOptions; Ads: TAdapterList; Sessions: TSessionStore; const Token: string);
var
  line, err, op, adapterId, chat, sess, rid: string;
  doc: TJSONData;
  req, rq, envo: TJSONObject;
  Ad: TAdapter;
  Req0: TRunRequest;
  i, live: Integer;
  runs: TJSONArray;
  arr: TJSONArray;
  Sink: TSocketSink;
  Em: TEventEmitter;
  Rn: TRunner;
  tiers: TJSONArray;
  extra: TStringList;
  rawFile: string;
  b: string;
  zs: TJSONArray;
begin
  if not ReadRequestLine(fd, O.MaxRequestBytes, O.ReadTimeoutMs, line, err) then begin Fail(fd, err); Exit; end;
  try
    doc := GetJSON(line);
  except
    Fail(fd, 'the request is not valid JSON'); Exit;
  end;
  if doc.JSONType <> jtObject then begin doc.Free; Fail(fd, 'the request must be a JSON object'); Exit; end;
  req := TJSONObject(doc);
  try
    if not ConstTimeEq(req.Get('token', ''), Token) then
    begin
      Sleep(150);                                  // a wrong guess costs time
      Fail(fd, 'unauthorized'); Exit;
    end;
    op := req.Get('op', '');

    if op = 'ping' then
    begin
      ListRuns(O, live).Free;
      Respond(fd, TJSONObject.Create(['ok', True, 'version', ENGINE_VERSION, 'pid', Int64(fpGetppid), 'runs', live]));
    end
    else if op = 'adapters' then
    begin
      arr := TJSONArray.Create;
      for i := 0 to Ads.Count - 1 do
      begin
        tiers := TJSONArray.Create;
        if Ads[i].TierSupported('read_only') then tiers.Add('read_only');
        if Ads[i].TierSupported('edit') then tiers.Add('edit');
        if Ads[i].TierSupported('shell') then tiers.Add('shell');
        arr.Add(TJSONObject.Create(['id', Ads[i].Id, 'display', Ads[i].Display, 'kind', Ads[i].Kind,
          'transport', Ads[i].Transport, 'tiers', tiers]));
      end;
      Respond(fd, TJSONObject.Create(['ok', True, 'adapters', arr]));
    end
    else if op = 'detect' then
    begin
      arr := TJSONArray.Create;
      for i := 0 to Ads.Count - 1 do
      begin
        if Ads[i].Transport = 'http' then
        begin
          b := '';
          arr.Add(TJSONObject.Create(['id', Ads[i].Id, 'ready',
            HttpGetStatus(Ads[i].Doc.Get('detect_url', Ads[i].Url), 1200, b) = 200]));
        end
        else
          arr.Add(TJSONObject.Create(['id', Ads[i].Id, 'ready',
            FindInPath(Ads[i].Command, GetEnvironmentVariable('PATH')) <> '',
            'path', FindInPath(Ads[i].Command, GetEnvironmentVariable('PATH'))]));
      end;
      Respond(fd, TJSONObject.Create(['ok', True, 'detect', arr]));
    end
    else if op = 'status' then
    begin
      runs := ListRuns(O, live);
      Respond(fd, TJSONObject.Create(['ok', True, 'version', ENGINE_VERSION, 'live_runs', live, 'max_runs', O.MaxRuns, 'runs', runs]));
    end
    else if op = 'sessions' then
    begin
      Respond(fd, TJSONObject.Create(['ok', True, 'sessions', GetJSON(Sessions.AsJson)]));
    end
    else if op = 'session_clear' then
    begin
      Sessions.Clear(req.Get('adapter', ''), req.Get('chat', ''));
      Respond(fd, TJSONObject.Create(['ok', True]));
    end
    else if op = 'cancel' then
    begin
      rid := req.Get('run_id', '');
      runs := ListRuns(O, live);
      try
        b := 'false';
        for i := 0 to runs.Count - 1 do
          if TJSONObject(runs[i]).Get('run_id', '') = rid then
          begin
            fpKill(TJSONObject(runs[i]).Get('pid', 0), SIGTERM);     // the child cancels cleanly and says so
            b := 'true';
          end;
      finally
        runs.Free;
      end;
      Respond(fd, TJSONObject.Create(['ok', True, 'found', b = 'true']));
    end
    else if op = 'run' then
    begin
      adapterId := req.Get('adapter', '');
      Ad := Ads.Find(adapterId);
      if Ad = nil then begin Fail(fd, 'no such adapter: ' + adapterId); Exit; end;
      rq := req.Get('request', TJSONObject(nil));
      if rq = nil then begin Fail(fd, 'missing "request"'); Exit; end;

      FillChar(Req0, SizeOf(Req0), 0);
      Req0.Prompt := rq.Get('prompt', '');
      Req0.System := rq.Get('system', '');
      if rq.Find('messages') <> nil then
      begin
        if rq.Find('messages').JSONType = jtArray then Req0.Messages := rq.Find('messages').AsJSON
        else Req0.Messages := rq.Get('messages', '');
      end;
      Req0.Model := rq.Get('model', '');
      Req0.Cwd := rq.Get('cwd', '');
      Req0.Tier := rq.Get('tier', '');
      Req0.TimeoutS := rq.Get('timeout_s', 0);
      Req0.MaxOutputKB := rq.Get('max_output_kb', 0);
      chat := rq.Get('chat', '');
      sess := rq.Get('session', '');
      if (sess = '') and (chat <> '') then sess := Sessions.Get(Ad.Id, chat);
      Req0.SessionId := sess;

      if not CwdAllowed(O, Req0.Cwd, err) then begin Fail(fd, err); Exit; end;
      extra := TStringList.Create;
      try
        envo := rq.Get('env', TJSONObject(nil));
        if envo <> nil then
          for i := 0 to envo.Count - 1 do
          begin
            if not EnvKeyAllowed(envo.Names[i]) then begin Fail(fd, 'environment variable not allowed: ' + envo.Names[i]); Exit; end;
            extra.Add(envo.Names[i] + '=' + envo.Items[i].AsString);
          end;

        ListRuns(O, live).Free;
        if live >= O.MaxRuns then begin Fail(fd, 'busy: ' + IntToStr(live) + ' runs are already active (limit ' + IntToStr(O.MaxRuns) + ')'); Exit; end;

        Sink := TSocketSink.Create;
        Sink.Fd := fd;
        rid := NewRunId;
        Em := TEventEmitter.Create(rid, @Sink.Write);
        Rn := TRunner.Create(Em);
        Sink.Runner := Rn;
        Rn.ClientGone := @Sink.Gone;
        Rn.ExtraEnv := extra;
        GChildRunner := Rn;
        fpSignal(SIGTERM, @OnChildSignal);
        fpSignal(SIGINT, @OnChildSignal);
        try
          if rq.Get('record', False) then
          begin
            ForceDirectories(IncludeTrailingPathDelimiter(O.StateDir) + 'raw');
            rawFile := IncludeTrailingPathDelimiter(O.StateDir) + 'raw/' + rid + '.jsonl';
            Rn.RecordFile := rawFile;
          end;
          WriteRunFile(O, rid, Ad.Id, chat);
          try
            Rn.Run(Ad, Req0);
          finally
            DeleteFile(RunsDir(O) + '/' + rid + '.run');
          end;
          if (chat <> '') and (Rn.LastSessionId <> '') then Sessions.Put(Ad.Id, chat, Rn.LastSessionId);
        finally
          GChildRunner := nil;
          Rn.Free; Em.Free; Sink.Free;
        end;
      finally
        extra.Free;
      end;
    end
    else if (op = 'fs') or (op = 'exec') or (op = 'sandbox') then
    begin
      // the file window and the command window (aic_fs, aic_exec). The caller names the zones; a READ-WRITE zone must lie under an allowed root,
      // and a read-only area must be owned by this account (checked in aic_fs).
      if op = 'sandbox' then
      begin
        Respond(fd, TJSONObject.Create(['ok', True, 'abi', SandboxAbi])); Exit;
      end;
      zs := req.Get('zones', TJSONArray(nil));
      if zs = nil then begin Fail(fd, 'missing "zones"'); Exit; end;
      for i := 0 to zs.Count - 1 do
        if (zs.Items[i].JSONType = jtObject) and TJSONObject(zs.Items[i]).Get('rw', False) then
        begin
          ForceDirectories(TJSONObject(zs.Items[i]).Get('path', ''));
          if not CwdAllowed(O, TJSONObject(zs.Items[i]).Get('path', ''), err) then begin Fail(fd, 'the Public folder is outside the allowed roots: ' + err); Exit; end;
        end;
      if op = 'fs' then Respond(fd, FsHandle(req)) else Respond(fd, ExecHandle(req));
    end
    else
      Fail(fd, 'unknown op: ' + op);
  finally
    req.Free;
  end;
end;

{ ---- the accept loop --------------------------------------------------------------------------- }

procedure OnParentSignal(Sig: cint); cdecl;
begin
  GShutdown := True;
end;

function MakeListener(var O: TServiceOptions; out Err: string): cint;
var
  fd: cint;
  addr: sockaddr_un;
  gid: TGid;
  probe: cint;
begin
  Result := -1;
  Err := '';
  if Length(O.SocketPath) > 100 then begin Err := 'socket path too long (limit about 100 bytes)'; Exit; end;

  // a stale socket file from a crashed server must not block startup, but a LIVE server must not be stolen
  if FileExists(O.SocketPath) then
  begin
    probe := fpSocket(AF_UNIX, SOCK_STREAM, 0);
    FillChar(addr, SizeOf(addr), 0);
    addr.sun_family := AF_UNIX;
    StrPCopy(addr.sun_path, O.SocketPath);
    if fpConnect(probe, @addr, SizeOf(addr)) = 0 then
    begin
      fpClose(probe);
      Err := 'another aicengine is already serving ' + O.SocketPath;
      Exit;
    end;
    fpClose(probe);
    DeleteFile(O.SocketPath);
  end;

  fd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if fd < 0 then begin Err := 'socket() failed'; Exit; end;
  FillChar(addr, SizeOf(addr), 0);
  addr.sun_family := AF_UNIX;
  StrPCopy(addr.sun_path, O.SocketPath);
  fpUmask(&077);                                   // created closed; opened up below only as far as asked
  if fpBind(fd, @addr, SizeOf(addr)) <> 0 then begin Err := 'bind failed for ' + O.SocketPath; fpClose(fd); Exit; end;
  if O.SocketGroup <> '' then
  begin
    gid := GetGroupId(O.SocketGroup);
    if gid = TGid(-1) then begin Err := 'no such group: ' + O.SocketGroup; fpClose(fd); Exit; end;
    fpChown(O.SocketPath, TUid(-1), gid);
  end;
  fpChmod(O.SocketPath, O.SocketMode);
  if fpListen(fd, 64) <> 0 then begin Err := 'listen failed'; fpClose(fd); Exit; end;
  fpFcntl(fd, F_SETFD, FD_CLOEXEC);          // an agent must never inherit the control socket
  Result := fd;
end;

function ServeForever(var O: TServiceOptions): Integer;
var
  lfd, cfd, tfd: cint;
  err, token: string;
  Ads: TAdapterList;
  Sessions: TSessionStore;
  pid: TPid;
  addr: sockaddr_un;
  alen: TSockLen;
  runs: TJSONArray;
  i, live: Integer;
  gid: TGid;
begin
  Result := 0;
  ForceDirectories(O.StateDir);
  fpChmod(O.StateDir, &700);
  ForceDirectories(RunsDir(O));

  // token: created once, kept across restarts, readable only by the owner (and the group, if one is given)
  if O.TokenFile = '' then O.TokenFile := IncludeTrailingPathDelimiter(O.StateDir) + 'token';
  if not FileExists(O.TokenFile) then
  begin
    token := RandomToken;
    with TStringList.Create do
    try
      Add(token);
      SaveToFile(O.TokenFile);
    finally
      Free;
    end;
    if O.SocketGroup <> '' then
    begin
      gid := GetGroupId(O.SocketGroup);
      if gid <> TGid(-1) then fpChown(O.TokenFile, TUid(-1), gid);
      fpChmod(O.TokenFile, &640);
    end
    else fpChmod(O.TokenFile, &600);
  end;
  token := ReadWholeFile(O.TokenFile);

  Ads := TAdapterList.Create;
  Ads.LoadDir(O.AdaptersDir);
  Sessions := TSessionStore.Create(IncludeTrailingPathDelimiter(O.StateDir) + 'sessions.json');

  lfd := MakeListener(O, err);
  if lfd < 0 then begin WriteLn(StdErr, 'aicengine serve: ', err); Exit(1); end;

  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  fpSignal(SIGTERM, @OnParentSignal);
  fpSignal(SIGINT, @OnParentSignal);
  fpSignal(SIGCHLD, SignalHandler(SIG_IGN));       // finished connection children are reaped automatically
  WriteLn(StdErr, 'aicengine ', ENGINE_VERSION, ' serving ', O.SocketPath, '  (', Ads.Count, ' adapters, state ', O.StateDir, ')');
  Flush(StdErr);

  while not GShutdown do
  begin
    alen := SizeOf(addr);
    cfd := fpAccept(lfd, @addr, @alen);
    if cfd < 0 then
    begin
      if (fpGetErrno = ESysEINTR) or (fpGetErrno = ESysEAGAIN) then Continue;
      Break;
    end;
    fpFcntl(cfd, F_SETFD, FD_CLOEXEC);        // ...nor the client's connection (it could write into another run's stream)
    pid := fpFork;
    if pid = 0 then
    begin
      // ---- child: owns this connection only ----
      fpClose(lfd);
      fpSignal(SIGCHLD, SignalHandler(SIG_DFL));    // the runner must be able to wait() for the agent it starts
      fpSignal(SIGTERM, SignalHandler(SIG_DFL));
      fpSignal(SIGINT, SignalHandler(SIG_DFL));
      try
        HandleConnection(cfd, O, Ads, Sessions, token);
      except
        on E: Exception do begin try Fail(cfd, 'internal error: ' + E.Message); except end; end;
      end;
      fpShutdown(cfd, 2);
      fpClose(cfd);
      FpExit(0);
    end
    else
      fpClose(cfd);                                 // parent: the child has its own copy
  end;

  // ---- shutdown: ask every live run to cancel (each child kills its agent's tree), then clean up ----
  WriteLn(StdErr, 'aicengine: shutting down');
  runs := ListRuns(O, live);
  try
    for i := 0 to runs.Count - 1 do fpKill(TJSONObject(runs[i]).Get('pid', 0), SIGTERM);
  finally
    runs.Free;
  end;
  Sleep(600);
  fpClose(lfd);
  DeleteFile(O.SocketPath);
  Ads.Free;
  Sessions.Free;
end;

end.
