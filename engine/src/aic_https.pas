(* =============================================================================
  aic_https — a small HTTP/1.1 client for http:// and https:// (the latter through aic_tls).

    HttpsRequest(method, url, body, headers, timeoutS, cafile, resolveIp) -> status, body, error text

  What curl -s gives the agent loop, and no more: no redirects, no cookies, no proxies, one request per connection ("Connection:
  close"). A complete response needs a status line; the body is whatever the server sends: chunked, Content-Length or until the
  server closes. The whole call, connect to last byte, is held to one deadline. A body over MaxBody is refused, not truncated.
  `resolveIp` (when not empty) replaces the DNS lookup, like curl --resolve: for tests and for pinning.
  ============================================================================= *)
unit aic_https;

{$mode objfpc}{$H+}

interface

uses
  Classes;

const
  HTTPS_MAX_BODY = 64 * 1024 * 1024;

type
  THttpsResult = record
    Ok: Boolean;           // a complete HTTP response arrived (any status)
    Status: Integer;
    Body: string;
    Err: string;           // why not, when Ok is false
    Location: string;      // the Location header of a redirect, when there is one
    ContentType: string;   // the Content-Type header, when there is one
  end;

function HttpsRequest(const Method, Url, Body: string; Headers: TStrings; TimeoutS: Integer;
  const CaFile, ResolveIp: string): THttpsResult;

implementation

uses
  SysUtils, BaseUnix, Unix, Sockets, netdb, aic_tls;

function NowMs: QWord;
begin
  Result := GetTickCount64;
end;

function LeftMs(Deadline: QWord): Integer;
var
  l: Int64;
begin
  l := Int64(Deadline) - Int64(NowMs);
  if l < 0 then l := 0;
  if l > 2000000000 then l := 2000000000;
  Result := Integer(l);
end;

{ connect with a deadline; returns the socket (non-blocking) or -1 and Err }
function ConnectTo(const Ip: string; Port: Integer; Deadline: QWord; out Err: string): Integer;
var
  fd: cint;
  addr: TInetSockAddr;
  rc: cint;
  pfd: TPollFd;
  so: cint;
  sl: TSockLen;
begin
  Result := -1; Err := '';
  fd := fpSocket(AF_INET, SOCK_STREAM, 0);
  if fd < 0 then begin Err := 'cannot create a socket'; Exit; end;
  fpFcntl(fd, F_SETFL, fpFcntl(fd, F_GETFL) or O_NONBLOCK);
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(Word(Port));
  addr.sin_addr := StrToNetAddr(Ip);
  if addr.sin_addr.s_addr = 0 then begin Err := 'bad address ' + Ip; fpClose(fd); Exit; end;
  rc := fpConnect(fd, @addr, SizeOf(addr));
  if (rc < 0) and (fpGetErrno = ESysEINPROGRESS) then
  begin
    pfd.fd := fd; pfd.events := POLLOUT; pfd.revents := 0;
    repeat rc := fpPoll(@pfd, 1, LeftMs(Deadline)); until (rc >= 0) or (fpGetErrno <> ESysEINTR);
    if rc <= 0 then begin Err := 'connection timed out'; fpClose(fd); Exit; end;
    so := 0; sl := SizeOf(so);
    fpGetSockOpt(fd, SOL_SOCKET, SO_ERROR, @so, @sl);
    if so <> 0 then begin Err := 'connection failed (' + SysErrorMessage(so) + ')'; fpClose(fd); Exit; end;
  end
  else if rc < 0 then begin Err := 'connection failed (' + SysErrorMessage(fpGetErrno) + ')'; fpClose(fd); Exit; end;
  Result := fd;
end;

type
  TConn = record
    Fd: cint;
    Tls: Pointer;
    Deadline: QWord;
    Buf: string;             // bytes read ahead
  end;

function ConnWrite(var C: TConn; const S: string): Boolean;
var
  p, n: Integer;
  pfd: TPollFd;
  rc: cint;
begin
  Result := False;
  p := 1;
  while p <= Length(S) do
  begin
    if C.Tls <> nil then n := TlsClientWrite(C.Tls, S[p], Length(S) - p + 1, LeftMs(C.Deadline))
    else
    begin
      n := fpSend(C.Fd, @S[p], Length(S) - p + 1, MSG_NOSIGNAL);
      if (n < 0) and ((fpGetErrno = ESysEAGAIN) or (fpGetErrno = ESysEINTR)) then
      begin
        pfd.fd := C.Fd; pfd.events := POLLOUT; pfd.revents := 0;
        rc := fpPoll(@pfd, 1, LeftMs(C.Deadline));
        if rc <= 0 then Exit;
        Continue;
      end;
    end;
    if n <= 0 then Exit;
    Inc(p, n);
  end;
  Result := True;
end;

{ read some bytes into C.Buf: >0, 0 = closed, -1 = timeout, -2 = error }
function ConnFill(var C: TConn): Integer;
var
  tmp: array[0..16383] of Byte;
  n: Integer;
  pfd: TPollFd;
  rc: cint;
  s: string;
begin
  while True do
  begin
    if LeftMs(C.Deadline) = 0 then Exit(-1);
    if C.Tls <> nil then n := TlsClientRead(C.Tls, tmp, SizeOf(tmp), LeftMs(C.Deadline))
    else
    begin
      pfd.fd := C.Fd; pfd.events := POLLIN; pfd.revents := 0;
      rc := fpPoll(@pfd, 1, LeftMs(C.Deadline));
      if rc = 0 then Exit(-1);
      if rc < 0 then begin if fpGetErrno = ESysEINTR then Continue; Exit(-2); end;
      n := fpRecv(C.Fd, @tmp[0], SizeOf(tmp), 0);
      if (n < 0) and ((fpGetErrno = ESysEAGAIN) or (fpGetErrno = ESysEINTR)) then Continue;
      if n < 0 then Exit(-2);
    end;
    if n > 0 then begin SetString(s, PChar(@tmp[0]), n); C.Buf := C.Buf + s; end;
    Exit(n);
  end;
end;

function ReadLine(var C: TConn; out Line: string): Integer;      // 1 = a line, 0 = closed before one, <0 = timeout/error
var
  p, r: Integer;
begin
  while True do
  begin
    p := Pos(#10, C.Buf);
    if p > 0 then
    begin
      Line := Copy(C.Buf, 1, p - 1);
      Delete(C.Buf, 1, p);
      if (Line <> '') and (Line[Length(Line)] = #13) then SetLength(Line, Length(Line) - 1);
      Exit(1);
    end;
    if Length(C.Buf) > 65536 then Exit(-2);                       // a header line that long is not HTTP
    r := ConnFill(C);
    if r <= 0 then Exit(r);
  end;
end;

procedure SplitUrl(const Url: string; out Https: Boolean; out Host: string; out Port: Integer; out Path: string; out Ok: Boolean);
var
  rest, hp: string;
  p: Integer;
begin
  Ok := False; Https := False; Host := ''; Port := 0; Path := '/';
  if Copy(Url, 1, 8) = 'https://' then begin Https := True; rest := Copy(Url, 9, MaxInt); Port := 443; end
  else if Copy(Url, 1, 7) = 'http://' then begin rest := Copy(Url, 8, MaxInt); Port := 80; end
  else Exit;
  p := Pos('/', rest);
  if p > 0 then begin hp := Copy(rest, 1, p - 1); Path := Copy(rest, p, MaxInt); end else hp := rest;
  if Pos('@', hp) > 0 then Exit;                                   // user:password@ is not supported
  p := Pos(':', hp);
  if p > 0 then begin Port := StrToIntDef(Copy(hp, p + 1, MaxInt), 0); hp := Copy(hp, 1, p - 1); end;
  Host := hp;
  Ok := (Host <> '') and (Port > 0) and (Port < 65536);
end;

function ResolveV4(const Host: string): string;
var
  a: THostAddr;
  he: THostEntry;
begin
  Result := '';
  a := StrToHostAddr(Host);
  if a.s_addr <> 0 then Exit(Host);
  if not ResolveHostByName(Host, he) then Exit;
  Result := NetAddrToStr(he.Addr);
end;

function HttpsRequest(const Method, Url, Body: string; Headers: TStrings; TimeoutS: Integer;
  const CaFile, ResolveIp: string): THttpsResult;
var
  https, ok: Boolean;
  host, path, ip, err, line, req, hn, hv, ctype, tenc: string;
  port, i, r, clen, p: Integer;
  c: TConn;
  chunk: Int64;
  chunked, hasLen: Boolean;
  sizeLine: string;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Ok := False; Result.Body := ''; Result.Err := '';
  SplitUrl(Url, https, host, port, path, ok);
  if not ok then begin Result.Err := 'not a usable URL (http:// or https://host[:port]/path): ' + Url; Exit; end;
  c.Fd := -1; c.Tls := nil; c.Buf := '';
  c.Deadline := NowMs + QWord(TimeoutS) * 1000;
  if https then
  begin
    if not TlsAvailable(err) then begin Result.Err := err; Exit; end;
  end;
  if ResolveIp <> '' then ip := ResolveIp else ip := ResolveV4(host);
  if ip = '' then begin Result.Err := 'cannot resolve ' + host; Exit; end;
  c.Fd := ConnectTo(ip, port, c.Deadline, err);
  if c.Fd < 0 then begin Result.Err := err; Exit; end;
  try
    if https then
    begin
      c.Tls := TlsClientOpen(c.Fd, host, CaFile, LeftMs(c.Deadline), err);
      if c.Tls = nil then begin Result.Err := err; Exit; end;
    end;
    req := Method + ' ' + path + ' HTTP/1.1' + #13#10 + 'Host: ' + host;
    if ((https and (port <> 443)) or (not https and (port <> 80))) then req := req + ':' + IntToStr(port);
    req := req + #13#10 + 'User-Agent: aicengine' + #13#10 + 'Accept: */*' + #13#10 + 'Connection: close' + #13#10;
    ctype := '';
    if Headers <> nil then
      for i := 0 to Headers.Count - 1 do req := req + Headers[i] + #13#10;
    if (Body <> '') or (Method = 'POST') or (Method = 'PUT') then req := req + 'Content-Length: ' + IntToStr(Length(Body)) + #13#10;
    req := req + #13#10;
    if not ConnWrite(c, req) then begin Result.Err := 'could not send the request'; Exit; end;
    if Body <> '' then if not ConnWrite(c, Body) then begin Result.Err := 'could not send the request body'; Exit; end;
    // status line
    r := ReadLine(c, line);
    if r <> 1 then begin if r = -1 then Result.Err := 'timed out waiting for the response' else Result.Err := 'the connection closed before a response'; Exit; end;
    if (Copy(line, 1, 5) <> 'HTTP/') or (Length(line) < 12) then begin Result.Err := 'not an HTTP response: ' + Copy(line, 1, 40); Exit; end;
    Result.Status := StrToIntDef(Copy(line, 10, 3), 0);
    // headers
    chunked := False; hasLen := False; clen := 0; tenc := '';
    while True do
    begin
      r := ReadLine(c, line);
      if r <> 1 then begin Result.Err := 'the response headers were cut off'; Exit; end;
      if line = '' then Break;
      p := Pos(':', line);
      if p > 0 then
      begin
        hn := LowerCase(Trim(Copy(line, 1, p - 1))); hv := Trim(Copy(line, p + 1, MaxInt));
        if hn = 'content-length' then begin clen := StrToIntDef(hv, -1); hasLen := clen >= 0; end
        else if hn = 'transfer-encoding' then chunked := Pos('chunked', LowerCase(hv)) > 0
        else if hn = 'location' then Result.Location := hv
        else if hn = 'content-type' then begin if Result.ContentType = '' then Result.ContentType := hv; end;
      end;
    end;
    // body
    if (Method = 'HEAD') or (Result.Status = 204) or (Result.Status = 304) or ((Result.Status >= 100) and (Result.Status < 200)) then
    begin Result.Ok := True; Exit; end;
    if chunked then
    begin
      while True do
      begin
        r := ReadLine(c, sizeLine);
        if r <> 1 then begin Result.Err := 'the chunked body was cut off'; Exit; end;
        p := Pos(';', sizeLine); if p > 0 then sizeLine := Copy(sizeLine, 1, p - 1);
        chunk := StrToInt64Def('$' + Trim(sizeLine), -1);
        if chunk < 0 then begin Result.Err := 'bad chunk size'; Exit; end;
        if chunk = 0 then
        begin
          while (ReadLine(c, line) = 1) and (line <> '') do ;       // trailers
          Break;
        end;
        if Int64(Length(Result.Body)) + chunk > HTTPS_MAX_BODY then begin Result.Err := 'the response is larger than the limit'; Exit; end;
        while Int64(Length(c.Buf)) < chunk + 2 do
        begin
          r := ConnFill(c);
          if r <= 0 then begin Result.Err := 'the chunked body was cut off'; Exit; end;
        end;
        Result.Body := Result.Body + Copy(c.Buf, 1, chunk);
        Delete(c.Buf, 1, chunk + 2);                                // the chunk and its CRLF
      end;
      Result.Ok := True;
    end
    else if hasLen then
    begin
      if clen > HTTPS_MAX_BODY then begin Result.Err := 'the response is larger than the limit'; Exit; end;
      while Length(c.Buf) < clen do
      begin
        r := ConnFill(c);
        if r <= 0 then begin Result.Err := 'the response body was cut off'; Exit; end;
      end;
      Result.Body := Copy(c.Buf, 1, clen);
      Result.Ok := True;
    end
    else
    begin
      repeat
        r := ConnFill(c);
        if Length(c.Buf) > HTTPS_MAX_BODY then begin Result.Err := 'the response is larger than the limit'; Exit; end;
      until r <= 0;
      if r = -1 then begin Result.Err := 'timed out reading the response'; Exit; end;
      if r < -1 then begin Result.Err := 'read error on the connection'; Exit; end;
      Result.Body := c.Buf;
      Result.Ok := True;                                            // closed by the server = the end of the body (an error close is indistinguishable here, as with curl)
    end;
  finally
    if c.Tls <> nil then TlsClientClose(c.Tls);
    if c.Fd >= 0 then fpClose(c.Fd);
  end;
end;

end.
