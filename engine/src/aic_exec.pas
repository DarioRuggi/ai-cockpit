(* =============================================================================
  aic_exec — the command window's engine: run ONE simple command line the way the file window's rules say.

    * The command runs as the account that runs this program (no elevation), in a folder of a zone (default: Public).
    * It may WRITE only inside the read-write zone(s) of the request (Public) and a private temp folder Public/.tmp; it may READ the
      read-only areas and the system's programs and libraries (/usr /bin /lib /etc ...); nothing else on the disk is visible to it.
      This is enforced by the Linux kernel (Landlock), so no command line trick, script or program started by it can get around it.
    * If the kernel cannot do that (no Landlock, not Linux) the command is NOT run: there is no unprotected mode.
    * Its environment is a small fixed one (the service's own environment, with its secrets, is not passed on).
    * A time limit and an output limit; on timeout the whole process group is killed.
  Network access is not restricted by the kernel here (Landlock's network rules need a newer kernel); that is said in the guide.
  ============================================================================= *)
unit aic_exec;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, fpjson;

function ExecHandle(Req: TJSONObject): TJSONObject;
{ 0 = no Landlock here, else the kernel's Landlock ABI version }
function SandboxAbi: Integer;

implementation

uses
  aic_fs;

const
  SYS_landlock_create_ruleset = 444;
  SYS_landlock_add_rule = 445;
  SYS_landlock_restrict_self = 446;
  LL_RULE_PATH_BENEATH = 1;
  LL_CREATE_RULESET_VERSION = 1;
  PR_SET_NO_NEW_PRIVS = 38;
  // access rights
  A_EXECUTE = 1 shl 0; A_WRITE_FILE = 1 shl 1; A_READ_FILE = 1 shl 2; A_READ_DIR = 1 shl 3; A_REMOVE_DIR = 1 shl 4; A_REMOVE_FILE = 1 shl 5;
  A_MAKE_CHAR = 1 shl 6; A_MAKE_DIR = 1 shl 7; A_MAKE_REG = 1 shl 8; A_MAKE_SOCK = 1 shl 9; A_MAKE_FIFO = 1 shl 10; A_MAKE_BLOCK = 1 shl 11;
  A_MAKE_SYM = 1 shl 12; A_REFER = 1 shl 13; A_TRUNCATE = 1 shl 14;
  O_PATH_ = $200000;
  O_CLOEXEC_ = $80000;
  RLIMIT_CPU_ = 0; RLIMIT_FSIZE_ = 1; RLIMIT_CORE_ = 4;
  EXEC_MAX_TIMEOUT = 120;

type
  TLLRuleAttr = packed record
    allowed_access: QWord;
    parent_fd: cint;
  end;
  TRLimit = record
    cur, max: QWord;
  end;

function c_syscall(num: clong): clong; cdecl; varargs; external 'c' name 'syscall';
function c_prctl(option: cint): cint; cdecl; varargs; external 'c' name 'prctl';
function c_open(path: PChar; flags: cint): cint; cdecl; varargs; external 'c' name 'open';
function c_setrlimit(res: cint; var rl: TRLimit): cint; cdecl; external 'c' name 'setrlimit';
function c_setpgid(pid, pgid: cint): cint; cdecl; external 'c' name 'setpgid';

function SandboxAbi: Integer;
var
  r: clong;
begin
  {$IF DEFINED(LINUX) AND (DEFINED(CPUX86_64) OR DEFINED(CPUAARCH64))}
  r := c_syscall(SYS_landlock_create_ruleset, 0, 0, LL_CREATE_RULESET_VERSION);
  if r < 1 then Result := 0 else Result := r;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

function HandledMask(Abi: Integer): QWord;
begin
  Result := $1FFF;
  if Abi >= 2 then Result := Result or A_REFER;
  if Abi >= 3 then Result := Result or A_TRUNCATE;
end;

{ builds the ruleset and restricts THIS process; returns '' or the reason it could not. Called in the child, before exec. }
function ApplySandbox(WriteRoots, ReadRoots: TStringList; const Tmp: string): string;
var
  abi: Integer;
  handled, full: QWord;
  fd: cint;
  rs: packed record handled_access_fs: QWord; end;
  ro: QWord;
  i: Integer;

  function AddPath(const Path: string; Access: QWord): Boolean;
  var
    pfd: cint;
    attr: TLLRuleAttr;
    r: clong;
  begin
    Result := True;
    if not (FileExists(Path) or DirectoryExists(Path)) then Exit;       // a system folder that does not exist on this machine
    pfd := c_open(PChar(Path), O_PATH_ or O_CLOEXEC_);
    if pfd < 0 then Exit;
    attr.allowed_access := Access and handled;
    // a rule for a FILE may only carry file rights
    if not DirectoryExists(Path) then attr.allowed_access := attr.allowed_access and (A_EXECUTE or A_WRITE_FILE or A_READ_FILE or A_TRUNCATE);
    attr.parent_fd := pfd;
    r := c_syscall(SYS_landlock_add_rule, fd, LL_RULE_PATH_BENEATH, PtrInt(@attr), 0);
    fpClose(pfd);
    Result := r = 0;
  end;

begin
  Result := '';
  abi := SandboxAbi;
  if abi < 1 then Exit('this machine cannot confine commands (needs Linux with Landlock)');
  handled := HandledMask(abi);
  full := handled;
  ro := A_READ_FILE or A_READ_DIR;
  rs.handled_access_fs := handled;
  fd := c_syscall(SYS_landlock_create_ruleset, PtrInt(@rs), SizeOf(rs), 0);
  if fd < 0 then Exit('could not create the confinement (Landlock)');
  for i := 0 to WriteRoots.Count - 1 do if not AddPath(WriteRoots[i], full) then Exit('could not allow the Public folder');
  if Tmp <> '' then AddPath(Tmp, full);
  for i := 0 to ReadRoots.Count - 1 do AddPath(ReadRoots[i], ro);
  for i in [0..8] do
    case i of
      0: AddPath('/usr', ro or A_EXECUTE);
      1: AddPath('/bin', ro or A_EXECUTE);
      2: AddPath('/sbin', ro or A_EXECUTE);
      3: AddPath('/lib', ro or A_EXECUTE);
      4: AddPath('/lib64', ro or A_EXECUTE);
      5: AddPath('/etc', ro);
      6: AddPath('/opt', ro or A_EXECUTE);
      7: AddPath('/proc', ro);
      8: AddPath('/sys', ro);
    end;
  AddPath('/dev/null', A_READ_FILE or A_WRITE_FILE); AddPath('/dev/zero', A_READ_FILE); AddPath('/dev/full', A_READ_FILE or A_WRITE_FILE);
  AddPath('/dev/random', A_READ_FILE); AddPath('/dev/urandom', A_READ_FILE);
  if c_prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) <> 0 then begin fpClose(fd); Exit('could not set no-new-privileges'); end;
  if c_syscall(SYS_landlock_restrict_self, fd, 0) <> 0 then begin fpClose(fd); Exit('could not apply the confinement'); end;
  fpClose(fd);
end;

function ExecHandle(Req: TJSONObject): TJSONObject;
var
  cmd, cwdPath, cwdReal, tmpDir, outp, msg, failMsg: string;
  rwZone, timedOut, truncated: Boolean;
  wr, ro: TStringList;
  timeoutS, maxKB, i: Integer;
  pid: TPid;
  pfd: array[0..1] of cint;
  status: cint;
  buf: array[0..16383] of Byte;
  n: PtrInt;
  start: QWord;
  fds: TFDSet;
  tv: TTimeVal;
  exitCode: Integer;
  argv, envp: array of PChar;
  envs: TStringList;
  rl: TRLimit;
  pubRoot: string;
  resp: TJSONObject;
begin
  cmd := Req.Get('cmd', '');
  if Trim(cmd) = '' then Exit(TJSONObject.Create(['ok', False, 'error', 'type a command']));
  if Length(cmd) > 8192 then Exit(TJSONObject.Create(['ok', False, 'error', 'the command line is too long']));
  if Pos(#0, cmd) > 0 then Exit(TJSONObject.Create(['ok', False, 'error', 'bad command line']));
  FsLoadZones(Req);
  wr := FsRoots(True); ro := FsRoots(False);
  envs := TStringList.Create;
  try
    if wr.Count = 0 then Exit(TJSONObject.Create(['ok', False, 'error', 'there is no Public folder to run in']));
    cwdPath := Req.Get('cwd', '');
    if cwdPath = '' then cwdPath := 'public:';
    try
      cwdReal := FsResolveDir(cwdPath, rwZone);
    except
      on E: Exception do Exit(TJSONObject.Create(['ok', False, 'error', 'folder: ' + E.Message]));
    end;
    if cwdReal = '' then Exit(TJSONObject.Create(['ok', False, 'error', 'that folder cannot be used']));
    pubRoot := wr[0];
    tmpDir := pubRoot + '/.tmp';
    if not DirectoryExists(tmpDir) then ForceDirectories(tmpDir);
    timeoutS := Req.Get('timeout_s', 20); if timeoutS < 1 then timeoutS := 1; if timeoutS > EXEC_MAX_TIMEOUT then timeoutS := EXEC_MAX_TIMEOUT;
    maxKB := Req.Get('max_output_kb', 256); if maxKB < 1 then maxKB := 1; if maxKB > 4096 then maxKB := 4096;
    if SandboxAbi < 1 then
    begin
      resp := TJSONObject.Create(['ok', False, 'error', 'commands are not available here: this machine cannot confine them (needs Linux with Landlock). Nothing was run.', 'sandbox', False]);
      FsAudit(Req, 'exec', resp);
      Exit(resp);
    end;
    envs.Add('PATH=/usr/local/bin:/usr/bin:/bin'); envs.Add('HOME=' + pubRoot); envs.Add('TMPDIR=' + tmpDir); envs.Add('LANG=C.UTF-8');
    envs.Add('TERM=dumb'); envs.Add('NO_COLOR=1'); envs.Add('PWD=' + cwdReal); envs.Add('USER=' + GetEnvironmentVariable('USER'));
    SetLength(argv, 4); argv[0] := '/bin/sh'; argv[1] := '-c'; argv[2] := PChar(cmd); argv[3] := nil;
    SetLength(envp, envs.Count + 1);
    for i := 0 to envs.Count - 1 do envp[i] := PChar(envs[i]);
    envp[envs.Count] := nil;

    if fpPipe(pfd) <> 0 then Exit(TJSONObject.Create(['ok', False, 'error', 'could not start']));
    pid := fpFork;
    if pid < 0 then begin fpClose(pfd[0]); fpClose(pfd[1]); Exit(TJSONObject.Create(['ok', False, 'error', 'could not start'])); end;
    if pid = 0 then
    begin
      // ---- child: confine first, then become the command
      c_setpgid(0, 0);
      fpClose(pfd[0]);
      fpDup2(pfd[1], 1); fpDup2(pfd[1], 2); fpClose(pfd[1]);
      i := fpOpen('/dev/null', O_RDONLY); if i >= 0 then begin fpDup2(i, 0); fpClose(i); end;
      rl.cur := timeoutS + 5; rl.max := timeoutS + 5; c_setrlimit(RLIMIT_CPU_, rl);
      rl.cur := QWord(512) * 1024 * 1024; rl.max := rl.cur; c_setrlimit(RLIMIT_FSIZE_, rl);
      rl.cur := 0; rl.max := 0; c_setrlimit(RLIMIT_CORE_, rl);
      failMsg := ApplySandbox(wr, ro, tmpDir);
      if failMsg <> '' then begin msg := 'COCKPIT_SANDBOX_FAIL ' + failMsg + #10; fpWrite(1, msg[1], Length(msg)); fpExit(125); end;
      if fpChDir(PChar(cwdReal)) <> 0 then begin msg := 'COCKPIT_SANDBOX_FAIL cannot enter the folder' + #10; fpWrite(1, msg[1], Length(msg)); fpExit(125); end;
      fpExecve('/bin/sh', PPChar(@argv[0]), PPChar(@envp[0]));
      fpExit(127);
    end;
    // ---- parent: collect output, enforce the limits
    fpClose(pfd[1]);
    c_setpgid(pid, pid);
    outp := ''; timedOut := False; truncated := False;
    start := GetTickCount64;
    repeat
      fpFD_ZERO(fds); fpFD_SET(pfd[0], fds);
      tv.tv_sec := 0; tv.tv_usec := 200000;
      i := fpSelect(pfd[0] + 1, @fds, nil, nil, @tv);
      if i > 0 then
      begin
        n := fpRead(pfd[0], buf, SizeOf(buf));
        if n <= 0 then Break;
        if Length(outp) < maxKB * 1024 then
        begin
          if Length(outp) + n > maxKB * 1024 then begin n := maxKB * 1024 - Length(outp); truncated := True; end;
          i := Length(outp); SetLength(outp, i + n); Move(buf[0], outp[i + 1], n);
        end
        else truncated := True;
      end;
      if (GetTickCount64 - start) > QWord(timeoutS) * 1000 then begin timedOut := True; Break; end;
      if truncated and (Length(outp) >= maxKB * 1024) and ((GetTickCount64 - start) > 2000) then Break;   // a flood: stop reading, kill below
    until False;
    if timedOut or truncated then fpKill(-pid, SIGKILL);
    fpClose(pfd[0]);
    status := 0;
    fpWaitPid(pid, status, 0);
    fpKill(-pid, SIGKILL);                       // anything it left behind
    if wifexited(status) then exitCode := wexitstatus(status)
    else if wifsignaled(status) then exitCode := 128 + wtermsig(status)
    else exitCode := -1;
    if (exitCode = 125) and (Pos('COCKPIT_SANDBOX_FAIL', outp) = 1) then
    begin
      resp := TJSONObject.Create(['ok', False, 'error', Trim(Copy(outp, 22, MaxInt)) + '. Nothing was run.', 'sandbox', False]);
      FsAudit(Req, 'exec', resp);
      Exit(resp);
    end;
    resp := TJSONObject.Create(['ok', True, 'exit', exitCode, 'output', outp, 'timed_out', timedOut, 'truncated', truncated, 'cwd', cwdPath]);
    Req.Add('cmd_logged', Copy(cmd, 1, 300));
    FsAudit(Req, 'exec', resp);
    Result := resp;
  finally
    wr.Free; ro.Free; envs.Free;
  end;
end;

end.
