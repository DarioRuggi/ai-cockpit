program locked_pc_probe;
{ locked_pc_probe — "Can AI Cockpit's self-supplied edition run on THIS PC?"

  One small .exe, no installer, no admin rights, nothing written outside its own folder and %TEMP%. Copy it to the PC, run it
  (double-click, or from cmd), and send / read the report it prints and saves next to itself (locked_pc_probe_report.txt).

  It answers, with PASS / FAIL / INFO / WARN lines:
    A  what this PC is (Windows version, user, domain, admin or not)
    B  where a program may write (its own folder, %TEMP%, %LOCALAPPDATA% ...)
    C  whether an UNSIGNED program may run from those places  <- the usual gate on locked PCs (AppLocker / WDAC)
    D  what application-control policy the PC advertises, and what PowerShell is allowed to do
    E  whether a program may listen on localhost, and whether the AI services are reachable (directly, or via the proxy)

  What it does NOT test: TLS inspection by a company proxy, content filtering, antivirus reaction to larger programs, or
  anything that needs a login. It sends nothing anywhere: the only network traffic is plain TCP connection attempts
  (no data) to the host names listed in HOSTS below.

  Build (FPC 3.2.2, Windows target):   fpc -Twin64 -Px86_64 locked_pc_probe.pas       (see build.sh for a Linux cross-build)
  Source is deliberately RTL-only (unit Windows, SysUtils): no packages, no third-party code. }
{$mode delphiunicode}
{$H+}
{$apptype console}

uses
  Windows, SysUtils;

const
  VERSION = '1.0 (2026-10-06)';
  { host:port pairs tried with a bare TCP connect }
  HOSTS: array[0..7] of string = (
    'api.anthropic.com:443', 'generativelanguage.googleapis.com:443', 'api.openai.com:443', 'openrouter.ai:443',
    'huggingface.co:443', 'api.groq.com:443', 'cockpit.ruggi.site:443', 'github.com:443');

{ ---- report output --------------------------------------------------------------------------------------------------- }
var
  Report: UnicodeString = '';
  Fails, Warns, Passes: Integer;
  OutH: THandle;
  OutIsConsole: Boolean;

procedure Emit(const S: UnicodeString);
var
  line: UnicodeString;
  written: DWORD;
  bytes: AnsiString;
begin
  line := S + #13#10;
  Report := Report + line;
  if OutH = INVALID_HANDLE_VALUE then Exit;
  if OutIsConsole then
    WriteConsoleW(OutH, PWideChar(line), Length(line), written, nil)
  else
  begin
    bytes := UTF8Encode(line);                  { redirected to a file or pipe: UTF-8 }
    WriteFile(OutH, PAnsiChar(bytes)^, Length(bytes), written, nil);
  end;
end;

procedure Head(const S: UnicodeString);
begin
  Emit('');
  Emit('== ' + S + ' ' + StringOfChar('=', 70 - Length(S)));
end;
procedure Pass(const S: UnicodeString); begin Inc(Passes); Emit('[PASS] ' + S); end;
procedure Fail(const S: UnicodeString); begin Inc(Fails);  Emit('[FAIL] ' + S); end;
procedure Warn(const S: UnicodeString); begin Inc(Warns);  Emit('[WARN] ' + S); end;
procedure Info(const S: UnicodeString); begin Emit('[info] ' + S); end;
procedure Say(const S: UnicodeString);  begin Emit('       ' + S); end;

{ ---- small helpers ----------------------------------------------------------------------------------------------------- }
function Env(const Name: UnicodeString): UnicodeString;
var
  buf: array[0..32767] of WideChar;
  n: DWORD;
begin
  n := GetEnvironmentVariableW(PWideChar(Name), buf, Length(buf));
  if (n = 0) or (n >= Length(buf)) then Result := '' else SetString(Result, buf, n);
end;

function DirOf(const P: UnicodeString): UnicodeString;
var i: Integer;
begin
  i := Length(P);
  while (i > 0) and (P[i] <> '\') do Dec(i);
  Result := Copy(P, 1, i - 1);
end;

function AddSlash(const S: UnicodeString): UnicodeString;
begin
  if (S <> '') and (S[Length(S)] <> '\') then Result := S + '\' else Result := S;
end;

{ can a file be created (and removed) in Dir? }
function CanWrite(const Dir: UnicodeString): Boolean;
var
  f: UnicodeString;
  h: THandle;
begin
  Result := False;
  if (Dir = '') or (GetFileAttributesW(PWideChar(Dir)) = INVALID_FILE_ATTRIBUTES) then Exit;
  f := AddSlash(Dir) + 'lpp_write_test_' + IntToStr(GetCurrentProcessId) + '.tmp';
  h := CreateFileW(PWideChar(f), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  CloseHandle(h);
  DeleteFileW(PWideChar(f));
  Result := True;
end;

{ run a command line, capture stdout+stderr (first 4 KB), wait up to TimeoutMs; ExitCode = -1 if it could not start, -2 on timeout }
function RunCapture(const CmdLine: UnicodeString; TimeoutMs: DWORD; out Output: UnicodeString; out ErrCode: DWORD): Integer;
var
  sa: TSecurityAttributes;
  rd, wr: THandle;
  si: TStartupInfoW;
  pi: TProcessInformation;
  cl: UnicodeString;
  buf: array[0..4095] of AnsiChar;
  got: DWORD;
  total: AnsiString;
  ec: DWORD;
  t0: QWord;
begin
  Output := ''; ErrCode := 0; Result := -1;
  sa.nLength := SizeOf(sa); sa.lpSecurityDescriptor := nil; sa.bInheritHandle := True;
  if not CreatePipe(rd, wr, @sa, 0) then begin ErrCode := GetLastError; Exit; end;
  SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  si.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  si.wShowWindow := SW_HIDE;
  si.hStdOutput := wr; si.hStdError := wr; si.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
  FillChar(pi, SizeOf(pi), 0);
  cl := CmdLine; UniqueString(cl);
  if not CreateProcessW(nil, PWideChar(cl), nil, nil, True, CREATE_NO_WINDOW, nil, nil, si, pi) then
  begin
    ErrCode := GetLastError;
    CloseHandle(rd); CloseHandle(wr);
    Exit;
  end;
  CloseHandle(wr);
  total := '';
  t0 := GetTickCount64;
  repeat
    if WaitForSingleObject(pi.hProcess, 50) = WAIT_OBJECT_0 then Break;
    if GetTickCount64 - t0 > TimeoutMs then begin TerminateProcess(pi.hProcess, 1); Result := -2; Break; end;
  until False;
  { drain what the child wrote }
  while (Length(total) < 4096) and ReadFile(rd, buf, SizeOf(buf), got, nil) and (got > 0) do
    total := total + Copy(AnsiString(PAnsiChar(@buf[0])), 1, got);
  if Result <> -2 then
  begin
    GetExitCodeProcess(pi.hProcess, ec);
    Result := Integer(ec);
  end;
  CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(rd);
  Output := Trim(UnicodeString(UTF8Decode(total)));
end;

function ErrText(Code: DWORD): UnicodeString;
var
  buf: array[0..511] of WideChar;
  n: DWORD;
begin
  n := FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM or FORMAT_MESSAGE_IGNORE_INSERTS, nil, Code, 0, buf, Length(buf), nil);
  if n = 0 then Result := 'error ' + IntToStr(Code)
  else Result := Trim(UnicodeString(Copy(buf, 0, n))) + ' (error ' + IntToStr(Code) + ')';
end;

{ ---- registry ------------------------------------------------------------------------------------------------------------ }
function RegReadStr(Root: HKEY; const Key, Name: UnicodeString; out Value: UnicodeString): Boolean;
var
  h: HKEY;
  typ, size: DWORD;
  buf: array[0..2047] of WideChar;
  dw: DWORD;
begin
  Result := False; Value := '';
  if RegOpenKeyExW(Root, PWideChar(Key), 0, KEY_READ, h) <> ERROR_SUCCESS then Exit;
  size := SizeOf(buf);
  if RegQueryValueExW(h, PWideChar(Name), nil, @typ, PByte(@buf), @size) = ERROR_SUCCESS then
  begin
    if typ = REG_DWORD then begin Move(buf, dw, 4); Value := IntToStr(dw); Result := True; end
    else if (typ = REG_SZ) or (typ = REG_EXPAND_SZ) then begin SetString(Value, buf, size div 2); Value := PWideChar(Value); Result := True; end;
  end;
  RegCloseKey(h);
end;

function RegSubKeys(Root: HKEY; const Key: UnicodeString): UnicodeString;     { comma-separated names, or '' when the key is absent }
var
  h: HKEY;
  i: DWORD;
  buf: array[0..255] of WideChar;
  n: DWORD;
begin
  Result := '';
  if RegOpenKeyExW(Root, PWideChar(Key), 0, KEY_READ, h) <> ERROR_SUCCESS then Exit;
  i := 0;
  repeat
    n := Length(buf);
    if RegEnumKeyExW(h, i, buf, n, nil, nil, nil, nil) <> ERROR_SUCCESS then Break;
    if Result <> '' then Result := Result + ', ';
    Result := Result + UnicodeString(Copy(buf, 0, n));
    Inc(i);
  until False;
  RegCloseKey(h);
end;
function RegKeyExists(Root: HKEY; const Key: UnicodeString): Boolean;
var h: HKEY;
begin
  Result := RegOpenKeyExW(Root, PWideChar(Key), 0, KEY_READ, h) = ERROR_SUCCESS;
  if Result then RegCloseKey(h);
end;

{ ---- winsock, loaded at run time (so the program still starts where the library is blocked) -------------------------------- }
type
  TWSAData = record                       { Win64 layout; the buffer is oversized, we never read it }
    wVersion, wHighVersion: Word;
    pad: array[0..511] of Byte;
  end;
  TSockAddrIn = record
    sin_family: SmallInt;
    sin_port: Word;
    sin_addr: LongWord;
    sin_zero: array[0..7] of Byte;
  end;
  TFdSet = record
    fd_count: LongWord;
    fd_array: array[0..63] of NativeUInt;
  end;
  THostEnt = record
    h_name: PAnsiChar;
    h_aliases: PPAnsiChar;
    h_addrtype: SmallInt;
    h_length: SmallInt;
    h_addr_list: PPAnsiChar;
  end;
  PHostEnt = ^THostEnt;
  TTimeVal = record tv_sec, tv_usec: LongInt; end;
var
  hWS: HMODULE;
  WSAStartup_: function(ver: Word; var d: TWSAData): Integer; stdcall;
  WSACleanup_: function: Integer; stdcall;
  socket_: function(af, typ, proto: Integer): NativeUInt; stdcall;
  closesocket_: function(s: NativeUInt): Integer; stdcall;
  connect_: function(s: NativeUInt; var a: TSockAddrIn; len: Integer): Integer; stdcall;
  bind_: function(s: NativeUInt; var a: TSockAddrIn; len: Integer): Integer; stdcall;
  listen_: function(s: NativeUInt; backlog: Integer): Integer; stdcall;
  accept_: function(s: NativeUInt; a: Pointer; len: Pointer): NativeUInt; stdcall;
  getsockname_: function(s: NativeUInt; var a: TSockAddrIn; var len: Integer): Integer; stdcall;
  getsockopt_: function(s: NativeUInt; level, opt: Integer; v: PAnsiChar; var len: Integer): Integer; stdcall;
  ioctlsocket_: function(s: NativeUInt; cmd: LongInt; var arg: LongWord): Integer; stdcall;
  select_: function(n: Integer; r, w, e: Pointer; var tv: TTimeVal): Integer; stdcall;
  gethostbyname_: function(name: PAnsiChar): PHostEnt; stdcall;
  htons_: function(v: Word): Word; stdcall;
  WSAGetLastError_: function: Integer; stdcall;
const
  INVALID_SOCK = NativeUInt(not 0);
  FIONBIO_ = LongInt($8004667E);
  SOL_SOCKET_ = $FFFF;
  SO_ERROR_ = $1007;

function WSLoad: Boolean;
var d: TWSAData;
begin
  Result := False;
  hWS := LoadLibraryW('ws2_32.dll');
  if hWS = 0 then Exit;
  @WSAStartup_ := GetProcAddress(hWS, 'WSAStartup');   @WSACleanup_ := GetProcAddress(hWS, 'WSACleanup');
  @socket_ := GetProcAddress(hWS, 'socket');           @closesocket_ := GetProcAddress(hWS, 'closesocket');
  @connect_ := GetProcAddress(hWS, 'connect');         @bind_ := GetProcAddress(hWS, 'bind');
  @listen_ := GetProcAddress(hWS, 'listen');           @accept_ := GetProcAddress(hWS, 'accept');
  @getsockname_ := GetProcAddress(hWS, 'getsockname'); @getsockopt_ := GetProcAddress(hWS, 'getsockopt');
  @ioctlsocket_ := GetProcAddress(hWS, 'ioctlsocket'); @select_ := GetProcAddress(hWS, 'select');
  @gethostbyname_ := GetProcAddress(hWS, 'gethostbyname'); @htons_ := GetProcAddress(hWS, 'htons');
  @WSAGetLastError_ := GetProcAddress(hWS, 'WSAGetLastError');
  if not Assigned(WSAStartup_) or not Assigned(connect_) or not Assigned(select_) then Exit;
  Result := WSAStartup_($0202, d) = 0;
end;

{ non-blocking connect with a timeout; 0 = connected, else a WSA error (or -1 for timeout) }
function TcpConnect(const Addr: TSockAddrIn; TimeoutMs: Integer): Integer;
var
  s: NativeUInt;
  nb: LongWord;
  a: TSockAddrIn;
  w, e: TFdSet;
  tv: TTimeVal;
  err, len: Integer;
begin
  s := socket_(2, 1, 6);
  if s = INVALID_SOCK then Exit(WSAGetLastError_());
  nb := 1; ioctlsocket_(s, FIONBIO_, nb);
  a := Addr;
  if connect_(s, a, SizeOf(a)) <> 0 then
  begin
    err := WSAGetLastError_();
    if err <> 10035 then begin closesocket_(s); Exit(err); end;       { WSAEWOULDBLOCK = in progress }
    FillChar(w, SizeOf(w), 0); FillChar(e, SizeOf(e), 0);
    w.fd_count := 1; w.fd_array[0] := s; e.fd_count := 1; e.fd_array[0] := s;
    tv.tv_sec := TimeoutMs div 1000; tv.tv_usec := (TimeoutMs mod 1000) * 1000;
    if select_(0, nil, @w, @e, tv) <= 0 then begin closesocket_(s); Exit(-1); end;
    len := 4; err := 0;
    getsockopt_(s, SOL_SOCKET_, SO_ERROR_, @err, len);
    if err <> 0 then begin closesocket_(s); Exit(err); end;
  end;
  closesocket_(s);
  Result := 0;
end;

function Resolve(const Host: UnicodeString; out Addr: TSockAddrIn): Boolean;
var
  he: PHostEnt;
  p: PAnsiChar;
  h: AnsiString;
begin
  Result := False;
  h := AnsiString(Host);
  he := gethostbyname_(PAnsiChar(h));
  if (he = nil) or (he^.h_addr_list = nil) or (he^.h_addr_list^ = nil) or (he^.h_length <> 4) then Exit;
  p := he^.h_addr_list^;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := 2;
  Move(p^, Addr.sin_addr, 4);
  Result := True;
end;

function AddrStr(const A: TSockAddrIn): UnicodeString;
begin
  Result := IntToStr(A.sin_addr and $FF) + '.' + IntToStr((A.sin_addr shr 8) and $FF) + '.' + IntToStr((A.sin_addr shr 16) and $FF) + '.' + IntToStr(A.sin_addr shr 24);
end;

function WsaText(Code: Integer): UnicodeString;
begin
  case Code of
    -1: Result := 'timed out (nothing answered in the time allowed: a firewall dropping the packets, or no route)';
    10061: Result := 'refused (something answered and said no)';
    10051, 10065: Result := 'no route to the network';
    10013: Result := 'blocked by the PC (access denied)';
    10060: Result := 'timed out';
  else Result := 'winsock error ' + IntToStr(Code);
  end;
end;

{ ---- the checks ------------------------------------------------------------------------------------------------------------ }
var
  ExeDir, ExePath: UnicodeString;
  ProxyHostPort: UnicodeString = '';

procedure CheckBasics;
var
  ver, build: UnicodeString;
  admin: Boolean;
  hShell: HMODULE;
  IsAdmin: function: BOOL; stdcall;
  dom, comp: UnicodeString;
begin
  Head('A. This PC');
  if RegReadStr(HKEY_LOCAL_MACHINE, 'SOFTWARE\Microsoft\Windows NT\CurrentVersion', 'ProductName', ver) then
  begin
    build := '';
    RegReadStr(HKEY_LOCAL_MACHINE, 'SOFTWARE\Microsoft\Windows NT\CurrentVersion', 'CurrentBuild', build);
    if (StrToIntDef(build, 0) >= 22000) and (Pos('Windows 10', ver) = 1) then ver := 'Windows 11' + Copy(ver, 11, MaxInt);   { the registry still says "Windows 10" on Windows 11 }
    Info('Windows: ' + ver);
    if RegReadStr(HKEY_LOCAL_MACHINE, 'SOFTWARE\Microsoft\Windows NT\CurrentVersion', 'DisplayVersion', ver) then Say('version ' + ver);
    Say('build ' + build);
  end;
  Info('User: ' + Env('USERDOMAIN') + '\' + Env('USERNAME') + '   Computer: ' + Env('COMPUTERNAME'));
  dom := UpperCase(Env('USERDOMAIN')); comp := UpperCase(Env('COMPUTERNAME'));
  if (dom <> '') and (dom <> comp) and (dom <> 'WORKGROUP') and (dom <> 'NT AUTHORITY') then Info('The user belongs to a domain/organisation account (' + Env('USERDOMAIN') + '): central policies probably apply.')
  else Info('A local account or workgroup PC: central domain policies are less likely, but local policy can still apply.');
  admin := False;
  hShell := LoadLibraryW('shell32.dll');
  if hShell <> 0 then begin @IsAdmin := GetProcAddress(hShell, 'IsUserAnAdmin'); if Assigned(IsAdmin) then admin := IsAdmin(); end;
  if admin then Info('This user is an administrator (elevated).') else Info('This user is a standard (non-admin) user, as expected for a locked PC.');
  Info('This program: ' + ExePath);
  Info('Probe version ' + VERSION);
end;

procedure CheckWritable;
type TLoc = record N, P: UnicodeString; end;
var
  locs: array[0..4] of TLoc;
  i: Integer;
begin
  Head('B. Where this user may write');
  locs[0].N := 'this folder';           locs[0].P := ExeDir;
  locs[1].N := '%TEMP%';                locs[1].P := Env('TEMP');
  locs[2].N := '%LOCALAPPDATA%';        locs[2].P := Env('LOCALAPPDATA');
  locs[3].N := '%APPDATA%';             locs[3].P := Env('APPDATA');
  locs[4].N := '%USERPROFILE%';         locs[4].P := Env('USERPROFILE');
  for i := 0 to High(locs) do
    if locs[i].P = '' then Info(locs[i].N + ': not set')
    else if CanWrite(locs[i].P) then Pass('can write in ' + locs[i].N + '  (' + locs[i].P + ')')
    else Fail('CANNOT write in ' + locs[i].N + '  (' + locs[i].P + ')');
  Say('Cockpit needs a writable folder of its own for its data (chats, settings). Any PASS above is enough.');
end;

{ copy this program to Dir and run the copy with --child }
function RunCopyFrom(const Dir, Label_: UnicodeString): Boolean;
var
  target, outp: UnicodeString;
  rc: Integer;
  ec: DWORD;
begin
  Result := False;
  if (Dir = '') or not CanWrite(Dir) then begin Info('run-from ' + Label_ + ': skipped (cannot write there)'); Exit; end;
  target := AddSlash(Dir) + 'lpp_child_' + IntToStr(GetCurrentProcessId) + '.exe';
  if not CopyFileW(PWideChar(ExePath), PWideChar(target), False) then
  begin
    Fail('copying this program into ' + Label_ + ' failed: ' + ErrText(GetLastError));
    Say('(security software that removes new .exe files on the spot does this)');
    Exit;
  end;
  rc := RunCapture('"' + target + '" --child', 8000, outp, ec);
  if (rc = 0) and (Pos('CHILD_OK', outp) > 0) then
  begin
    Pass('an UNSIGNED program ran from ' + Label_ + '  (' + Dir + ')'); Result := True;
  end
  else if rc = -1 then
  begin
    Fail('an unsigned program was BLOCKED from running in ' + Label_ + ': ' + ErrText(ec));
    Say('This is what application control (AppLocker / Windows Defender Application Control / Smart App Control) looks like.');
  end
  else if rc = -2 then Warn('the copy in ' + Label_ + ' started but did not finish in 8 s (a security product may be scanning it)')
  else Fail('the copy in ' + Label_ + ' started but did not run properly (exit code ' + IntToStr(rc) + ')');
  DeleteFileW(PWideChar(target));
end;

procedure CheckRunUnsigned;
var
  outp: UnicodeString;
  ec: DWORD;
  rc: Integer;
begin
  Head('C. May an unsigned program run here?  (this decides almost everything)');
  Pass('this probe itself is running from ' + ExeDir + '  (it is an unsigned program)');
  rc := RunCapture('cmd.exe /c echo CMD_OK', 8000, outp, ec);
  if (rc = 0) and (Pos('CMD_OK', outp) > 0) then Pass('can start other programs (cmd.exe)') else Warn('cannot start cmd.exe: ' + ErrText(ec));
  RunCopyFrom(ExeDir, 'this folder (a second copy)');
  RunCopyFrom(Env('TEMP'), '%TEMP%');
  RunCopyFrom(Env('LOCALAPPDATA'), '%LOCALAPPDATA%');
  begin
    Say('How to read this: if it ran from your own folder but NOT from %TEMP% / %LOCALAPPDATA%, the PC allows only chosen folders: ask IT to');
    Say('allow one folder for Cockpit. If it ran from none of them, the PC runs only signed programs: Cockpit would need to be signed (or allowed by hash).');
  end;
end;

procedure CheckPolicy;
var
  subs, v, mode: UnicodeString;
  outp: UnicodeString;
  ec: DWORD;
  rc: Integer;
  c: array[0..4] of UnicodeString;
  i: Integer;
begin
  Head('D. Application-control policy and scripting');
  c[0] := 'Exe'; c[1] := 'Script'; c[2] := 'Dll'; c[3] := 'Msi'; c[4] := 'Appx';
  subs := RegSubKeys(HKEY_LOCAL_MACHINE, 'SOFTWARE\Policies\Microsoft\Windows\SrpV2');
  if subs = '' then Info('AppLocker: no AppLocker rules are defined in the registry (it may still be managed some other way).')
  else
  begin
    Warn('AppLocker rules ARE defined here (rule collections: ' + subs + ').');
    for i := 0 to 4 do
      if RegReadStr(HKEY_LOCAL_MACHINE, 'SOFTWARE\Policies\Microsoft\Windows\SrpV2\' + c[i], 'EnforcementMode', v) then
      begin
        if v = '1' then mode := 'ENFORCED (programs that match no rule are blocked)' else mode := 'audit only (logged, not blocked)';
        Say(c[i] + ' rules: ' + mode);
      end;
  end;
  { WDAC: stock Windows 11 ships built-in .cip policy files (driver block lists), so file presence says nothing. What matters is whether the
    USER-MODE code-integrity policy is enforced, which the DeviceGuard WMI class reports: 0 off, 1 audit, 2 enforced. }
  rc := RunCapture('powershell.exe -NoProfile -NonInteractive -Command "(Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard).UsermodeCodeIntegrityPolicyEnforcementStatus"', 20000, outp, ec);
  if (rc = 0) and (outp = '2') then Warn('Windows Defender Application Control (WDAC) is ENFORCING a user-mode policy: only programs it trusts will run.')
  else if (rc = 0) and (outp = '1') then Warn('WDAC has a user-mode policy in AUDIT mode (it logs what it would block, but blocks nothing yet).')
  else if (rc = 0) and (outp = '0') then Info('WDAC: no user-mode code-integrity policy is enforced.')
  else Info('WDAC: could not be determined (' + IntToStr(rc) + ' ' + outp + ').');
  if RegReadStr(HKEY_LOCAL_MACHINE, 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers', 'DefaultLevel', v) then
  begin
    if v = '0' then Warn('Software Restriction Policy: default level DISALLOWED: everything not allowed by a path/publisher rule is blocked.')
    else Info('Software Restriction Policy default level = ' + v + '  (262144 = Unrestricted: nothing blocked by default)');
  end;
  if RegReadStr(HKEY_LOCAL_MACHINE, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'SmartScreenEnabled', v) then Info('SmartScreen setting: ' + v);
  if RegReadStr(HKEY_LOCAL_MACHINE, 'SYSTEM\CurrentControlSet\Control\CI\Policy', 'VerifiedAndReputablePolicyState', v) then
    Info('Smart App Control state: ' + v + '  (1 = on: only reputable/signed programs run, 2 = evaluation)');
  rc := RunCapture('powershell.exe -NoProfile -NonInteractive -Command "$ExecutionContext.SessionState.LanguageMode"', 15000, outp, ec);
  if rc = -1 then Info('PowerShell cannot be started: ' + ErrText(ec))
  else if rc = -2 then Info('PowerShell started but did not answer in 15 s')
  else
  begin
    Info('PowerShell language mode: ' + outp);
    if Pos('Constrained', outp) > 0 then Warn('PowerShell is in Constrained Language Mode (typical where application control is enforced): scripts are heavily limited.');
  end;
  rc := RunCapture('powershell.exe -NoProfile -NonInteractive -Command "Get-ExecutionPolicy -List | Out-String -Width 120"', 15000, outp, ec);
  if rc >= 0 then begin Info('PowerShell execution policy:'); Say(StringReplace(outp, #13#10, #13#10 + '       ', [rfReplaceAll])); end;
end;

procedure CheckProxy;
var
  v, srv: UnicodeString;
  p: Integer;
begin
  Info('Proxy settings:');
  if RegReadStr(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Internet Settings', 'ProxyEnable', v) then Say('ProxyEnable = ' + v);
  if RegReadStr(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Internet Settings', 'ProxyServer', srv) then
  begin
    Say('ProxyServer = ' + srv);
    p := Pos(';', srv); if p > 0 then srv := Copy(srv, 1, p - 1);
    p := Pos('=', srv); if p > 0 then srv := Copy(srv, p + 1, MaxInt);
    p := Pos('://', srv); if p > 0 then srv := Copy(srv, p + 3, MaxInt);
    ProxyHostPort := srv;
  end;
  if RegReadStr(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Internet Settings', 'AutoConfigURL', v) then Say('AutoConfigURL (PAC script) = ' + v);
  if Env('HTTPS_PROXY') <> '' then Say('HTTPS_PROXY = ' + Env('HTTPS_PROXY'));
  if Env('HTTP_PROXY') <> '' then Say('HTTP_PROXY = ' + Env('HTTP_PROXY'));
  if (ProxyHostPort = '') and (Env('HTTPS_PROXY') = '') then Say('(no proxy configured for this user)');
end;

procedure CheckNetwork;
var
  a, la: TSockAddrIn;
  ls, cs: NativeUInt;
  len, rc, i, p: Integer;
  host, hp: UnicodeString;
  port: Integer;
  nb: LongWord;
  r: TFdSet;
  tv: TTimeVal;
  ok: Integer;
begin
  Head('E. Network');
  if not WSLoad then begin Fail('Winsock could not be started: the network stack is not available to this program.'); Exit; end;
  { 1. listen on localhost }
  ls := socket_(2, 1, 6);
  if ls = INVALID_SOCK then Fail('cannot create a socket: ' + WsaText(WSAGetLastError_()))
  else
  begin
    FillChar(la, SizeOf(la), 0); la.sin_family := 2; la.sin_addr := $0100007F; la.sin_port := 0;
    if (bind_(ls, la, SizeOf(la)) <> 0) or (listen_(ls, 4) <> 0) then Fail('cannot listen on 127.0.0.1: ' + WsaText(WSAGetLastError_()) + '  (a local web server such as Cockpit needs this)')
    else
    begin
      len := SizeOf(la); getsockname_(ls, la, len);
      p := htons_(la.sin_port);
      rc := TcpConnect(la, 2000);
      if rc = 0 then Pass('can listen on 127.0.0.1 (port ' + IntToStr(p) + ') and connect to it: a local web server will work')
      else Fail('listened on 127.0.0.1:' + IntToStr(p) + ' but could not connect to it: ' + WsaText(rc) + ' (a personal firewall in the way)');
    end;
    closesocket_(ls);
  end;
  { 2. is a local Ollama running? }
  FillChar(a, SizeOf(a), 0); a.sin_family := 2; a.sin_addr := $0100007F; a.sin_port := htons_(11434);
  if TcpConnect(a, 800) = 0 then Info('Something is listening on 127.0.0.1:11434 (the usual Ollama port): local models would be reachable.')
  else Info('Nothing on 127.0.0.1:11434 (no local Ollama running; fine).');
  { 3. proxy, then the AI hosts }
  CheckProxy;
  if ProxyHostPort <> '' then
  begin
    p := Pos(':', ProxyHostPort);
    if p > 0 then begin host := Copy(ProxyHostPort, 1, p - 1); port := StrToIntDef(Copy(ProxyHostPort, p + 1, 6), 8080); end
    else begin host := ProxyHostPort; port := 8080; end;
    if Resolve(host, a) then
    begin
      a.sin_port := htons_(port);
      rc := TcpConnect(a, 4000);
      if rc = 0 then Pass('the configured proxy answers (' + host + ':' + IntToStr(port) + ')') else Warn('the configured proxy does not answer (' + host + ':' + IntToStr(port) + '): ' + WsaText(rc));
    end
    else Warn('the proxy host name does not resolve: ' + host);
  end;
  Emit('');
  Info('Reaching the AI services (a bare TCP connection, no data sent):');
  ok := 0;
  for i := 0 to High(HOSTS) do
  begin
    hp := UnicodeString(HOSTS[i]);
    p := Pos(':', hp);
    host := Copy(hp, 1, p - 1); port := StrToIntDef(Copy(hp, p + 1, 6), 443);
    if not Resolve(host, a) then Warn(host + ': the name does not resolve (DNS blocked, or only a proxy can resolve it)')
    else
    begin
      a.sin_port := htons_(port);
      rc := TcpConnect(a, 4000);
      if rc = 0 then begin Inc(ok); Pass(host + ':' + IntToStr(port) + ' reachable directly  (' + AddrStr(a) + ')'); end
      else Warn(host + ':' + IntToStr(port) + ' ' + WsaText(rc) + '  (' + AddrStr(a) + ')');
    end;
  end;
  if ok = 0 then
  begin
    if ProxyHostPort <> '' then Say('Nothing is reachable directly, but a proxy is configured: traffic must go through it (Cockpit would need proxy support, and the proxy may inspect or block it).')
    else Say('Nothing is reachable directly and no proxy is configured: outbound access to AI services is blocked on this network.');
  end;
  if WSACleanup_() = 0 then ;
end;

procedure Summary;
begin
  Head('Summary');
  Emit(IntToStr(Passes) + ' passed, ' + IntToStr(Warns) + ' warning(s), ' + IntToStr(Fails) + ' failed.');
  Emit('');
  Emit('What it means for AI Cockpit''s self-supplied (no-install) edition:');
  Emit('  * Section C is the gate. If a copied program ran from your own folder, Cockpit''s own programs can run there.');
  Emit('  * Section B must show one writable folder (for Cockpit''s data).');
  Emit('  * Section E tells you whether the AI services are reachable at all; Cockpit also has local-only modes (Ollama) that need none of it.');
  Emit('  * Not covered: whether the company allows sending work data to AI services. That is a policy question for you and your IT department.');
  Emit('');
  Emit('Please send this report (locked_pc_probe_report.txt, next to the program) to whoever is helping you.');
end;

procedure SaveReport;
var
  targets: array[0..1] of UnicodeString;
  i: Integer;
  h: THandle;
  bytes: AnsiString;
  written: DWORD;
  bom: array[0..2] of Byte = ($EF, $BB, $BF);
begin
  targets[0] := AddSlash(ExeDir) + 'locked_pc_probe_report.txt';
  targets[1] := AddSlash(Env('TEMP')) + 'locked_pc_probe_report.txt';
  bytes := UTF8Encode(Report);
  for i := 0 to 1 do
  begin
    h := CreateFileW(PWideChar(targets[i]), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if h <> INVALID_HANDLE_VALUE then
    begin
      WriteFile(h, bom, 3, written, nil);                              { UTF-8 byte-order mark, written as raw bytes }
      WriteFile(h, PAnsiChar(bytes)^, Length(bytes), written, nil);
      CloseHandle(h);
      Emit('');
      Emit('Report saved: ' + targets[i]);
      Exit;
    end;
  end;
  Emit('');
  Emit('(The report could not be saved to a file; copy it from this window.)');
end;

var
  mode: DWORD;
  buf: array[0..32767] of WideChar;
  n: DWORD;
begin
  OutH := GetStdHandle(STD_OUTPUT_HANDLE);
  OutIsConsole := (OutH <> INVALID_HANDLE_VALUE) and (OutH <> 0) and GetConsoleMode(OutH, mode);
  n := GetModuleFileNameW(0, buf, Length(buf));
  SetString(ExePath, buf, n);
  ExeDir := DirOf(ExePath);

  if (ParamCount >= 1) and (ParamStr(1) = '--child') then begin Emit('CHILD_OK'); Halt(0); end;

  Emit('AI Cockpit - locked-PC probe ' + VERSION);
  Emit('Run on: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
  CheckBasics;
  CheckWritable;
  CheckRunUnsigned;
  CheckPolicy;
  CheckNetwork;
  Summary;
  SaveReport;
  if OutIsConsole and (ParamCount = 0) then
  begin
    Emit('');
    Emit('Press Enter to close this window.');
    ReadLn;
  end;
end.
