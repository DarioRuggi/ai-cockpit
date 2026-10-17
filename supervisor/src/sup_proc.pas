(* =============================================================================
  sup_proc — starting, watching and killing processes (Unix).

    SpawnProcess   fork + exec in a NEW SESSION (own process group), stdin from /dev/null, stdout and stderr
                   appended to a log file.  Returns the pid, or -1 with Err filled.  No shell, ever.
    PollChild      non-blocking waitpid: has it ended, and how (exit code or killed by signal)?
    KillTree       signal the whole group (a service that spawned helpers leaves none behind)
    ForkProbe      run a small check (connect to a port / socket, GET a URL) in a forked child that exits 0
                   (healthy) or 1; the supervisor only watches its pid, so a probe that hangs on a dead
                   service can be killed at its timeout and can never stall the supervisor's own loop.

  Windows needs the same contract with CreateProcess + job objects: a separate unit, same interface.
  ============================================================================= *)
unit sup_proc;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, Unix, Sockets;

type
  TChildEnd = record
    Ended: Boolean;
    ExitCode: Integer;      // when it exited
    Signal: Integer;        // when it was killed by a signal (0 otherwise)
  end;

function FindExe(const Exe, PathVar: string): string;
function SpawnProcess(const Exe: string; Args, Env: TStrings; const Cwd, LogFile: string; out Err: string): Integer;
function PollChild(Pid: Integer): TChildEnd;
procedure KillTree(Pid: Integer; Hard: Boolean);
{ Send a signal to part of a service: Scope 'children' = every DESCENDANT of Pid but not Pid itself (what a Stop button wants: end the running
  CLI, keep the loop that started it), 'group' = the whole process group, Pid included (what Ctrl-C in a terminal does), 'leader' = Pid only.
  Returns how many processes were signalled, or -1 for an unknown scope. }
function SignalTree(Pid, Sig: Integer; const Scope: string): Integer;
function PidAlive(Pid: Integer): Boolean;

{ Probes: each forks, and returns the child's pid (-1 on failure).  Child exit status 0 = healthy. }
function ForkProbeTcp(const Host: string; Port, TimeoutMs: Integer): Integer;
function ForkProbeUnix(const SockPath: string; TimeoutMs: Integer): Integer;
function ForkProbeHttp(const Url: string; TimeoutMs: Integer): Integer;

implementation

procedure SetEnvEntry(L: TStrings; const Entry: string);
var
  k, p: Integer;
  name: string;
begin
  p := Pos('=', Entry);
  if p <= 1 then begin L.Add(Entry); Exit; end;
  name := Copy(Entry, 1, p);
  for k := 0 to L.Count - 1 do
    if Copy(L[k], 1, p) = name then begin L[k] := Entry; Exit; end;
  L.Add(Entry);
end;

function FindExe(const Exe, PathVar: string): string;
var
  parts: TStringList;
  i: Integer;
  cand: string;
begin
  Result := '';
  if Pos('/', Exe) > 0 then
  begin
    if FileExists(Exe) then Result := ExpandFileName(Exe);
    Exit;
  end;
  parts := TStringList.Create;
  try
    parts.Delimiter := ':'; parts.StrictDelimiter := True; parts.DelimitedText := PathVar;
    for i := 0 to parts.Count - 1 do
    begin
      if parts[i] = '' then Continue;
      cand := IncludeTrailingPathDelimiter(parts[i]) + Exe;
      if FileExists(cand) and (fpAccess(cand, X_OK) = 0) then Exit(cand);
    end;
  finally
    parts.Free;
  end;
end;

function SpawnProcess(const Exe: string; Args, Env: TStrings; const Cwd, LogFile: string; out Err: string): Integer;
var
  path, pathVar: string;
  envList: TStringList;
  argv, envp: array of PChar;
  keep: TStringList;
  i: Integer;
  pid: TPid;
  logfd, nullfd: cint;
begin
  Result := -1;
  Err := '';
  envList := TStringList.Create;
  keep := TStringList.Create;
  try
    for i := 0 to GetEnvironmentVariableCount do
      if GetEnvironmentString(i) <> '' then SetEnvEntry(envList, GetEnvironmentString(i));
    if Assigned(Env) then for i := 0 to Env.Count - 1 do SetEnvEntry(envList, Env[i]);
    pathVar := envList.Values['PATH'];
    path := FindExe(Exe, pathVar);
    if path = '' then begin Err := 'program not found: ' + Exe; Exit; end;
    if (Cwd <> '') and not DirectoryExists(Cwd) then begin Err := 'working directory does not exist: ' + Cwd; Exit; end;

    // build argv / envp BEFORE forking: after fork the child must only call simple syscalls
    keep.Add(path);
    if Assigned(Args) then for i := 0 to Args.Count - 1 do keep.Add(Args[i]);
    SetLength(argv, keep.Count + 1);
    for i := 0 to keep.Count - 1 do argv[i] := PChar(keep[i]);
    argv[keep.Count] := nil;
    SetLength(envp, envList.Count + 1);
    for i := 0 to envList.Count - 1 do envp[i] := PChar(envList[i]);
    envp[envList.Count] := nil;

    ForceDirectories(ExtractFilePath(LogFile));
    logfd := fpOpen(LogFile, O_WRONLY or O_CREAT or O_APPEND, &640);
    nullfd := fpOpen('/dev/null', O_RDONLY);

    pid := fpFork;
    if pid < 0 then begin Err := 'fork failed'; if logfd >= 0 then fpClose(logfd); if nullfd >= 0 then fpClose(nullfd); Exit; end;
    if pid = 0 then
    begin
      // ---- child ----
      fpSetsid;
      if nullfd >= 0 then fpDup2(nullfd, 0);
      if logfd >= 0 then begin fpDup2(logfd, 1); fpDup2(logfd, 2); end;
      if Cwd <> '' then fpChdir(Cwd);
      // Close every other inherited descriptor.  The supervisor's control socket is one of them: a service
      // that kept it open would keep the socket "alive" after the supervisor died, and every later
      // connection (and the next supervisor's start) would hang on a listener nobody serves.
      for i := 3 to 1023 do fpClose(i);
      fpExecve(PChar(path), @argv[0], @envp[0]);
      FpExit(127);                                  // exec failed
    end;
    if logfd >= 0 then fpClose(logfd);
    if nullfd >= 0 then fpClose(nullfd);
    Result := pid;
  finally
    envList.Free;
    keep.Free;
  end;
end;

function PollChild(Pid: Integer): TChildEnd;
var
  st: cint;
  r: TPid;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Pid <= 0 then begin Result.Ended := True; Exit; end;
  st := 0;
  r := fpWaitPid(Pid, st, WNOHANG);
  if r = 0 then Exit;                                // still running
  if r < 0 then begin Result.Ended := True; Result.ExitCode := -1; Exit; end;    // not our child / already reaped
  Result.Ended := True;
  if (st and $7F) = 0 then Result.ExitCode := (st shr 8) and $FF
  else begin Result.Signal := st and $7F; Result.ExitCode := 128 + Result.Signal; end;
end;

procedure KillTree(Pid: Integer; Hard: Boolean);
begin
  if Pid <= 1 then Exit;
  if Hard then begin fpKill(-Pid, SIGKILL); fpKill(Pid, SIGKILL); end
  else begin fpKill(-Pid, SIGTERM); fpKill(Pid, SIGTERM); end;
end;

function PidAlive(Pid: Integer): Boolean;
begin
  Result := (Pid > 1) and (fpKill(Pid, 0) = 0);
end;

{ pid -> parent pid for every process: from /proc (Linux) or, where there is none (macOS, BSD), from "ps -A -o pid= -o ppid=" }
procedure ReadParents(Pids, Parents: TList);
var
  sr: TSearchRec;
  s, rest: string;
  p, v: Integer;
  fs: TFileStream;
  buf: array[0..1023] of Char;
  n: Integer;
  f: Text;
  line: string;
begin
  if DirectoryExists('/proc/self') then
  begin
    if FindFirst('/proc/*', faDirectory, sr) = 0 then
    begin
      repeat
        v := StrToIntDef(sr.Name, 0);
        if v <= 0 then Continue;
        try
          fs := TFileStream.Create('/proc/' + sr.Name + '/stat', fmOpenRead or fmShareDenyNone);
          try n := fs.Read(buf, SizeOf(buf)); finally fs.Free; end;
        except
          Continue;                                   { the process ended while we were looking }
        end;
        SetString(s, buf, n);
        p := LastDelimiter(')', s);                   { "pid (comm) state ppid ...": comm may hold spaces and brackets }
        if p = 0 then Continue;
        rest := Trim(Copy(s, p + 1, MaxInt));         { "S ppid ..." }
        rest := Trim(Copy(rest, Pos(' ', rest) + 1, MaxInt));
        p := StrToIntDef(Copy(rest, 1, Pos(' ', rest + ' ') - 1), -1);
        if p >= 0 then begin Pids.Add(Pointer(PtrInt(v))); Parents.Add(Pointer(PtrInt(p))); end;
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  end
  else
  begin
    Unix.POpen(f, 'ps -A -o pid= -o ppid= 2>/dev/null', 'R');
    while not Eof(f) do
    begin
      ReadLn(f, line);
      line := Trim(line);
      p := Pos(' ', line);
      if p > 0 then
      begin
        v := StrToIntDef(Copy(line, 1, p - 1), 0);
        n := StrToIntDef(Trim(Copy(line, p + 1, MaxInt)), -1);
        if (v > 0) and (n >= 0) then begin Pids.Add(Pointer(PtrInt(v))); Parents.Add(Pointer(PtrInt(n))); end;
      end;
    end;
    PClose(f);
  end;
end;

function SignalTree(Pid, Sig: Integer; const Scope: string): Integer;
var
  pids, parents, todo, found: TList;
  i, cur: Integer;
begin
  Result := 0;
  if Pid <= 1 then Exit(-1);
  if Scope = 'leader' then
  begin
    if fpKill(Pid, Sig) = 0 then Result := 1;
    Exit;
  end;
  if Scope = 'group' then
  begin
    if fpKill(-Pid, Sig) = 0 then Result := 1;      { one call reaches the whole group; the count is "the group", not each member }
    Exit;
  end;
  if Scope <> 'children' then Exit(-1);
  pids := TList.Create; parents := TList.Create; todo := TList.Create; found := TList.Create;
  try
    ReadParents(pids, parents);
    todo.Add(Pointer(PtrInt(Pid)));
    while todo.Count > 0 do                          { breadth-first: every descendant, whatever the depth }
    begin
      cur := PtrInt(todo[0]); todo.Delete(0);
      for i := 0 to pids.Count - 1 do
        if PtrInt(parents[i]) = cur then
        begin
          if found.IndexOf(pids[i]) < 0 then begin found.Add(pids[i]); todo.Add(pids[i]); end;
        end;
    end;
    for i := 0 to found.Count - 1 do
      if fpKill(PtrInt(found[i]), Sig) = 0 then Inc(Result);
  finally
    pids.Free; parents.Free; todo.Free; found.Free;
  end;
end;

{ ---- probes: all share "connect with a timeout" ---------------------------------------------------- }

function ConnectWithTimeout(fd: cint; addr: Pointer; alen: Integer; TimeoutMs: Integer): Boolean;
var
  fl: cint;
  pfd: TPollFd;
  err: cint;
  elen: TSockLen;
begin
  Result := False;
  fl := fpFcntl(fd, F_GETFL);
  fpFcntl(fd, F_SETFL, fl or O_NONBLOCK);
  if fpConnect(fd, addr, alen) = 0 then Exit(True);
  if fpGetErrno <> ESysEINPROGRESS then Exit;
  pfd.fd := fd; pfd.events := POLLOUT; pfd.revents := 0;
  if fpPoll(@pfd, 1, TimeoutMs) <= 0 then Exit;
  err := 0; elen := SizeOf(err);
  fpGetSockOpt(fd, SOL_SOCKET, SO_ERROR, @err, @elen);
  Result := err = 0;
end;

function TcpUp(const Host: string; Port, TimeoutMs: Integer; out Fd: cint): Boolean;
var
  addr: TInetSockAddr;
begin
  Result := False;
  Fd := fpSocket(AF_INET, SOCK_STREAM, 0);
  if Fd < 0 then Exit;
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(Port);
  addr.sin_addr := StrToNetAddr(Host);
  Result := ConnectWithTimeout(Fd, @addr, SizeOf(addr), TimeoutMs);
end;

function ForkProbeTcp(const Host: string; Port, TimeoutMs: Integer): Integer;
var
  pid: TPid;
  fd: cint;
begin
  pid := fpFork;
  if pid = 0 then
  begin
    if TcpUp(Host, Port, TimeoutMs, fd) then FpExit(0) else FpExit(1);
  end;
  Result := pid;
end;

function ForkProbeUnix(const SockPath: string; TimeoutMs: Integer): Integer;
var
  pid: TPid;
  fd: cint;
  addr: sockaddr_un;
begin
  pid := fpFork;
  if pid = 0 then
  begin
    fd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
    FillChar(addr, SizeOf(addr), 0);
    addr.sun_family := AF_UNIX;
    StrPCopy(addr.sun_path, SockPath);
    if (fd >= 0) and ConnectWithTimeout(fd, @addr, SizeOf(addr), TimeoutMs) then FpExit(0) else FpExit(1);
  end;
  Result := pid;
end;

{ GET http://host:port/path -> 2xx or 3xx is healthy. }
function ForkProbeHttp(const Url: string; TimeoutMs: Integer): Integer;
var
  pid: TPid;
  fd: cint;
  rest, host, path, req, resp: string;
  port, p, n: Integer;
  buf: array[0..511] of Char;
  pfd: TPollFd;
  code: Integer;
begin
  pid := fpFork;
  if pid <> 0 then Exit(pid);
  // ---- child ----
  if LowerCase(Copy(Url, 1, 7)) <> 'http://' then FpExit(1);            // https is not probed here
  rest := Copy(Url, 8, MaxInt);
  p := Pos('/', rest);
  if p = 0 then begin host := rest; path := '/'; end else begin host := Copy(rest, 1, p - 1); path := Copy(rest, p, MaxInt); end;
  port := 80;
  p := Pos(':', host);
  if p > 0 then begin port := StrToIntDef(Copy(host, p + 1, 6), 80); host := Copy(host, 1, p - 1); end;
  if host = 'localhost' then host := '127.0.0.1';
  if not TcpUp(host, port, TimeoutMs, fd) then FpExit(1);
  req := 'GET ' + path + ' HTTP/1.0'#13#10'Host: ' + host + #13#10'Connection: close'#13#10#13#10;
  fpSend(fd, @req[1], Length(req), 0);
  pfd.fd := fd; pfd.events := POLLIN; pfd.revents := 0;
  if fpPoll(@pfd, 1, TimeoutMs) <= 0 then FpExit(1);
  FillChar(buf, SizeOf(buf), 0);
  n := fpRecv(fd, @buf[0], SizeOf(buf) - 1, 0);
  if n <= 0 then FpExit(1);
  SetString(resp, PChar(@buf[0]), n);
  // "HTTP/1.x 200 OK"
  code := StrToIntDef(Copy(resp, 10, 3), 0);
  if (code >= 200) and (code < 400) then FpExit(0) else FpExit(1);
  Result := 0;
end;

end.
