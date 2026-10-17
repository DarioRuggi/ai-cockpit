(* =============================================================================
  srv_http — HTTP/1.1 on a connected socket: strict request parsing, body readers, response writer.

  Strictness is deliberate (this is a security boundary):
    * request line and headers must end in CRLF; a bare LF or CR is a 400;
    * header names are RFC tokens; a header line that starts with space/tab (obsolete line folding) is a 400;
    * Content-Length must be digits only; two different Content-Length values, or Content-Length together with
      Transfer-Encoding, are a 400 (the classic request-smuggling shapes); a Transfer-Encoding other than
      "chunked" is a 501;
    * limits on request line, header block, header count and body size; each has its own status code
      (414, 431, 413) and every read has a deadline (408), so a client that sends one byte a minute holds a
      process for seconds, not forever.

  Reading and writing are blocking calls guarded by poll() deadlines.  One process serves one connection
  (see srv_main), so no state here is shared.
  ============================================================================= *)
unit srv_http;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, StrUtils, DateUtils, Classes, BaseUnix, Sockets, srv_gzip, srv_tls, srv_util;

type
  TLimits = record
    MaxLineBytes: Integer;        // request line
    MaxHeaderBytes: Integer;      // whole header block
    MaxHeaders: Integer;
    MaxBodyBytes: Int64;
    HeaderTimeoutMs: Integer;     // from the first byte of a request to the end of its headers
    BodyIdleMs: Integer;          // between body bytes
    KeepAliveMs: Integer;         // idle wait for the NEXT request
    WriteTimeoutMs: Integer;      // a client that does not read
  end;

  TReadResult = (rrOk, rrEof, rrTimeout, rrError);

  TConn = class
  private
    FBuf: string;
    FPos: Integer;
  public
    Fd: cint;
    PeerIp: string;
    PeerPort: Integer;
    BytesIn, BytesOut: Int64;
    Dead: Boolean;
    Tls: Pointer;                 // the TLS session when the listener is HTTPS
    constructor Create(AFd: cint; const AIp: string; APort: Integer);
    destructor Destroy; override;
    { Switch this connection to TLS (server side): the handshake, within TimeoutMs.  False = it failed; the connection is unusable. }
    function StartTls(TimeoutMs: Integer): Boolean;
    { more bytes into the buffer: >0 got some, 0 peer closed, -1 timed out, -2 error }
    function Fill(TimeoutMs: Integer): Integer;
    function Buffered: Integer;
    function ReadLine(MaxLen, TimeoutMs: Integer; out Line: string; out Why: Integer): TReadResult;   // Line without CRLF; Why 0 ok, 1 too long, 2 bare LF/CR
    function ReadSome(var Buf; Max, TimeoutMs: Integer): Integer;       // up to Max bytes; 0 = EOF, -1 = timeout, -2 = error
    function WriteAll(const S: string; TimeoutMs: Integer): Boolean;
    function WriteRaw(const Buf; Len: Integer; TimeoutMs: Integer): Boolean;
    procedure Close;
  end;

  TRequest = class
  public
    Method, Target, Version, Path, Query, Host: string;
    Hdr: TStringList;             // lower-case name = value; repeated headers joined with ", " (Cookie with "; ")
    ContentLength: Int64;         // -1 when there is no Content-Length
    Chunked, KeepAlive, ExpectContinue, Http10: Boolean;
    constructor Create;
    destructor Destroy; override;
    function H(const Name: string): string;
    function HasBody: Boolean;
  end;

  { Reads the request body once: Content-Length or chunked.  Read returns >0 bytes, 0 at the end,
    or a negative code:  -1 too large (413)  -2 malformed (400)  -3 timeout (408)  -4 connection lost. }
  TBodyReader = class
  private
    FConn: TConn;
    FReq: TRequest;
    FLim: TLimits;
    FLeft: Int64;                 // Content-Length mode: bytes still to read
    FChunkLeft: Int64;            // chunked: bytes left in the current chunk
    FChunkDone: Boolean;
    FTotal: Int64;
    FMax: Int64;
    FAtEnd: Boolean;
    function ReadChunkHeader: Integer;
  public
    constructor Create(AConn: TConn; AReq: TRequest; const ALim: TLimits; AMax: Int64);
    function Read(var Buf; Max: Integer): Integer;
    property Total: Int64 read FTotal;
    property AtEnd: Boolean read FAtEnd;
  end;

function ReadRequest(C: TConn; const L: TLimits; out R: TRequest; out Code: Integer; out Msg: string; FirstTimeoutMs: Integer): TReadResult;
function IsToken(const S: string): Boolean;

{ ---- response ---- }

type
  TResponse = class
  private
    FConn: TConn;
    FReq: TRequest;
    FWriteMs: Integer;
    FChunked, FHeadOnly, FNoBody, FClose: Boolean;
    FExpect, FSent: Int64;
    FGz, FGzStream, FGzEnd: Boolean;
    FGzObj: TGzip;
    function GzipWanted(AStatus: Integer; Headers: TStrings; ContentLength: Int64): Boolean;
    function WriteOut(const Buf; Len: Integer): Boolean;
    function GzFeed(const Buf; Len: Integer): Boolean;
  public
    GzipOn: Boolean;              // set by the router from the config
    GzipMin, GzipLevel: Integer;
    HeadSent: Boolean;
    Status: Integer;
    ServerName: string;
    ExtraHeaders: TStringList;    // added to every response (security headers) unless the response sets the same name
    KeepAlive: Boolean;           // final decision (also false after an error)
    constructor Create(AConn: TConn; AReq: TRequest; AWriteMs: Integer);
    destructor Destroy; override;
    { Send the status line + headers.  ContentLength < 0 = unknown (chunked for HTTP/1.1, close-delimited for 1.0). }
    function Start(AStatus: Integer; Headers: TStrings; ContentLength: Int64): Boolean;
    function Write(const Buf; Len: Integer): Boolean;
    function WriteStr(const S: string): Boolean;
    function Finish: Boolean;
    property Aborted: Boolean read FClose;
  end;

{ A complete small response (error pages, redirects). }
function SimpleResponse(R: TResponse; Status: Integer; const ContentType, Body: string; Extra: TStrings = nil): Boolean;

implementation

{ ---- TConn --------------------------------------------------------------------------------------- }

constructor TConn.Create(AFd: cint; const AIp: string; APort: Integer);
begin
  inherited Create;
  Fd := AFd; PeerIp := AIp; PeerPort := APort;
  FBuf := ''; FPos := 1;
end;

destructor TConn.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TConn.Close;
begin
  if Tls <> nil then begin TlsClose(Tls); Tls := nil; end;
  if Fd >= 0 then begin fpShutdown(Fd, 2); fpClose(Fd); Fd := -1; end;
  Dead := True;
end;

function TConn.StartTls(TimeoutMs: Integer): Boolean;
begin
  fpFcntl(Fd, F_SETFL, fpFcntl(Fd, F_GETFL) or O_NONBLOCK);              // TLS needs non-blocking I/O to honour timeouts
  Tls := TlsAccept(Fd, TimeoutMs);
  Result := Tls <> nil;
  if not Result then Dead := True;
end;

function TConn.Buffered: Integer;
begin
  Result := Length(FBuf) - FPos + 1;
end;

function TConn.Fill(TimeoutMs: Integer): Integer;
var
  pfd: TPollFd;
  tmp: array[0..16383] of Byte;
  n, rc: Integer;
  s: string;
  wantW: Boolean;
  deadline: QWord;
  left: Int64;
begin
  if Fd < 0 then Exit(0);
  if Tls <> nil then
  begin
    deadline := GetTickCount64 + QWord(TimeoutMs);
    while True do
    begin
      n := TlsRead(Tls, tmp[0], SizeOf(tmp), wantW);
      if n > 0 then Break;
      if n = 0 then Exit(0);
      if n = -2 then Exit(-2);
      left := Int64(deadline) - Int64(GetTickCount64);               // would block: wait for the socket, then try again
      if left <= 0 then Exit(-1);
      pfd.fd := Fd; pfd.revents := 0;
      if wantW then pfd.events := POLLOUT else pfd.events := POLLIN;
      repeat
        rc := fpPoll(@pfd, 1, Integer(left));
      until (rc >= 0) or (fpGetErrno <> ESysEINTR);
      if rc = 0 then Exit(-1);
      if rc < 0 then Exit(-2);
    end;
  end
  else
  begin
    pfd.fd := Fd; pfd.events := POLLIN; pfd.revents := 0;
    repeat
      rc := fpPoll(@pfd, 1, TimeoutMs);
    until (rc >= 0) or (fpGetErrno <> ESysEINTR);
    if rc = 0 then Exit(-1);
    if rc < 0 then Exit(-2);
    n := fpRecv(Fd, @tmp[0], SizeOf(tmp), 0);
    if n = 0 then Exit(0);
    if n < 0 then
    begin
      if (fpGetErrno = ESysEAGAIN) or (fpGetErrno = ESysEINTR) then Exit(-1);
      Exit(-2);
    end;
  end;
  if FPos > 1 then begin Delete(FBuf, 1, FPos - 1); FPos := 1; end;
  SetString(s, PChar(@tmp[0]), n);
  FBuf := FBuf + s;
  Inc(BytesIn, n);
  Result := n;
end;

function TConn.ReadLine(MaxLen, TimeoutMs: Integer; out Line: string; out Why: Integer): TReadResult;
var
  p, n: Integer;
  deadline: QWord;
begin
  Line := ''; Why := 0;
  deadline := GetTickCount64 + QWord(TimeoutMs);
  while True do
  begin
    p := PosEx(#10, FBuf, FPos);
    if p > 0 then
    begin
      // the line must end in CRLF, and contain no other CR or LF
      if (p = FPos) or (FBuf[p - 1] <> #13) then begin Why := 2; Exit(rrError); end;
      Line := Copy(FBuf, FPos, p - 1 - FPos);
      if Pos(#13, Line) > 0 then begin Why := 2; Exit(rrError); end;
      FPos := p + 1;
      if Length(Line) > MaxLen then begin Why := 1; Exit(rrError); end;
      Exit(rrOk);
    end;
    if Buffered > MaxLen + 2 then begin Why := 1; Exit(rrError); end;
    if GetTickCount64 >= deadline then Exit(rrTimeout);
    n := Fill(Integer(deadline - GetTickCount64));
    if n = 0 then begin if Buffered > 0 then Exit(rrError) else Exit(rrEof); end;
    if n = -1 then Exit(rrTimeout);
    if n < 0 then Exit(rrError);
  end;
end;

function TConn.ReadSome(var Buf; Max, TimeoutMs: Integer): Integer;
var
  n: Integer;
begin
  if Buffered = 0 then
  begin
    n := Fill(TimeoutMs);
    if n <= 0 then Exit(n);
  end;
  if Max > Buffered then Max := Buffered;
  Move(FBuf[FPos], Buf, Max);
  Inc(FPos, Max);
  Result := Max;
end;

function TConn.WriteRaw(const Buf; Len: Integer; TimeoutMs: Integer): Boolean;
var
  p: PByte;
  n: TSsize;
  pfd: TPollFd;
  rc: Integer;
  wantR: Boolean;
begin
  Result := False;
  if Fd < 0 then Exit;
  p := @Buf;
  while Len > 0 do
  begin
    if Tls <> nil then
    begin
      n := TlsWrite(Tls, p^, Len, wantR);
      if n > 0 then begin Inc(p, n); Dec(Len, n); Inc(BytesOut, n); Continue; end;
      if n = -1 then
      begin
        pfd.fd := Fd; pfd.revents := 0;
        if wantR then pfd.events := POLLIN else pfd.events := POLLOUT;
        repeat rc := fpPoll(@pfd, 1, TimeoutMs); until (rc >= 0) or (fpGetErrno <> ESysEINTR);
        if rc <= 0 then begin Dead := True; Exit; end;
        Continue;
      end;
      Dead := True; Exit;
    end;
    n := fpSend(Fd, p, Len, MSG_NOSIGNAL);
    if n > 0 then begin Inc(p, n); Dec(Len, n); Inc(BytesOut, n); Continue; end;
    if (n < 0) and ((fpGetErrno = ESysEAGAIN) or (fpGetErrno = ESysEINTR)) then
    begin
      pfd.fd := Fd; pfd.events := POLLOUT; pfd.revents := 0;
      rc := fpPoll(@pfd, 1, TimeoutMs);
      if rc <= 0 then begin Dead := True; Exit; end;
      Continue;
    end;
    Dead := True;
    Exit;
  end;
  Result := True;
end;

function TConn.WriteAll(const S: string; TimeoutMs: Integer): Boolean;
begin
  if S = '' then Exit(True);
  Result := WriteRaw(S[1], Length(S), TimeoutMs);
end;

{ ---- TRequest ------------------------------------------------------------------------------------ }

constructor TRequest.Create;
begin
  Hdr := TStringList.Create;
  Hdr.CaseSensitive := True;
  ContentLength := -1;
end;

destructor TRequest.Destroy;
begin
  Hdr.Free;
  inherited Destroy;
end;

function TRequest.H(const Name: string): string;
begin
  Result := Hdr.Values[LowerCase(Name)];
end;

function TRequest.HasBody: Boolean;
begin
  Result := Chunked or (ContentLength > 0);
end;

function IsToken(const S: string): Boolean;
var
  i: Integer;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~']) then Exit(False);
end;

{ ---- request parsing ----------------------------------------------------------------------------- }

function ReadRequest(C: TConn; const L: TLimits; out R: TRequest; out Code: Integer; out Msg: string; FirstTimeoutMs: Integer): TReadResult;
var
  line, name, val, cur: string;
  why, p, count, total: Integer;
  rr: TReadResult;
  i: Integer;
  clSeen: Boolean;
  deadline: QWord;
  te: string;
begin
  R := nil; Code := 0; Msg := '';
  // ---- request line (the keep-alive wait is the first read's timeout) ----
  rr := C.ReadLine(L.MaxLineBytes, FirstTimeoutMs, line, why);
  // tolerate stray empty lines before a request line (RFC 9112 2.2)
  while (rr = rrOk) and (line = '') do rr := C.ReadLine(L.MaxLineBytes, L.HeaderTimeoutMs, line, why);
  if rr = rrEof then Exit(rrEof);
  if rr = rrTimeout then Exit(rrTimeout);
  if rr = rrError then
  begin
    if why = 1 then begin Code := 414; Msg := 'request line too long'; end else begin Code := 400; Msg := 'malformed request line'; end;
    Exit(rrError);
  end;
  deadline := GetTickCount64 + QWord(L.HeaderTimeoutMs);

  R := TRequest.Create;
  try
    // METHOD SP target SP HTTP/x.y
    p := Pos(' ', line);
    if p < 2 then begin Code := 400; Msg := 'malformed request line'; FreeAndNil(R); Exit(rrError); end;
    R.Method := Copy(line, 1, p - 1);
    cur := Copy(line, p + 1, MaxInt);
    p := RPos(' ', cur);
    if p < 2 then begin Code := 400; Msg := 'malformed request line'; FreeAndNil(R); Exit(rrError); end;
    R.Target := Copy(cur, 1, p - 1);
    R.Version := Copy(cur, p + 1, MaxInt);
    if not IsToken(R.Method) then begin Code := 400; Msg := 'bad method'; FreeAndNil(R); Exit(rrError); end;
    if Pos(' ', R.Target) > 0 then begin Code := 400; Msg := 'bad target'; FreeAndNil(R); Exit(rrError); end;
    for i := 1 to Length(R.Target) do
      if (Ord(R.Target[i]) < 33) or (Ord(R.Target[i]) = 127) then begin Code := 400; Msg := 'control character in target'; FreeAndNil(R); Exit(rrError); end;
    if R.Version = 'HTTP/1.1' then R.Http10 := False
    else if R.Version = 'HTTP/1.0' then R.Http10 := True
    else if Copy(R.Version, 1, 5) <> 'HTTP/' then begin Code := 400; Msg := 'malformed request line (no HTTP version)'; FreeAndNil(R); Exit(rrError); end
    else begin Code := 505; Msg := 'only HTTP/1.0 and HTTP/1.1'; FreeAndNil(R); Exit(rrError); end;

    // ---- headers ----
    count := 0; total := 0;
    repeat
      if GetTickCount64 >= deadline then begin FreeAndNil(R); Exit(rrTimeout); end;
      rr := C.ReadLine(L.MaxHeaderBytes, Integer(deadline - GetTickCount64), line, why);
      if rr = rrTimeout then begin FreeAndNil(R); Exit(rrTimeout); end;
      if rr = rrEof then begin FreeAndNil(R); Exit(rrEof); end;
      if rr = rrError then
      begin
        if why = 1 then begin Code := 431; Msg := 'header line too long'; end else begin Code := 400; Msg := 'malformed header line'; end;
        FreeAndNil(R); Exit(rrError);
      end;
      if line = '' then Break;
      Inc(total, Length(line) + 2);
      Inc(count);
      if total > L.MaxHeaderBytes then begin Code := 431; Msg := 'header block too large'; FreeAndNil(R); Exit(rrError); end;
      if count > L.MaxHeaders then begin Code := 431; Msg := 'too many headers'; FreeAndNil(R); Exit(rrError); end;
      if line[1] in [' ', #9] then begin Code := 400; Msg := 'obsolete header line folding is not accepted'; FreeAndNil(R); Exit(rrError); end;
      p := Pos(':', line);
      if p < 2 then begin Code := 400; Msg := 'header without a colon'; FreeAndNil(R); Exit(rrError); end;
      name := LowerCase(Copy(line, 1, p - 1));
      if not IsToken(name) then begin Code := 400; Msg := 'bad header name'; FreeAndNil(R); Exit(rrError); end;
      val := Trim(Copy(line, p + 1, MaxInt));
      for i := 1 to Length(val) do
        if (Ord(val[i]) < 32) and (val[i] <> #9) or (Ord(val[i]) = 127) then begin Code := 400; Msg := 'control character in a header value'; FreeAndNil(R); Exit(rrError); end;
      cur := R.Hdr.Values[name];
      if cur <> '' then
      begin
        if name = 'cookie' then val := cur + '; ' + val
        else if (name = 'content-length') then
        begin
          if cur <> val then begin Code := 400; Msg := 'conflicting Content-Length headers'; FreeAndNil(R); Exit(rrError); end;
          val := cur;
        end
        else if (name = 'host') then begin Code := 400; Msg := 'more than one Host header'; FreeAndNil(R); Exit(rrError); end
        else val := cur + ', ' + val;
      end;
      R.Hdr.Values[name] := val;
    until False;

    // ---- framing ----
    R.Host := R.Hdr.Values['host'];
    if (not R.Http10) and (R.Host = '') then begin Code := 400; Msg := 'HTTP/1.1 requires a Host header'; FreeAndNil(R); Exit(rrError); end;
    te := LowerCase(R.Hdr.Values['transfer-encoding']);
    clSeen := R.Hdr.Values['content-length'] <> '';
    if (te <> '') and clSeen then begin Code := 400; Msg := 'both Transfer-Encoding and Content-Length'; FreeAndNil(R); Exit(rrError); end;
    if te <> '' then
    begin
      if te <> 'chunked' then begin Code := 501; Msg := 'only "chunked" transfer coding'; FreeAndNil(R); Exit(rrError); end;
      R.Chunked := True;
    end
    else if clSeen then
    begin
      val := R.Hdr.Values['content-length'];
      for i := 1 to Length(val) do
        if not (val[i] in ['0'..'9']) then begin Code := 400; Msg := 'bad Content-Length'; FreeAndNil(R); Exit(rrError); end;
      if (Length(val) > 18) then begin Code := 413; Msg := 'Content-Length too large'; FreeAndNil(R); Exit(rrError); end;
      R.ContentLength := StrToInt64Def(val, -1);
      if R.ContentLength < 0 then begin Code := 400; Msg := 'bad Content-Length'; FreeAndNil(R); Exit(rrError); end;
    end;
    val := LowerCase(R.Hdr.Values['connection']);
    if R.Http10 then R.KeepAlive := Pos('keep-alive', val) > 0 else R.KeepAlive := Pos('close', val) = 0;
    R.ExpectContinue := LowerCase(R.Hdr.Values['expect']) = '100-continue';
    if (R.Hdr.Values['expect'] <> '') and not R.ExpectContinue then begin Code := 417; Msg := 'unsupported Expect'; FreeAndNil(R); Exit(rrError); end;
    Result := rrOk;
  except
    FreeAndNil(R);
    raise;
  end;
end;

{ ---- TBodyReader --------------------------------------------------------------------------------- }

constructor TBodyReader.Create(AConn: TConn; AReq: TRequest; const ALim: TLimits; AMax: Int64);
begin
  inherited Create;
  FConn := AConn; FReq := AReq; FLim := ALim; FMax := AMax;
  FLeft := AReq.ContentLength;
  if FLeft < 0 then FLeft := 0;
  FAtEnd := not AReq.HasBody;
end;

function TBodyReader.ReadChunkHeader: Integer;
var
  line: string;
  why, i, p: Integer;
  rr: TReadResult;
  v: Int64;
begin
  rr := FConn.ReadLine(80, FLim.BodyIdleMs, line, why);
  if rr = rrTimeout then Exit(-3);
  if rr = rrEof then Exit(-4);
  if rr = rrError then Exit(-2);
  p := Pos(';', line);
  if p > 0 then line := Copy(line, 1, p - 1);                 // chunk extensions are ignored
  line := Trim(line);
  if (line = '') or (Length(line) > 15) then Exit(-2);
  v := 0;
  for i := 1 to Length(line) do
  begin
    if HexVal(line[i]) < 0 then Exit(-2);
    v := v * 16 + HexVal(line[i]);
  end;
  FChunkLeft := v;
  Result := 0;
end;

function TBodyReader.Read(var Buf; Max: Integer): Integer;
var
  n, h: Integer;
  line: string;
  why: Integer;
  rr: TReadResult;
  tries: Integer;
begin
  if FAtEnd then Exit(0);
  if not FReq.Chunked then
  begin
    if FLeft = 0 then begin FAtEnd := True; Exit(0); end;
    if Int64(Max) > FLeft then Max := Integer(FLeft);
    n := FConn.ReadSome(Buf, Max, FLim.BodyIdleMs);
    if n = 0 then Exit(-4);
    if n = -1 then Exit(-3);
    if n < 0 then Exit(-4);
    Dec(FLeft, n); Inc(FTotal, n);
    Exit(n);
  end;
  // ---- chunked ----
  while True do
  begin
    if FChunkLeft = 0 then
    begin
      if FChunkDone then begin FAtEnd := True; Exit(0); end;
      h := ReadChunkHeader;
      if h < 0 then Exit(h);
      if FChunkLeft = 0 then
      begin
        // the last chunk: read (and discard) trailer lines up to the empty line
        tries := 0;
        repeat
          rr := FConn.ReadLine(FLim.MaxHeaderBytes, FLim.BodyIdleMs, line, why);
          if rr = rrTimeout then Exit(-3);
          if rr <> rrOk then Exit(-2);
          Inc(tries);
          if tries > 50 then Exit(-2);
        until line = '';
        FChunkDone := True; FAtEnd := True;
        Exit(0);
      end;
    end;
    if Int64(Max) > FChunkLeft then Max := Integer(FChunkLeft);
    n := FConn.ReadSome(Buf, Max, FLim.BodyIdleMs);
    if n = 0 then Exit(-4);
    if n = -1 then Exit(-3);
    if n < 0 then Exit(-4);
    Dec(FChunkLeft, n); Inc(FTotal, n);
    if (FMax > 0) and (FTotal > FMax) then Exit(-1);
    if FChunkLeft = 0 then
    begin
      // the CRLF that ends the chunk data
      rr := FConn.ReadLine(2, FLim.BodyIdleMs, line, why);
      if rr = rrTimeout then Exit(-3);
      if (rr <> rrOk) or (line <> '') then Exit(-2);
    end;
    Exit(n);
  end;
end;

{ Types worth compressing: text, JSON, JavaScript, XML, SVG.  Images, video, archives and fonts are already packed. }
function Compressible(const CT: string): Boolean;
var
  t: string;
  p: Integer;
begin
  t := LowerCase(Trim(CT));
  p := Pos(';', t); if p > 0 then t := Trim(Copy(t, 1, p - 1));
  if t = 'text/event-stream' then Exit(False);             // a stream the browser reads live: never held back
  Result := (Copy(t, 1, 5) = 'text/') or (t = 'application/json') or (t = 'application/javascript') or (t = 'application/xml')
         or (t = 'image/svg+xml') or (t = 'application/manifest+json') or (Copy(t, Length(t) - 4, 5) = '+json') or (Copy(t, Length(t) - 3, 4) = '+xml');
end;
{ ---- TResponse ----------------------------------------------------------------------------------- }

constructor TResponse.Create(AConn: TConn; AReq: TRequest; AWriteMs: Integer);
begin
  inherited Create;
  FConn := AConn; FReq := AReq; FWriteMs := AWriteMs;
  ExtraHeaders := TStringList.Create;
  ServerName := 'aicserver';
  KeepAlive := Assigned(AReq) and AReq.KeepAlive;
  FHeadOnly := Assigned(AReq) and (AReq.Method = 'HEAD');
end;

destructor TResponse.Destroy;
begin
  FGzObj.Free;
  ExtraHeaders.Free;
  inherited Destroy;
end;

{ Should this response be gzipped?  Only a plain 200 for a client that asked, a compressible type, nothing already encoded,
  and either a stream (unknown length) or something big enough to be worth it.  Ranges (206), HEAD, 304 and HTTP/1.0 are left alone. }
function TResponse.GzipWanted(AStatus: Integer; Headers: TStrings; ContentLength: Int64): Boolean;
var
  i, p: Integer;
  ct, enc, ae: string;
begin
  Result := False;
  if (not GzipOn) or (FReq = nil) or FHeadOnly or (AStatus <> 200) or FReq.Http10 then Exit;
  ae := LowerCase(FReq.H('accept-encoding'));
  if (Pos('gzip', ae) = 0) or (Pos('gzip;q=0', StringReplace(ae, ' ', '', [rfReplaceAll])) > 0) then Exit;
  if (ContentLength >= 0) and (ContentLength < GzipMin) then Exit;
  ct := ''; enc := '';
  if Assigned(Headers) then
    for i := 0 to Headers.Count - 1 do
    begin
      p := Pos(':', Headers[i]); if p < 2 then Continue;
      if LowerCase(Copy(Headers[i], 1, p - 1)) = 'content-type' then ct := Copy(Headers[i], p + 1, MaxInt);
      if LowerCase(Copy(Headers[i], 1, p - 1)) = 'content-encoding' then enc := Trim(Copy(Headers[i], p + 1, MaxInt));
    end;
  if enc <> '' then Exit;                                   // the backend chose an encoding (even identity): never stack a second one
  Result := Compressible(ct);
end;

{ Push Len bytes through deflate and out as chunks.  A stream is flushed after each write so the reader sees it now. }
function TResponse.GzFeed(const Buf; Len: Integer): Boolean;
var
  o: string;
begin
  Result := True;
  try
    o := FGzObj.Push(Buf, Len, FGzStream);
  except
    FClose := True; KeepAlive := False; Exit(False);
  end;
  if o <> '' then Result := WriteOut(o[1], Length(o));
end;

function TResponse.Start(AStatus: Integer; Headers: TStrings; ContentLength: Int64): Boolean;
var
  s: string;
  i: Integer;
  seen: TStringList;
  n, v: string;
  p: Integer;
begin
  Result := False;
  if HeadSent then Exit(True);
  Status := AStatus;
  FNoBody := FHeadOnly or (AStatus = 204) or (AStatus = 304) or ((AStatus >= 100) and (AStatus < 200));
  seen := TStringList.Create;
  try
    FGz := GzipWanted(AStatus, Headers, ContentLength);
    s := 'HTTP/1.1 ' + IntToStr(AStatus) + ' ' + StatusText(AStatus) + #13#10;
    s := s + 'Date: ' + HttpDate(LocalTimeToUniversal(Now)) + #13#10;
    if ServerName <> '' then s := s + 'Server: ' + ServerName + #13#10;
    if Assigned(Headers) then
      for i := 0 to Headers.Count - 1 do
      begin
        p := Pos(':', Headers[i]);
        if p < 2 then Continue;
        n := Copy(Headers[i], 1, p - 1); v := Trim(Copy(Headers[i], p + 1, MaxInt));
        if (Pos(#13, v) > 0) or (Pos(#10, v) > 0) then Continue;                    // never let a header value split the response
        if FGz and ((LowerCase(n) = 'content-length') or (LowerCase(n) = 'accept-ranges')) then Continue;   // the compressed size is not known up front
        seen.Add(LowerCase(n));
        s := s + n + ': ' + v + #13#10;
      end;
    for i := 0 to ExtraHeaders.Count - 1 do
    begin
      p := Pos(':', ExtraHeaders[i]);
      if p < 2 then Continue;
      if seen.IndexOf(LowerCase(Copy(ExtraHeaders[i], 1, p - 1))) < 0 then s := s + ExtraHeaders[i] + #13#10;
    end;
    if FGz then
    begin
      s := s + 'Content-Encoding: gzip' + #13#10;
      if seen.IndexOf('vary') < 0 then s := s + 'Vary: Accept-Encoding' + #13#10;
      FGzStream := ContentLength < 0;                       // an unknown length means a live stream: flush after every write
      ContentLength := -1;
      FGzObj := TGzip.Create(GzipLevel); FGzEnd := False;
    end;
    // framing
    FChunked := False;
    if FNoBody and not FHeadOnly then ContentLength := 0
    else if ContentLength < 0 then
    begin
      if Assigned(FReq) and not FReq.Http10 then begin FChunked := True; s := s + 'Transfer-Encoding: chunked' + #13#10; end
      else KeepAlive := False;                                    // HTTP/1.0 and no length: the end of the body is the close
    end;
    if (ContentLength >= 0) and (seen.IndexOf('content-length') < 0) and not ((AStatus = 204) or (AStatus = 304)) then
      s := s + 'Content-Length: ' + IntToStr(ContentLength) + #13#10;
    FExpect := ContentLength; FSent := 0;
    if KeepAlive then s := s + 'Connection: keep-alive' + #13#10 else s := s + 'Connection: close' + #13#10;
    s := s + #13#10;
    HeadSent := True;
    Result := FConn.WriteAll(s, FWriteMs);
    if not Result then begin KeepAlive := False; FClose := True; end;
  finally
    seen.Free;
  end;
end;

function TResponse.Write(const Buf; Len: Integer): Boolean;
begin
  Result := True;
  if (Len <= 0) or FNoBody then Exit;
  if FClose then Exit(False);
  if FGz then Result := GzFeed(Buf, Len) else Result := WriteOut(Buf, Len);
end;

function TResponse.WriteOut(const Buf; Len: Integer): Boolean;
var
  hdr: string;
begin
  Result := True;
  if FChunked then
  begin
    hdr := LowerCase(IntToHex(Len, 1)) + #13#10;
    if not FConn.WriteAll(hdr, FWriteMs) then begin FClose := True; KeepAlive := False; Exit(False); end;
    if not FConn.WriteRaw(Buf, Len, FWriteMs) then begin FClose := True; KeepAlive := False; Exit(False); end;
    if not FConn.WriteAll(#13#10, FWriteMs) then begin FClose := True; KeepAlive := False; Exit(False); end;
  end
  else if not FConn.WriteRaw(Buf, Len, FWriteMs) then begin FClose := True; KeepAlive := False; Exit(False); end;
  Inc(FSent, Len);
end;

function TResponse.WriteStr(const S: string): Boolean;
begin
  if S = '' then Exit(True);
  Result := Write(S[1], Length(S));
end;

function TResponse.Finish: Boolean;
var
  tail: string;
begin
  Result := True;
  if FClose then Exit(False);
  if FGz and (not FNoBody) and (not FGzEnd) then
  begin
    FGzEnd := True;
    tail := FGzObj.Finish;
    if tail <> '' then if not WriteOut(tail[1], Length(tail)) then Exit(False);
  end;
  if FChunked and not FNoBody then Result := FConn.WriteAll('0'#13#10#13#10, FWriteMs);
  if not Result then begin FClose := True; KeepAlive := False; end
  else if (not FChunked) and (FExpect >= 0) and (not FNoBody) and (FSent <> FExpect) then
  begin
    // we promised N bytes and delivered a different number: the framing is broken, the connection must go
    KeepAlive := False; FClose := True; Result := False;
  end;
end;

function SimpleResponse(R: TResponse; Status: Integer; const ContentType, Body: string; Extra: TStrings): Boolean;
var
  h: TStringList;
  i: Integer;
begin
  h := TStringList.Create;
  try
    h.Add('Content-Type: ' + ContentType);
    if Assigned(Extra) then for i := 0 to Extra.Count - 1 do h.Add(Extra[i]);
    Result := R.Start(Status, h, Length(Body));
    if Result then Result := R.WriteStr(Body);
    if Result then Result := R.Finish;
  finally
    h.Free;
  end;
end;

end.
