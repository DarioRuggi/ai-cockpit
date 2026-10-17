(* =============================================================================
  srv_fcgi — a FastCGI client (the web server's side of the conversation with php-cgi / php-fpm).

  One request per backend connection (no multiplexing, FCGI_KEEP_CONN off): BEGIN_REQUEST, the CGI
  parameters as PARAMS records, the request body as STDIN records, then we read STDOUT / STDERR /
  END_REQUEST.

  STREAMING.  Every STDOUT record is passed to the caller the moment it arrives — nothing is collected —
  so a PHP script that echoes and flush()es (server-sent events, a long-running agent answer) reaches the
  browser as it is produced.  The CGI response header block (Status:, Content-Type:, Location:, Set-Cookie: ...)
  is parsed once, handed over through OnHeaders, and everything after it is body.

  NO DEADLOCK.  All writes to the backend go through a pump that also reads whatever the backend has sent, so
  a script that starts answering before it has consumed a large upload cannot stop us.

  OUTCOMES (TFcgiResult) are distinct so the caller can answer correctly:
    frOk              END_REQUEST received
    frConnectFailed   nothing answered at the address                   -> 502
    frTimeout         the backend went silent for IdleMs                 -> 504 (or abort if headers were sent)
    frBackendClosed   the connection ended before END_REQUEST           -> 502, or abort
    frClientGone      OnBody / the client write failed: an ABORT_REQUEST is sent so the script can stop
    frBodyError       the request body could not be read (BodyCode says why)
  ============================================================================= *)
unit srv_fcgi;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, Sockets;

type
  TFcgiAddr = record
    IsUnix: Boolean;
    Host: string;
    Port: Integer;
    Path: string;
  end;

  TFcgiResult = (frOk, frConnectFailed, frTimeout, frBackendClosed, frClientGone, frBodyError, frProtocolError);

  { The caller implements these; the client stays free of any HTTP detail. }
  TFcgiSink = class
  public
    HeadersDone: Boolean;
    BodyCode: Integer;                       // when frBodyError: the reader's negative code
    function OnHeaders(Status: Integer; Headers: TStrings): Boolean; virtual; abstract;     // False = stop (client gone)
    function OnBody(const Buf; Len: Integer): Boolean; virtual; abstract;                   // False = client gone
    procedure OnStderr(const S: string); virtual;
    { next piece of the request body: >0 bytes, 0 = no more, negative = error code }
    function ReadBody(var Buf; Max: Integer): Integer; virtual;
  end;

function ParseFcgiAddr(const S: string; out A: TFcgiAddr): Boolean;           // "127.0.0.1:9000" | "unix:/path/sock"
function FcgiExecute(const A: TFcgiAddr; Params: TStrings; Sink: TFcgiSink; ConnectMs, IdleMs: Integer): TFcgiResult;

implementation

const
  FCGI_BEGIN_REQUEST = 1;
  FCGI_ABORT_REQUEST = 2;
  FCGI_END_REQUEST = 3;
  FCGI_PARAMS = 4;
  FCGI_STDIN = 5;
  FCGI_STDOUT = 6;
  FCGI_STDERR = 7;
  FCGI_RESPONDER = 1;
  REQ_ID = 1;
  MAX_CGI_HEADER = 65536;

procedure TFcgiSink.OnStderr(const S: string);
begin
end;

function TFcgiSink.ReadBody(var Buf; Max: Integer): Integer;
begin
  Result := 0;
end;

function ParseFcgiAddr(const S: string; out A: TFcgiAddr): Boolean;
var
  p: Integer;
begin
  FillChar(A, SizeOf(A), 0);
  Result := False;
  if Copy(S, 1, 5) = 'unix:' then begin A.IsUnix := True; A.Path := Copy(S, 6, MaxInt); Exit(A.Path <> ''); end;
  p := LastDelimiter(':', S);
  if p < 2 then Exit;
  A.Host := Copy(S, 1, p - 1);
  A.Port := StrToIntDef(Copy(S, p + 1, 6), 0);
  if A.Host = 'localhost' then A.Host := '127.0.0.1';
  Result := (A.Port > 0) and (A.Port < 65536);
end;

function Connect(const A: TFcgiAddr; TimeoutMs: Integer): cint;
var
  fd: cint;
  ai: TInetSockAddr;
  au: sockaddr_un;
  fl: cint;
  pfd: TPollFd;
  err: cint;
  elen: TSockLen;
  rc: Integer;
begin
  Result := -1;
  if A.IsUnix then fd := fpSocket(AF_UNIX, SOCK_STREAM, 0) else fd := fpSocket(AF_INET, SOCK_STREAM, 0);
  if fd < 0 then Exit;
  fpFcntl(fd, F_SETFD, 1);                                  // close-on-exec
  fl := fpFcntl(fd, F_GETFL);
  fpFcntl(fd, F_SETFL, fl or O_NONBLOCK);
  if A.IsUnix then
  begin
    FillChar(au, SizeOf(au), 0); au.sun_family := AF_UNIX; StrPCopy(au.sun_path, A.Path);
    rc := fpConnect(fd, @au, SizeOf(au));
  end
  else
  begin
    FillChar(ai, SizeOf(ai), 0); ai.sin_family := AF_INET; ai.sin_port := htons(A.Port); ai.sin_addr := StrToNetAddr(A.Host);
    rc := fpConnect(fd, @ai, SizeOf(ai));
  end;
  if rc <> 0 then
  begin
    if fpGetErrno <> ESysEINPROGRESS then begin fpClose(fd); Exit; end;
    pfd.fd := fd; pfd.events := POLLOUT; pfd.revents := 0;
    if fpPoll(@pfd, 1, TimeoutMs) <= 0 then begin fpClose(fd); Exit; end;
    err := 0; elen := SizeOf(err);
    fpGetSockOpt(fd, SOL_SOCKET, SO_ERROR, @err, @elen);
    if err <> 0 then begin fpClose(fd); Exit; end;
  end;
  Result := fd;
end;

function Rec(AType: Byte; const Content: string): string;
var
  n: Integer;
begin
  n := Length(Content);
  Result := Chr(1) + Chr(AType) + Chr(0) + Chr(REQ_ID) + Chr(n shr 8) + Chr(n and $FF) + Chr(0) + Chr(0) + Content;
end;

function EncLen(n: Integer): string;
begin
  if n < 128 then Result := Chr(n)
  else Result := Chr(((n shr 24) and $7F) or $80) + Chr((n shr 16) and $FF) + Chr((n shr 8) and $FF) + Chr(n and $FF);
end;

function BuildParams(P: TStrings): string;
var
  i: Integer;
  data, all: string;
begin
  all := '';
  for i := 0 to P.Count - 1 do
    all := all + EncLen(Length(P.Names[i])) + EncLen(Length(P.ValueFromIndex[i])) + P.Names[i] + P.ValueFromIndex[i];
  Result := '';
  while Length(all) > 0 do
  begin
    data := Copy(all, 1, 65535);
    Delete(all, 1, Length(data));
    Result := Result + Rec(FCGI_PARAMS, data);
  end;
  Result := Result + Rec(FCGI_PARAMS, '');                  // an empty PARAMS record ends the stream
end;

type
  TPump = class
    Fd: cint;
    Sink: TFcgiSink;
    InBuf: string;                   // bytes read from the backend, not yet parsed into records
    OutQ: string;                    // bytes waiting to be written to the backend
    CgiHead: string;                 // header block being assembled
    Ended, ClientGone, Closed: Boolean;
    LastActivity: QWord;
    procedure Parse;
    procedure Stdout(const Data: string);
    function ReadAvailable(TimeoutMs: Integer): Integer;      // 1 data, 0 nothing yet, -1 closed/error
    function FlushSome(TimeoutMs: Integer): Boolean;
  end;

procedure TPump.Stdout(const Data: string);
var
  p, q, code, i: Integer;
  hdr, body, line, name, val: string;
  hl: TStringList;
begin
  if Data = '' then Exit;
  if Sink.HeadersDone then
  begin
    if not Sink.OnBody(Data[1], Length(Data)) then ClientGone := True;
    Exit;
  end;
  CgiHead := CgiHead + Data;
  // an empty header block: the very first line is blank ("\r\n" or "\n"), everything after it is body
  if (Copy(CgiHead, 1, 2) = #13#10) or (Copy(CgiHead, 1, 1) = #10) then
  begin
    if Copy(CgiHead, 1, 2) = #13#10 then body := Copy(CgiHead, 3, MaxInt) else body := Copy(CgiHead, 2, MaxInt);
    CgiHead := '';
    Sink.HeadersDone := True;
    hl := TStringList.Create;
    try
      if not Sink.OnHeaders(200, hl) then begin ClientGone := True; Exit; end;
    finally
      hl.Free;
    end;
    if body <> '' then if not Sink.OnBody(body[1], Length(body)) then ClientGone := True;
    Exit;
  end;
  p := Pos(#13#10#13#10, CgiHead); q := Pos(#10#10, CgiHead);
  if (p = 0) or ((q > 0) and (q < p)) then
  begin
    if (q > 0) and ((p = 0) or (q < p)) then begin hdr := Copy(CgiHead, 1, q - 1); body := Copy(CgiHead, q + 2, MaxInt); end
    else begin
      if Length(CgiHead) > MAX_CGI_HEADER then begin ClientGone := True; Closed := True; end;   // runaway header block: give up
      Exit;
    end;
  end
  else begin hdr := Copy(CgiHead, 1, p - 1); body := Copy(CgiHead, p + 4, MaxInt); end;
  CgiHead := '';
  hl := TStringList.Create;
  try
    code := 200;
    hdr := StringReplace(hdr, #13#10, #10, [rfReplaceAll]);
    for i := 1 to 1000 do
    begin
      if hdr = '' then Break;
      p := Pos(#10, hdr);
      if p = 0 then begin line := hdr; hdr := ''; end else begin line := Copy(hdr, 1, p - 1); Delete(hdr, 1, p); end;
      q := Pos(':', line);
      if q < 2 then Continue;
      name := Copy(line, 1, q - 1); val := Trim(Copy(line, q + 1, MaxInt));
      if SameText(name, 'Status') then code := StrToIntDef(Copy(val, 1, 3), 200)
      else hl.Add(name + ': ' + val);
    end;
    if code = 200 then
      for i := 0 to hl.Count - 1 do                  // (IndexOfName would look for "Location=", these lines are "Location: ...")
        if SameText(Copy(hl[i], 1, 9), 'Location:') then begin code := 302; Break; end;
    Sink.HeadersDone := True;
    if not Sink.OnHeaders(code, hl) then begin ClientGone := True; Exit; end;
  finally
    hl.Free;
  end;
  if body <> '' then
    if not Sink.OnBody(body[1], Length(body)) then ClientGone := True;
end;

procedure TPump.Parse;
var
  ty, pad: Byte;
  clen: Integer;
  content: string;
begin
  while (Length(InBuf) >= 8) and not ClientGone and not Ended do
  begin
    ty := Ord(InBuf[2]);
    clen := (Ord(InBuf[5]) shl 8) or Ord(InBuf[6]);
    pad := Ord(InBuf[7]);
    if Length(InBuf) < 8 + clen + pad then Break;             // the record is not complete yet
    content := Copy(InBuf, 9, clen);
    Delete(InBuf, 1, 8 + clen + pad);
    case ty of
      FCGI_STDOUT: Stdout(content);
      FCGI_STDERR: Sink.OnStderr(content);
      FCGI_END_REQUEST: Ended := True;
    end;
  end;
end;

function TPump.ReadAvailable(TimeoutMs: Integer): Integer;
var
  pfd: TPollFd;
  tmp: array[0..65535] of Byte;
  n, rc: Integer;
  s: string;
begin
  pfd.fd := Fd; pfd.events := POLLIN; pfd.revents := 0;
  repeat rc := fpPoll(@pfd, 1, TimeoutMs); until (rc >= 0) or (fpGetErrno <> ESysEINTR);
  if rc <= 0 then Exit(0);
  n := fpRecv(Fd, @tmp[0], SizeOf(tmp), 0);
  if n = 0 then Exit(-1);
  if n < 0 then begin if (fpGetErrno = ESysEAGAIN) or (fpGetErrno = ESysEINTR) then Exit(0); Exit(-1); end;
  SetString(s, PChar(@tmp[0]), n);
  InBuf := InBuf + s;
  LastActivity := GetTickCount64;
  Result := 1;
end;

{ Write what the backend will take; wait up to TimeoutMs for it to accept more. }
function TPump.FlushSome(TimeoutMs: Integer): Boolean;
var
  pfd: TPollFd;
  n: TSsize;
  rc: Integer;
begin
  Result := True;
  while OutQ <> '' do
  begin
    n := fpSend(Fd, @OutQ[1], Length(OutQ), MSG_NOSIGNAL);
    if n > 0 then begin Delete(OutQ, 1, n); LastActivity := GetTickCount64; Continue; end;
    if (n < 0) and ((fpGetErrno = ESysEAGAIN) or (fpGetErrno = ESysEINTR)) then
    begin
      pfd.fd := Fd; pfd.events := POLLOUT or POLLIN; pfd.revents := 0;
      rc := fpPoll(@pfd, 1, TimeoutMs);
      if rc <= 0 then Exit;
      if (pfd.revents and POLLIN) <> 0 then
      begin
        // the backend has something to say while we still have a lot to send: read it so neither side blocks
        if ReadAvailable(0) < 0 then begin Closed := True; Exit(False); end;
        Parse;
        if ClientGone or Ended then Exit;
      end;
      Continue;
    end;
    Closed := True;
    Exit(False);
  end;
end;

function FcgiExecute(const A: TFcgiAddr; Params: TStrings; Sink: TFcgiSink; ConnectMs, IdleMs: Integer): TFcgiResult;
var
  P: TPump;
  buf: array[0..32767] of Byte;
  n, rc: Integer;
  s, begin_: string;
  bodyDone: Boolean;
  deadlineNote: QWord;
begin
  Result := frConnectFailed;
  P := TPump.Create;
  try
    P.Sink := Sink;
    P.Fd := Connect(A, ConnectMs);
    if P.Fd < 0 then Exit;
    P.LastActivity := GetTickCount64;
    begin_ := Chr(0) + Chr(FCGI_RESPONDER) + Chr(0) + #0#0#0#0#0;           // role (2 bytes), flags, reserved
    P.OutQ := Rec(FCGI_BEGIN_REQUEST, begin_) + BuildParams(Params);
    if not P.FlushSome(IdleMs) then begin Result := frBackendClosed; Exit; end;

    // ---- the request body, interleaved with whatever the backend sends ----
    bodyDone := False;
    while not bodyDone do
    begin
      if P.ClientGone then begin Result := frClientGone; Break; end;
      if P.Ended or P.Closed then Break;                                  // the backend answered without reading the body
      if Length(P.OutQ) > 262144 then begin if not P.FlushSome(IdleMs) then Break; Continue; end;
      // drain any output first (it may be an early error response)
      rc := P.ReadAvailable(0);
      if rc < 0 then begin P.Closed := True; Break; end;
      P.Parse;
      if P.ClientGone or P.Ended then Break;
      n := Sink.ReadBody(buf, SizeOf(buf));
      if n < 0 then begin Sink.BodyCode := n; Result := frBodyError; P.OutQ := Rec(FCGI_ABORT_REQUEST, ''); P.FlushSome(100); Exit; end;
      if n = 0 then
      begin
        P.OutQ := P.OutQ + Rec(FCGI_STDIN, '');
        bodyDone := True;
      end
      else
      begin
        SetString(s, PChar(@buf[0]), n);
        P.OutQ := P.OutQ + Rec(FCGI_STDIN, s);
      end;
      if not P.FlushSome(IdleMs) then Break;
    end;
    if (not P.ClientGone) and (not P.Ended) and (not P.Closed) then P.FlushSome(IdleMs);

    // ---- the response ----
    P.Parse;
    while (not P.Ended) and (not P.ClientGone) and (not P.Closed) do
    begin
      rc := P.ReadAvailable(200);
      if rc < 0 then begin P.Closed := True; Break; end;
      if rc > 0 then P.Parse;
      if (rc = 0) and (GetTickCount64 - P.LastActivity > QWord(IdleMs)) then begin Result := frTimeout; Exit; end;
    end;
    if P.ClientGone then
    begin
      P.OutQ := Rec(FCGI_ABORT_REQUEST, '');                              // tell the script nobody is listening
      P.FlushSome(100);
      Exit(frClientGone);
    end;
    if P.Ended then Exit(frOk);
    Result := frBackendClosed;
  finally
    if P.Fd >= 0 then fpClose(P.Fd);
    P.Free;
  end;
end;

end.
