(* =============================================================================
  aic_proc — the PROCESS transport: run a program from an argument array, stream its output.

  What it guarantees (each one has a test in tests/):
    * NO SHELL.  The program is started directly with an argv array, so a prompt full of quotes,
      newlines, backticks or "; rm -rf ~" is only bytes.
    * LINES, as they arrive.  stdout and stderr are read with poll(), split on LF, and handed to the
      caller immediately (no waiting for the process to end).  A final line without LF is delivered too.
    * STDIN without deadlock.  A large prompt (hundreds of KB) is written in chunks while output is being
      read, so a child that starts answering before it has read everything cannot block us.
    * LIMITS.  Wall-clock timeout, a cap on the raw bytes read, and a cancel flag the caller can flip
      from outside.  Any of them stops the run.
    * THE WHOLE TREE.  The child is started in its own session / process group; on a stop we SIGTERM the
      group, wait briefly, then SIGKILL it.  An agent that spawned a build, a server or `sleep 1000`
      does not leave it behind.  (After a NORMAL exit the group is also swept, so nothing the agent
      started keeps running after its run is over.)
    * ENVIRONMENT.  The parent's environment plus explicit additions, so per-run isolation such as
      CLAUDE_CONFIG_DIR works without touching the engine's own environment.

  Unix implementation (Linux, macOS).  Windows needs the same contract through job objects; that is a
  separate unit with the same interface.
  ============================================================================= *)
unit aic_proc;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, Unix;

type
  TLineEvent = procedure(const Line: string; IsStderr: Boolean) of object;
  TCancelCheck = function: Boolean of object;
  { raw bytes exactly as they were read (no line splitting): used by the legacy mode, which must reproduce a shell's `> file 2>&1` }
  TChunkEvent = procedure(const Data: string; IsStderr: Boolean) of object;

  TProcResult = record
    Started: Boolean;
    StartError: string;
    ExitCode: Integer;
    TimedOut, Cancelled, OutputCapped: Boolean;
    BytesRead: Int64;
    Pid: Integer;
  end;

function FindInPath(const Exe: string; const PathVar: string): string;

function RunProcess(const Exe: string; Args: TStrings; const Cwd: string; EnvExtra: TStrings;
  const StdinData: string; TimeoutS, MaxOutKB: Integer; OnLine: TLineEvent;
  Cancel: TCancelCheck; OnChunk: TChunkEvent = nil; MergeStderr: Boolean = False): TProcResult;

implementation

function FindInPath(const Exe: string; const PathVar: string): string;
var
  parts: TStringList;
  i: Integer;
  cand: string;
begin
  Result := '';
  if Pos('/', Exe) > 0 then
  begin
    if FileExists(Exe) then Result := Exe;
    Exit;
  end;
  parts := TStringList.Create;
  try
    parts.Delimiter := ':';
    parts.StrictDelimiter := True;
    parts.DelimitedText := PathVar;
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

procedure SetEnvEntry(L: TStrings; const Entry: string);
var
  k, p: Integer;
  name: string;
begin
  p := Pos('=', Entry);
  if p <= 1 then begin L.Add(Entry); Exit; end;
  name := Copy(Entry, 1, p);                       // "NAME="
  for k := 0 to L.Count - 1 do
    if Copy(L[k], 1, p) = name then begin L[k] := Entry; Exit; end;
  L.Add(Entry);
end;

procedure SetNonBlocking(fd: THandle);
var
  fl: cint;
begin
  fl := fpFcntl(fd, F_GETFL);
  if fl >= 0 then fpFcntl(fd, F_SETFL, fl or O_NONBLOCK);
end;

{ Split a growing buffer into complete lines and hand them out; the unfinished tail stays in Buf. }
procedure DrainLines(var Buf: string; IsErr: Boolean; OnLine: TLineEvent);
var
  p: Integer;
  ln: string;
begin
  repeat
    p := Pos(#10, Buf);
    if p = 0 then Break;
    ln := Copy(Buf, 1, p - 1);
    Delete(Buf, 1, p);
    if (Length(ln) > 0) and (ln[Length(ln)] = #13) then SetLength(ln, Length(ln) - 1);   // CRLF tools
    if Assigned(OnLine) then OnLine(ln, IsErr);
  until False;
end;

procedure KillGroup(Pid: Integer; Hard: Boolean);
begin
  if Pid <= 1 then Exit;
  if Hard then fpKill(-Pid, SIGKILL) else fpKill(-Pid, SIGTERM);
end;

{ ---- starting the child: fork + exec, by hand ----------------------------------------------------------
  Why not TProcess: FPC builds argv with StrNew, which returns nil for an EMPTY string, so one empty argument
  (an empty prompt after a flag, `--message ""`) silently ENDS the argument list there and drops everything after
  it. Doing fork/exec ourselves also lets us put the child in its own session, merge stderr into stdout the way
  a shell's `2>&1` does, and close every inherited descriptor above 2. }
type
  TChild = record
    Pid: cint;
    InFd, OutFd, ErrFd: cint;        // our ends; -1 when closed / not used
    Done: Boolean;
    Status: cint;                    // raw wait() status once Done
  end;

function SpawnChild(const Exe: string; Args, Env: TStrings; const Cwd: string; MergeErr: Boolean;
  out C: TChild; out Err: string): Boolean;
var
  pin, pout, perr: array[0..1] of cint;
  argv, envp: array of PChar;
  i, nfd: Integer;
  pid: cint;
  cwdp: PChar;
  rl: TRLimit;
begin
  Result := False; Err := '';
  FillChar(C, SizeOf(C), 0);
  C.InFd := -1; C.OutFd := -1; C.ErrFd := -1;
  // argv: program name, then every argument — empty ones included
  SetLength(argv, Args.Count + 2);
  argv[0] := PChar(Exe);
  for i := 0 to Args.Count - 1 do argv[i + 1] := PChar(Args[i]);
  argv[Args.Count + 1] := nil;
  SetLength(envp, Env.Count + 1);
  for i := 0 to Env.Count - 1 do envp[i] := PChar(Env[i]);
  envp[Env.Count] := nil;
  if Cwd <> '' then cwdp := PChar(Cwd) else cwdp := nil;
  if fpPipe(pin) <> 0 then begin Err := 'pipe failed'; Exit; end;
  if fpPipe(pout) <> 0 then begin fpClose(pin[0]); fpClose(pin[1]); Err := 'pipe failed'; Exit; end;
  perr[0] := -1; perr[1] := -1;
  if not MergeErr then
    if fpPipe(perr) <> 0 then begin fpClose(pin[0]); fpClose(pin[1]); fpClose(pout[0]); fpClose(pout[1]); Err := 'pipe failed'; Exit; end;
  // highest descriptor to close in the child: the soft limit, capped
  nfd := 1024;
  if fpGetRLimit(RLIMIT_NOFILE, @rl) = 0 then if (rl.rlim_cur > 0) and (rl.rlim_cur < 4096) then nfd := Integer(rl.rlim_cur);

  pid := fpFork;
  if pid < 0 then
  begin
    fpClose(pin[0]); fpClose(pin[1]); fpClose(pout[0]); fpClose(pout[1]);
    if not MergeErr then begin fpClose(perr[0]); fpClose(perr[1]); end;
    Err := 'fork failed';
    Exit;
  end;
  if pid = 0 then
  begin
    // ---- child: only async-signal-safe calls from here to exec ----
    fpSetsid;                                       // its own session and process group: Stop can signal the whole tree
    fpDup2(pin[0], 0);
    fpDup2(pout[1], 1);
    if MergeErr then fpDup2(pout[1], 2) else fpDup2(perr[1], 2);
    for i := 3 to nfd - 1 do fpClose(i);            // nothing else the engine holds may leak into the agent
    if cwdp <> nil then if fpChdir(cwdp) <> 0 then FpExit(126);
    fpExecve(argv[0], PPChar(@argv[0]), PPChar(@envp[0]));
    FpExit(127);                                    // exec failed
  end;
  // ---- parent ----
  fpClose(pin[0]); fpClose(pout[1]);
  if not MergeErr then fpClose(perr[1]);
  C.Pid := pid;
  C.InFd := pin[1]; C.OutFd := pout[0];
  if MergeErr then C.ErrFd := -1 else C.ErrFd := perr[0];
  // our ends must not be inherited by anything we start later
  fpFcntl(C.InFd, F_SETFD, 1); fpFcntl(C.OutFd, F_SETFD, 1);
  if C.ErrFd >= 0 then fpFcntl(C.ErrFd, F_SETFD, 1);
  Result := True;
end;

procedure ChildCloseInput(var C: TChild);
begin
  if C.InFd >= 0 then begin fpClose(C.InFd); C.InFd := -1; end;
end;

{ Has it ended?  Non-blocking; records the status once. }
function ChildRunning(var C: TChild): Boolean;
var
  st: cint;
  r: TPid;
begin
  if C.Done then Exit(False);
  r := fpWaitPid(C.Pid, @st, WNOHANG);
  if r = C.Pid then begin C.Done := True; C.Status := st; Exit(False); end;
  if r < 0 then begin C.Done := True; C.Status := 0; Exit(False); end;     // already reaped / not ours
  Result := True;
end;

procedure ChildWait(var C: TChild);
var
  st: cint;
begin
  if C.Done then Exit;
  while fpWaitPid(C.Pid, @st, 0) < 0 do
    if fpGetErrno <> ESysEINTR then Break;
  C.Done := True; C.Status := st;
end;

function RunProcess(const Exe: string; Args: TStrings; const Cwd: string; EnvExtra: TStrings;
  const StdinData: string; TimeoutS, MaxOutKB: Integer; OnLine: TLineEvent;
  Cancel: TCancelCheck; OnChunk: TChunkEvent; MergeStderr: Boolean): TProcResult;
var
  C: TChild;
  Env, ArgList: TStringList;
  fds: array[0..2] of TPollFd;
  nfds, rc, got, k: Integer;
  outBuf, errBuf: string;
  chunk: array[0..65535] of Byte;
  s: string;
  deadline: QWord;
  stdinPos: Integer;
  stdinOpen, outOpen, errOpen: Boolean;
  exe2, pathVar, spawnErr: string;
  i: Integer;
  exited: Boolean;
  graceUntil: QWord;
  ep: PPChar;
  maxBytes: Int64;
  w: TSize;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ExitCode := -1;

  pathVar := GetEnvironmentVariable('PATH');
  // an explicit PATH in the extra environment wins for finding the program, as it will for the child
  if Assigned(EnvExtra) then
    for i := 0 to EnvExtra.Count - 1 do
      if Copy(EnvExtra[i], 1, 5) = 'PATH=' then pathVar := Copy(EnvExtra[i], 6, MaxInt);
  exe2 := FindInPath(Exe, pathVar);
  if (exe2 <> '') and (Pos('/', exe2) > 0) then exe2 := ExpandFileName(exe2);   // the child may chdir before exec
  if exe2 = '' then
  begin
    Result.StartError := 'program not found: ' + Exe;
    Exit;
  end;

  Env := TStringList.Create;
  ArgList := TStringList.Create;
  try
    // environment: ours, then the additions.  A later KEY=VALUE REPLACES an earlier one with the same name
    // (inherited < adapter < request): two entries with one name would make getenv() return the FIRST, so
    // a per-run CLAUDE_CONFIG_DIR would silently lose to an inherited one.
    // Walk the environment block itself. GetEnvironmentVariableCount is a count FPC's runtime keeps, which does not follow a program that
    // replaces the block (aicengine loop does, to give its children CLAUDE_CONFIG_DIR and the keys): it cut the later variables off.
    ep := envp;
    while (ep <> nil) and (ep^ <> nil) do
    begin
      if ep^^ <> #0 then SetEnvEntry(Env, StrPas(ep^));
      Inc(ep);
    end;
    if Assigned(EnvExtra) then
      for i := 0 to EnvExtra.Count - 1 do SetEnvEntry(Env, EnvExtra[i]);
    if Assigned(Args) then ArgList.AddStrings(Args);

    if not SpawnChild(exe2, ArgList, Env, Cwd, MergeStderr, C, spawnErr) then
    begin
      Result.StartError := 'could not start ' + Exe + ': ' + spawnErr;
      Exit;
    end;
    Result.Started := True;
    Result.Pid := C.Pid;

    SetNonBlocking(C.InFd); SetNonBlocking(C.OutFd); if C.ErrFd >= 0 then SetNonBlocking(C.ErrFd);

    stdinPos := 1;
    stdinOpen := True;
    if StdinData = '' then
    begin
      ChildCloseInput(C);
      stdinOpen := False;
    end;
    outOpen := True; errOpen := C.ErrFd >= 0;
    outBuf := ''; errBuf := '';
    if TimeoutS > 0 then deadline := GetTickCount64 + QWord(TimeoutS) * 1000 else deadline := 0;
    maxBytes := Int64(MaxOutKB) * 1024;
    exited := False;
    graceUntil := 0;

    while True do
    begin
      // ---- stop conditions ------------------------------------------------------------------
      if Assigned(Cancel) and Cancel() then Result.Cancelled := True;
      if (deadline > 0) and (GetTickCount64 > deadline) then Result.TimedOut := True;
      if (maxBytes > 0) and (Result.BytesRead > maxBytes) then Result.OutputCapped := True;
      if Result.Cancelled or Result.TimedOut or Result.OutputCapped then
      begin
        KillGroup(Result.Pid, False);
        Sleep(150);
        KillGroup(Result.Pid, True);
        Break;
      end;

      // ---- poll the three pipes -------------------------------------------------------------
      nfds := 0;
      if outOpen then begin fds[nfds].fd := C.OutFd; fds[nfds].events := POLLIN; fds[nfds].revents := 0; Inc(nfds); end;
      if errOpen then begin fds[nfds].fd := C.ErrFd; fds[nfds].events := POLLIN; fds[nfds].revents := 0; Inc(nfds); end;
      if stdinOpen then begin fds[nfds].fd := C.InFd; fds[nfds].events := POLLOUT; fds[nfds].revents := 0; Inc(nfds); end;
      if nfds > 0 then rc := fpPoll(@fds[0], nfds, 50) else begin rc := 0; Sleep(20); end;

      if rc > 0 then
        for k := 0 to nfds - 1 do
        begin
          if fds[k].revents = 0 then Continue;
          if stdinOpen and (fds[k].fd = C.InFd) then
          begin
            // write the next slice of stdin; closing it tells the child "that is all"
            if (fds[k].revents and (POLLERR or POLLHUP)) <> 0 then
            begin
              ChildCloseInput(C); stdinOpen := False;
            end
            else
            begin
              w := fpWrite(C.InFd, StdinData[stdinPos], Length(StdinData) - stdinPos + 1);
              if w > 0 then Inc(stdinPos, w);
              if stdinPos > Length(StdinData) then begin ChildCloseInput(C); stdinOpen := False; end;
            end;
          end
          else
          begin
            got := fpRead(fds[k].fd, chunk[0], SizeOf(chunk));
            if got > 0 then
            begin
              SetString(s, PChar(@chunk[0]), got);
              Inc(Result.BytesRead, got);
              if Assigned(OnChunk) then OnChunk(s, fds[k].fd <> C.OutFd);
              if fds[k].fd = C.OutFd then begin outBuf := outBuf + s; DrainLines(outBuf, False, OnLine); end
              else begin errBuf := errBuf + s; DrainLines(errBuf, True, OnLine); end;
            end
            else if got = 0 then
            begin
              if fds[k].fd = C.OutFd then outOpen := False else errOpen := False;     // EOF
            end;
          end;
        end;

      // ---- has the child ended? --------------------------------------------------------------
      if not exited and not ChildRunning(C) then
      begin
        exited := True;
        graceUntil := GetTickCount64 + 300;     // a short window to drain what is still in the pipes
      end;
      if (not outOpen) and (not errOpen) and exited then Break;
      if exited and (GetTickCount64 > graceUntil) then Break;    // a grandchild keeping a pipe open must not hold us
    end;

    // final flush: a last line that had no trailing newline
    if outBuf <> '' then begin if Assigned(OnLine) then OnLine(outBuf, False); outBuf := ''; end;
    if errBuf <> '' then begin if Assigned(OnLine) then OnLine(errBuf, True); errBuf := ''; end;

    // sweep the group: nothing the agent started may outlive its run
    KillGroup(Result.Pid, False);
    if not exited then
    begin
      i := 0;
      while ChildRunning(C) and (i < 40) do begin Sleep(25); Inc(i); end;
    end;
    KillGroup(Result.Pid, True);
    ChildWait(C);
    // C.Status is the raw wait() status: low 7 bits = terminating signal, next byte = exit code
    if (C.Status and $7F) = 0 then Result.ExitCode := (C.Status shr 8) and $FF
    else Result.ExitCode := 128 + (C.Status and $7F);
    ChildCloseInput(C);
    if C.OutFd >= 0 then fpClose(C.OutFd);
    if C.ErrFd >= 0 then fpClose(C.ErrFd);
  finally
    Env.Free; ArgList.Free;
  end;
end;

end.
