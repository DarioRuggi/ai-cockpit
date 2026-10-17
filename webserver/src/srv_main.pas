(* =============================================================================
  srv_main — the request router and the process model.

  PROCESS MODEL  The parent only accepts.  Every connection gets its own forked child that serves requests
  on it (HTTP/1.1 keep-alive) until the client leaves, an error makes the connection unsafe to reuse, or the
  idle/limit rules say stop.  So: blocking code, a crash costs one connection, no threads.  The parent keeps a
  count of live children and answers 503 beyond max_connections.

  ROUTING (in this order)
    1. method: GET HEAD POST PUT DELETE PATCH OPTIONS; anything else 405 (TRACE/CONNECT never)
    2. Host header against allowed_hosts (DNS-rebinding guard)  -> 421
    3. the target is normalised (srv_util): traversal, encoded slashes, NUL, backslashes -> 400
    4. "/" -> root_redirect; the path is matched to a mount (longest prefix on a segment boundary)
    5. deny rules (dotfiles, backups, source files, per-mount globs) -> 404 (a denied file does not exist)
    6. the file is resolved under the mount's root; its REAL path must still be inside the root (symlink
       escape -> 404); directories get a trailing slash (301) and an index file; "/x.php/extra" runs x.php
       with PATH_INFO=/extra
    7. a file with a PHP extension is NEVER served as a file: it goes to FastCGI — except below a
       static_only_dir (uploads, generated output), where it is refused (403) rather than executed
    8. everything else is static (srv_static)
  ============================================================================= *)
unit srv_main;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, StrUtils, Classes, BaseUnix, Sockets, srv_util, srv_http, srv_config, srv_static, srv_fcgi, srv_tls, srv_native;

function RunServer(Cfg: TServerConfig): Integer;
procedure RequestStop;

implementation

const
  VERSION = '0.1.0';

var
  GStop: Boolean;
  GConn: TConn;                    // set in a child: the current connection (for the access log)
  GCfg: TServerConfig;
  GLogFd: cint = -1;

procedure RequestStop;
begin
  GStop := True;
end;

{ ---- access log ---------------------------------------------------------------------------------- }

procedure AccessLog(const Ip, Method, Target: string; Status: Integer; Bytes: Int64; Ms: Int64);
var
  line: string;
begin
  if GLogFd < 0 then Exit;
  line := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ' + Ip + ' "' + Method + ' ' + Copy(Target, 1, 500) + '" ' + IntToStr(Status) + ' ' + IntToStr(Bytes) + ' ' + IntToStr(Ms) + 'ms' + #10;
  fpWrite(GLogFd, line[1], Length(line));                 // one write = one line, even with many children
end;

{ ---- small helpers ------------------------------------------------------------------------------- }

function WantsJson(Req: TRequest; const Path: string): Boolean;
begin
  Result := (Pos('application/json', LowerCase(Req.H('accept'))) > 0) or (LowerCase(ExtractFileExt(Path)) = '.php');
end;

procedure ErrorReply(R: TResponse; Req: TRequest; Code: Integer; const Msg: string; const Path: string = '');
var
  body, ct: string;
  extra: TStringList;
begin
  extra := TStringList.Create;
  try
    if Code = 405 then extra.Add('Allow: GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS');
    if (Code = 400) or (Code = 408) or (Code = 413) or (Code = 414) or (Code = 431) or (Code >= 500) then R.KeepAlive := False;
    if (Req <> nil) and WantsJson(Req, Path) then
    begin
      ct := 'application/json; charset=utf-8';
      body := '{"ok":false,"status":' + IntToStr(Code) + ',"error":"' + StringReplace(StringReplace(Msg, '\', '\\', [rfReplaceAll]), '"', '\"', [rfReplaceAll]) + '"}'#10;
    end
    else
    begin
      ct := 'text/html; charset=utf-8';
      body := '<!doctype html><html><head><meta charset="utf-8"><title>' + IntToStr(Code) + ' ' + StatusText(Code) + '</title></head><body><h1>' + IntToStr(Code) + ' ' +
        StatusText(Code) + '</h1><p>' + HtmlEscape(Msg) + '</p></body></html>'#10;
    end;
    SimpleResponse(R, Code, ct, body, extra);
  finally
    extra.Free;
  end;
end;

function HostPart(const H: string): string;
var
  p: Integer;
begin
  Result := LowerCase(Trim(H));
  if (Result <> '') and (Result[1] = '[') then
  begin
    p := Pos(']', Result);
    if p > 0 then Result := Copy(Result, 1, p);
  end
  else
  begin
    p := Pos(':', Result);
    if p > 0 then Result := Copy(Result, 1, p - 1);
  end;
end;

function HostAllowed(Cfg: TServerConfig; const Host: string): Boolean;
var
  i: Integer;
  h: string;
begin
  if Cfg.AllowedHosts.Count = 0 then Exit(True);
  if Host = '' then Exit(True);                            // HTTP/1.0 without Host: nothing to check
  h := HostPart(Host);
  for i := 0 to Cfg.AllowedHosts.Count - 1 do
    if GlobMatch(LowerCase(Cfg.AllowedHosts[i]), h) then Exit(True);
  Result := False;
end;

function SegmentAllowed(Cfg: TServerConfig; const Seg: string): Boolean;     // exempt from "deny"?
var
  i: Integer;
begin
  for i := 0 to Cfg.Allow.Count - 1 do if GlobMatch(Cfg.Allow[i], Seg) then Exit(True);
  Result := False;
end;

{ A path below a mount is denied when ANY segment matches a deny glob (dotfiles, backups, source...), or the
  whole relative path matches a mount-specific glob.  Matching is case-insensitive. }
function IsDenied(Cfg: TServerConfig; M: TMount; const Rel: string): Boolean;
var
  parts: TStringList;
  i, j: Integer;
  r: string;
begin
  Result := False;
  r := Rel;
  while (r <> '') and (r[1] = '/') do Delete(r, 1, 1);
  parts := TStringList.Create;
  try
    parts.Delimiter := '/'; parts.StrictDelimiter := True; parts.DelimitedText := r;
    for i := 0 to parts.Count - 1 do
    begin
      if parts[i] = '' then Continue;
      if SegmentAllowed(Cfg, parts[i]) then Continue;
      for j := 0 to Cfg.Deny.Count - 1 do
        if GlobMatch(Cfg.Deny[j], parts[i], True) then Exit(True);
    end;
  finally
    parts.Free;
  end;
  for j := 0 to M.Deny.Count - 1 do
    if GlobMatch(M.Deny[j], r, True) then Exit(True);
end;

function IsPhpFile(Cfg: TServerConfig; const Name: string): Boolean;
begin
  Result := Cfg.PhpExt.IndexOf(LowerCase(ExtractFileExt(Name))) >= 0;
end;

function InsideStaticOnly(M: TMount; const Rel: string): Boolean;
var
  parts: TStringList;
  i, j: Integer;
begin
  Result := False;
  parts := TStringList.Create;
  try
    parts.Delimiter := '/'; parts.StrictDelimiter := True; parts.DelimitedText := Rel;
    for i := 0 to parts.Count - 2 do                        // directories only, not the file name itself
      for j := 0 to M.StaticOnly.Count - 1 do
        if SameText(parts[i], M.StaticOnly[j]) then Exit(True);
  finally
    parts.Free;
  end;
end;

function Contained(const RootReal, RealPath: string): Boolean;
begin
  Result := (RealPath = RootReal) or (Copy(RealPath, 1, Length(RootReal) + 1) = IncludeTrailingPathDelimiter(RootReal));
end;

function IsDirectory(const P: string): Boolean;
var
  st: Stat;
begin
  Result := (fpStat(P, st) = 0) and fpS_ISDIR(st.st_mode);
end;

function IsRegular(const P: string): Boolean;
var
  st: Stat;
begin
  Result := (fpStat(P, st) = 0) and fpS_ISREG(st.st_mode);
end;

procedure Redirect(R: TResponse; Code: Integer; const Loc: string);
var
  h: TStringList;
begin
  h := TStringList.Create;
  try
    h.Add('Location: ' + Loc);
    SimpleResponse(R, Code, 'text/plain; charset=utf-8', 'redirecting to ' + Loc + #10, h);
  finally
    h.Free;
  end;
end;

{ ---- PHP through FastCGI ------------------------------------------------------------------------- }

type
  TWebSink = class(TFcgiSink)
  public
    Resp: TResponse;
    Body: TBodyReader;
    Mem: TMemoryStream;              // a chunked request body is buffered here so PHP gets a Content-Length
    function OnHeaders(Status: Integer; Headers: TStrings): Boolean; override;
    function OnBody(const Buf; Len: Integer): Boolean; override;
    function ReadBody(var Buf; Max: Integer): Integer; override;
    procedure OnStderr(const S: string); override;
  end;

function TWebSink.OnHeaders(Status: Integer; Headers: TStrings): Boolean;
var
  h: TStringList;
  i, p: Integer;
  n: string;
  cl: Int64;
begin
  h := TStringList.Create;
  try
    cl := -1;
    for i := 0 to Headers.Count - 1 do
    begin
      p := Pos(':', Headers[i]);
      n := LowerCase(Copy(Headers[i], 1, p - 1));
      // hop-by-hop headers belong to the backend connection, not to ours
      if (n = 'connection') or (n = 'keep-alive') or (n = 'transfer-encoding') or (n = 'upgrade') or (n = 'proxy-authenticate') then Continue;
      if n = 'content-length' then cl := StrToInt64Def(Trim(Copy(Headers[i], p + 1, MaxInt)), -1);
      h.Add(Headers[i]);
    end;
    if (Status < 200) or (Status = 204) or (Status = 304) then cl := 0;
    Result := Resp.Start(Status, h, cl);
  finally
    h.Free;
  end;
end;

function TWebSink.OnBody(const Buf; Len: Integer): Boolean;
begin
  Result := Resp.Write(Buf, Len);
end;

function TWebSink.ReadBody(var Buf; Max: Integer): Integer;
begin
  if Mem <> nil then
  begin
    Result := Mem.Read(Buf, Max);
    Exit;
  end;
  if Body = nil then Exit(0);
  Result := Body.Read(Buf, Max);
end;

procedure TWebSink.OnStderr(const S: string);
begin
  WriteLn(StdErr, FormatDateTime('hh:nn:ss', Now), ' php: ', Trim(S));
  Flush(StdErr);
end;

procedure BuildParams(P: TStrings; Req: TRequest; Conn: TConn; M: TMount; const ScriptFile, ScriptName, PathInfo: string;
  ContentLength: Int64; Cfg: TServerConfig);
var
  i, k: Integer;
  n, v, hn: string;
begin
  P.Add('GATEWAY_INTERFACE=CGI/1.1');
  P.Add('SERVER_SOFTWARE=aicserver/' + VERSION);
  P.Add('SERVER_PROTOCOL=' + Req.Version);
  P.Add('SERVER_NAME=' + HostPart(Req.Host));
  P.Add('SERVER_ADDR=' + Cfg.Host);
  P.Add('SERVER_PORT=' + IntToStr(Cfg.Port));
  if Conn.Tls <> nil then P.Add('HTTPS=on');
  P.Add('REMOTE_ADDR=' + Conn.PeerIp);
  P.Add('REMOTE_PORT=' + IntToStr(Conn.PeerPort));
  P.Add('REQUEST_METHOD=' + Req.Method);
  P.Add('REQUEST_URI=' + Req.Target);
  P.Add('QUERY_STRING=' + Req.Query);
  P.Add('SCRIPT_NAME=' + ScriptName);
  P.Add('SCRIPT_FILENAME=' + ScriptFile);
  P.Add('DOCUMENT_ROOT=' + M.RootReal);
  P.Add('DOCUMENT_URI=' + ScriptName + PathInfo);
  if PathInfo <> '' then begin P.Add('PATH_INFO=' + PathInfo); P.Add('PATH_TRANSLATED=' + M.RootReal + PathInfo); end;
  P.Add('REDIRECT_STATUS=200');                              // php-cgi refuses to run without it
  if Req.H('content-type') <> '' then P.Add('CONTENT_TYPE=' + Req.H('content-type'));
  if ContentLength >= 0 then P.Add('CONTENT_LENGTH=' + IntToStr(ContentLength));
  for i := 0 to Req.Hdr.Count - 1 do
  begin
    n := Req.Hdr.Names[i];
    if (n = 'content-type') or (n = 'content-length') or (n = 'proxy') then Continue;            // "Proxy" would become HTTP_PROXY (httpoxy)
    v := Req.Hdr.ValueFromIndex[i];
    hn := '';
    for k := 1 to Length(n) do
      if n[k] = '-' then hn := hn + '_' else hn := hn + UpCase(n[k]);
    P.Add('HTTP_' + hn + '=' + v);
  end;
end;

procedure RunPhp(R: TResponse; Req: TRequest; Conn: TConn; M: TMount; const ScriptFile, ScriptName, PathInfo: string;
  var BodyRd: TBodyReader; Cfg: TServerConfig; const PreBody: string = '');
var
  addr: TFcgiAddr;
  params: TStringList;
  sink: TWebSink;
  res: TFcgiResult;
  cl: Int64;
  buf: array[0..32767] of Byte;
  n: Integer;
begin
  if not ParseFcgiAddr(Cfg.FcgiAddr, addr) then begin ErrorReply(R, Req, 502, 'PHP backend address is not configured correctly', ScriptName); Exit; end;
  params := TStringList.Create;
  sink := TWebSink.Create;
  try
    sink.Resp := R;
    cl := Req.ContentLength;
    if PreBody <> '' then
    begin
      // the body was read already (the native handler looked at it and passed): hand PHP exactly those bytes
      sink.Mem := TMemoryStream.Create;
      sink.Mem.Write(PreBody[1], Length(PreBody));
      cl := sink.Mem.Size;
      sink.Mem.Position := 0;
    end
    else if Req.Chunked then
    begin
      // PHP wants a Content-Length: buffer a chunked body (bounded by max_body) to learn it
      sink.Mem := TMemoryStream.Create;
      repeat
        n := BodyRd.Read(buf, SizeOf(buf));
        if n > 0 then sink.Mem.Write(buf, n);
      until n <= 0;
      if n < 0 then
      begin
        if n = -1 then ErrorReply(R, Req, 413, 'request body too large') else if n = -3 then ErrorReply(R, Req, 408, 'timed out reading the request body')
        else ErrorReply(R, Req, 400, 'malformed request body');
        sink.Mem.Free; Exit;
      end;
      cl := sink.Mem.Size;
      sink.Mem.Position := 0;
    end
    else if Req.ContentLength > 0 then sink.Body := BodyRd;
    BuildParams(params, Req, Conn, M, ScriptFile, ScriptName, PathInfo, cl, Cfg);
    res := FcgiExecute(addr, params, sink, Cfg.FcgiConnectS * 1000, Cfg.FcgiIdleS * 1000);
    case res of
      frOk:
        if not sink.HeadersDone then ErrorReply(R, Req, 502, 'the PHP backend returned an empty response', ScriptName)
        else R.Finish;
      frConnectFailed: ErrorReply(R, Req, 502, 'the PHP backend is not reachable', ScriptName);
      frTimeout:
        if not sink.HeadersDone then ErrorReply(R, Req, 504, 'the PHP backend did not answer in time', ScriptName)
        else begin R.KeepAlive := False; Conn.Close; end;               // part of the answer is already out: cut the connection
      frBackendClosed, frProtocolError:
        if not sink.HeadersDone then ErrorReply(R, Req, 502, 'the PHP backend closed the connection', ScriptName)
        else begin R.KeepAlive := False; Conn.Close; end;
      frClientGone: begin R.KeepAlive := False; Conn.Close; end;
      frBodyError:
        begin
          R.KeepAlive := False;
          if not sink.HeadersDone then
          begin
            if sink.BodyCode = -1 then ErrorReply(R, Req, 413, 'request body too large')
            else if sink.BodyCode = -3 then ErrorReply(R, Req, 408, 'timed out reading the request body')
            else ErrorReply(R, Req, 400, 'malformed request body');
          end
          else Conn.Close;
        end;
    end;
  finally
    sink.Mem.Free;
    sink.Free;
    params.Free;
  end;
end;

{ ---- one request --------------------------------------------------------------------------------- }

type
  TOutcome = record
    Status: Integer;
  end;

{ Returns False when the connection must be closed afterwards. }
function HandleRequest(Conn: TConn; Req: TRequest; R: TResponse; var BodyRd: TBodyReader; Cfg: TServerConfig): Boolean;
var
  clean, query, err, rest, rel, full, real, scriptRel, pathInfo, idx, cand, accum: string;
  mnt: TMount;
  parts: TStringList;
  i, k: Integer;
  isDir: Boolean;
  loc: string;
  found: Boolean;
  preBody, nativeReply: string;
  got, n2: Integer;
  hdrN: TStringList;
begin
  Result := True;
  // ---- 1. method ----
  if not ((Req.Method = 'GET') or (Req.Method = 'HEAD') or (Req.Method = 'POST') or (Req.Method = 'PUT') or (Req.Method = 'DELETE')
       or (Req.Method = 'PATCH') or (Req.Method = 'OPTIONS')) then
  begin ErrorReply(R, Req, 405, 'method not allowed'); Exit(False); end;
  // ---- 2. host ----
  if not HostAllowed(Cfg, Req.Host) then begin ErrorReply(R, Req, 421, 'this Host is not served here'); Exit(False); end;
  // ---- 3. the target ----
  if not NormalizeTarget(Req.Target, clean, query, err) then begin ErrorReply(R, Req, 400, 'bad request path: ' + err); Exit(False); end;
  Req.Path := clean; Req.Query := query;
  // OPTIONS is answered here (CORS is not offered)
  if Req.Method = 'OPTIONS' then
  begin
    SimpleResponse(R, 204, 'text/plain', '', nil);
    Exit;
  end;
  // ---- 4. mount ----
  if (clean = '/') and (Cfg.RootRedirect <> '') then
  begin
    loc := Cfg.RootRedirect;
    if query <> '' then loc := loc + '?' + query;
    Redirect(R, 302, loc);
    Exit;
  end;
  mnt := Cfg.MountFor(clean, rest);
  if mnt = nil then begin ErrorReply(R, Req, 404, 'not found', clean); Exit; end;
  // ---- 5. deny ----
  if IsDenied(Cfg, mnt, rest) then begin ErrorReply(R, Req, 404, 'not found', clean); Exit; end;

  // ---- 6. resolve: walk the segments; a PHP script may be followed by PATH_INFO ----
  parts := TStringList.Create;
  try
    parts.Delimiter := '/'; parts.StrictDelimiter := True;
    rel := rest;
    while (rel <> '') and (rel[1] = '/') do Delete(rel, 1, 1);
    parts.DelimitedText := rel;
    for i := parts.Count - 1 downto 0 do if parts[i] = '' then parts.Delete(i);
    accum := ''; scriptRel := ''; pathInfo := ''; found := False; isDir := True;
    for i := 0 to parts.Count - 1 do
    begin
      cand := accum + '/' + parts[i];
      full := mnt.RootReal + cand;
      if IsDirectory(full) then begin accum := cand; isDir := True; Continue; end;
      if IsRegular(full) then
      begin
        isDir := False;
        if IsPhpFile(Cfg, parts[i]) then
        begin
          scriptRel := cand; found := True;
          for k := i + 1 to parts.Count - 1 do pathInfo := pathInfo + '/' + parts[k];
          if (rest <> '') and (rest[Length(rest)] = '/') and (pathInfo <> '') then pathInfo := pathInfo + '/';
        end
        else if i = parts.Count - 1 then begin scriptRel := cand; found := True; end;
        Break;
      end;
      ErrorReply(R, Req, 404, 'not found', clean); Exit;             // nothing at this segment
    end;
    if not found then
    begin
      if not isDir then begin ErrorReply(R, Req, 404, 'not found', clean); Exit; end;
      // a directory: redirect to the slash form, then try the index files
      if (rest <> '') and (rest[Length(rest)] <> '/') then
      begin
        loc := clean + '/';
        if query <> '' then loc := loc + '?' + query;
        Redirect(R, 301, loc);
        Exit;
      end;
      for k := 0 to mnt.Index.Count - 1 do
      begin
        cand := accum + '/' + mnt.Index[k];
        if IsRegular(mnt.RootReal + cand) then begin scriptRel := cand; found := True; Break; end;
      end;
      if not found then begin ErrorReply(R, Req, 404, 'no index file here (directory listing is off)', clean); Exit; end;
      pathInfo := '';
    end;

    // ---- containment: the real path must stay inside the mount's root (symlinks!) ----
    real := RealPathOf(mnt.RootReal + scriptRel);
    if (real = '') or not Contained(mnt.RootReal, real) then begin ErrorReply(R, Req, 404, 'not found', clean); Exit; end;
    if IsDenied(Cfg, mnt, scriptRel) then begin ErrorReply(R, Req, 404, 'not found', clean); Exit; end;

    // ---- 7/8. PHP or static ----
    if IsPhpFile(Cfg, scriptRel) then
    begin
      if InsideStaticOnly(mnt, scriptRel) then begin ErrorReply(R, Req, 403, 'scripts are not executed in this folder', clean); Exit; end;
      // native handlers (srv_native): answered here only when provably what PHP would answer; otherwise the body read so far goes on to PHP
      if Cfg.NativePoll and (Req.Method = 'POST') and (scriptRel = '/bridge.php') and not Req.Chunked and (Req.ContentLength > 0) and (Req.ContentLength <= 65536) then
      begin
        preBody := ''; SetLength(preBody, Req.ContentLength); got := 0;
        while got < Req.ContentLength do
        begin
          n2 := BodyRd.Read(preBody[got + 1], Req.ContentLength - got);
          if n2 <= 0 then Break;
          got := got + n2;
        end;
        if got <> Req.ContentLength then
        begin
          R.KeepAlive := False;
          if n2 = -3 then ErrorReply(R, Req, 408, 'timed out reading the request body') else ErrorReply(R, Req, 400, 'malformed request body');
          Exit(False);
        end;
        if NativeBridgePoll(mnt.RootReal, Cfg.NativeSessionDir, Cfg.NativeSupDir, Cfg.NativeSessionDays, Req.H('cookie'), preBody, nativeReply) then
        begin
          hdrN := TStringList.Create;
          try
            hdrN.Add('X-Aic-Native: bridge-poll');
            hdrN.Add('Expires: Thu, 19 Nov 1981 08:52:00 GMT'); hdrN.Add('Cache-Control: no-store, no-cache, must-revalidate'); hdrN.Add('Pragma: no-cache');
            SimpleResponse(R, 200, 'application/json', nativeReply, hdrN);
          finally
            hdrN.Free;
          end;
          Exit(R.KeepAlive);
        end;
        RunPhp(R, Req, Conn, mnt, real, mnt.Prefix + scriptRel, pathInfo, BodyRd, Cfg, preBody);
        Exit(R.KeepAlive);
      end;
      RunPhp(R, Req, Conn, mnt, real, mnt.Prefix + scriptRel, pathInfo, BodyRd, Cfg);
      Exit(R.KeepAlive);
    end;
    if (Req.Method <> 'GET') and (Req.Method <> 'HEAD') then begin ErrorReply(R, Req, 405, 'static files accept GET and HEAD only'); Exit; end;
    if pathInfo <> '' then begin ErrorReply(R, Req, 404, 'not found', clean); Exit; end;
    case ServeFile(R, Req, real, scriptRel, Cfg) of
      srNotFound: ErrorReply(R, Req, 404, 'not found', clean);
      srAborted: Exit(False);
    end;
  finally
    parts.Free;
  end;
end;

{ ---- one connection ------------------------------------------------------------------------------ }

procedure ServeConnection(Conn: TConn; Cfg: TServerConfig);
var
  req: TRequest;
  resp: TResponse;
  code, count: Integer;
  msg: string;
  rr: TReadResult;
  bodyRd: TBodyReader;
  t0: QWord;
  drain: array[0..8191] of Byte;
  n, tries: Integer;
  keep: Boolean;
  startOut: Int64;
begin
  count := 0;
  while True do
  begin
    req := nil;
    rr := ReadRequest(Conn, Cfg.Lim, req, code, msg, Cfg.Lim.KeepAliveMs);
    if rr = rrEof then Break;
    if rr = rrTimeout then
    begin
      if count = 0 then begin resp := TResponse.Create(Conn, nil, Cfg.Lim.WriteTimeoutMs); try resp.KeepAlive := False; ErrorReply(resp, nil, 408, 'request timed out'); finally resp.Free; end; end;
      Break;
    end;
    if rr = rrError then
    begin
      resp := TResponse.Create(Conn, nil, Cfg.Lim.WriteTimeoutMs);
      try
        resp.KeepAlive := False;
        resp.ExtraHeaders.AddStrings(Cfg.Headers);
        resp.GzipOn := Cfg.GzipOn; resp.GzipMin := Cfg.GzipMin; resp.GzipLevel := Cfg.GzipLevel;
        ErrorReply(resp, nil, code, msg);
        AccessLog(Conn.PeerIp, '-', '-', code, 0, 0);
      finally
        resp.Free;
      end;
      Break;
    end;
    Inc(count);
    t0 := GetTickCount64;
    startOut := Conn.BytesOut;
    resp := TResponse.Create(Conn, req, Cfg.Lim.WriteTimeoutMs);
    bodyRd := TBodyReader.Create(Conn, req, Cfg.Lim, Cfg.Lim.MaxBodyBytes);
    try
      resp.ServerName := Cfg.ServerName;
      resp.ExtraHeaders.AddStrings(Cfg.Headers);
      resp.GzipOn := Cfg.GzipOn; resp.GzipMin := Cfg.GzipMin; resp.GzipLevel := Cfg.GzipLevel;
      if count >= Cfg.MaxRequestsPerConn then resp.KeepAlive := False;
      // a declared body over the limit is refused BEFORE it is read
      if (req.ContentLength > Cfg.Lim.MaxBodyBytes) then
      begin
        ErrorReply(resp, req, 413, 'request body too large (limit ' + IntToStr(Cfg.Lim.MaxBodyBytes div 1048576) + ' MB)');
        keep := False;
      end
      else
      begin
        if req.ExpectContinue and req.HasBody then Conn.WriteAll('HTTP/1.1 100 Continue'#13#10#13#10, Cfg.Lim.WriteTimeoutMs);
        keep := HandleRequest(Conn, req, resp, bodyRd, Cfg) and resp.KeepAlive;
      end;
      if not resp.HeadSent then
      begin
        ErrorReply(resp, req, 500, 'internal error: no response was produced');
        keep := False;
      end;
      AccessLog(Conn.PeerIp, req.Method, req.Target, resp.Status, Conn.BytesOut - startOut, Int64(GetTickCount64 - t0));
      // an unread request body must be consumed (or the connection dropped), or the next request is garbage
      if keep and req.HasBody and not bodyRd.AtEnd then
      begin
        tries := 0;
        repeat
          n := bodyRd.Read(drain, SizeOf(drain));
          Inc(tries);
        until (n <= 0) or (tries > 64);
        if (n < 0) or not bodyRd.AtEnd then keep := False;
      end;
      if Conn.Dead then keep := False;
    finally
      bodyRd.Free;
      resp.Free;
      req.Free;
    end;
    if not keep then Break;
  end;
end;

{ ---- the accept loop ----------------------------------------------------------------------------- }

procedure OnTermSignal(Sig: cint); cdecl;
begin
  GStop := True;
end;

function RunServer(Cfg: TServerConfig): Integer;
var
  lfd, cfd: cint;
  addr: TInetSockAddr;
  peer: TInetSockAddr;
  alen: TSockLen;
  one: cint;
  pfd: TPollFd;
  children, i, k: Integer;
  pid: TPid;
  kids: TList;
  st: cint;
  conn: TConn;
  t0: QWord;
  r: TResponse;
  req0: TRequest;
  tlsErr: string;
begin
  Result := 0;
  GCfg := Cfg;
  if Cfg.TlsCert <> '' then
    if not TlsInit(Cfg.TlsCert, Cfg.TlsKey, tlsErr) then begin WriteLn(StdErr, 'aicserver: TLS: ', tlsErr); Exit(1); end;
  lfd := fpSocket(AF_INET, SOCK_STREAM, 0);
  one := 1;
  fpSetSockOpt(lfd, SOL_SOCKET, SO_REUSEADDR, @one, SizeOf(one));
  fpFcntl(lfd, F_SETFD, 1);
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET; addr.sin_port := htons(Cfg.Port); addr.sin_addr := StrToNetAddr(Cfg.Host);
  if (fpBind(lfd, @addr, SizeOf(addr)) <> 0) or (fpListen(lfd, 128) <> 0) then
  begin
    WriteLn(StdErr, 'aicserver: cannot listen on ', Cfg.Host, ':', Cfg.Port, ' (is it in use?)');
    Exit(1);
  end;
  if Cfg.AccessLog <> '' then
  begin
    ForceDirectories(ExtractFilePath(Cfg.AccessLog));
    GLogFd := fpOpen(Cfg.AccessLog, O_WRONLY or O_CREAT or O_APPEND, &640);
  end;
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  fpSignal(SIGTERM, @OnTermSignal);
  fpSignal(SIGINT, @OnTermSignal);
  WriteLn(StdErr, 'aicserver ', VERSION, ' listening on ', Cfg.Host, ':', Cfg.Port, IfThen(Cfg.TlsCert <> '', ' HTTPS', ''), '  (', Cfg.Mounts.Count, ' mounts, php=', Cfg.FcgiAddr, ')');
  Flush(StdErr);
  children := 0;
  kids := TList.Create;

  while not GStop do
  begin
    // reap finished connection processes
    repeat
      pid := fpWaitPid(-1, st, WNOHANG);
      if pid > 0 then begin Dec(children); k := kids.IndexOf(Pointer(PtrInt(pid))); if k >= 0 then kids.Delete(k); end;
    until pid <= 0;
    pfd.fd := lfd; pfd.events := POLLIN; pfd.revents := 0;
    if fpPoll(@pfd, 1, 200) <= 0 then Continue;
    alen := SizeOf(peer);
    cfd := fpAccept(lfd, @peer, @alen);
    if cfd < 0 then Continue;
    if children >= Cfg.MaxConnections then
    begin
      // too busy: say so politely instead of queueing without bound
      conn := TConn.Create(cfd, NetAddrToStr(peer.sin_addr), ntohs(peer.sin_port));
      if Cfg.TlsCert <> '' then begin conn.Free; Continue; end;                 // no time for a handshake here: refuse
      req0 := TRequest.Create; req0.Version := 'HTTP/1.1'; req0.Method := 'GET';
      r := TResponse.Create(conn, req0, 2000);
      try
        r.KeepAlive := False;
        SimpleResponse(r, 503, 'text/plain; charset=utf-8', 'server busy: too many connections'#10, nil);
      finally
        r.Free; req0.Free; conn.Free;
      end;
      Continue;
    end;
    pid := fpFork;
    if pid = 0 then
    begin
      // ---- child: this connection only ----
      fpClose(lfd);
      fpSignal(SIGTERM, SignalHandler(SIG_DFL));
      fpSignal(SIGINT, SignalHandler(SIG_DFL));
      fpFcntl(cfd, F_SETFD, 1);
      one := 1;
      fpSetSockOpt(cfd, IPPROTO_TCP, TCP_NODELAY, @one, SizeOf(one));      // small writes (headers, TLS records) must not wait for an ACK
      conn := TConn.Create(cfd, NetAddrToStr(peer.sin_addr), ntohs(peer.sin_port));
      GConn := conn;
      try
        if (Cfg.TlsCert <> '') and not conn.StartTls(Cfg.Lim.HeaderTimeoutMs) then begin conn.Close; FpExit(0); end;
        ServeConnection(conn, Cfg);
      except
        on E: Exception do begin WriteLn(StdErr, 'connection error: ', E.Message); Flush(StdErr); end;
      end;
      conn.Close;
      FpExit(0);
    end
    else if pid > 0 then
    begin
      Inc(children);
      kids.Add(Pointer(PtrInt(pid)));
      fpClose(cfd);
    end
    else fpClose(cfd);
  end;

  // ---- shutdown: no new connections; give running ones a few seconds, then end them ----
  WriteLn(StdErr, 'aicserver: shutting down (', children, ' connections open)');
  fpClose(lfd);
  t0 := GetTickCount64;
  while (children > 0) and (GetTickCount64 - t0 < 5000) do
  begin
    pid := fpWaitPid(-1, st, WNOHANG);
    if pid > 0 then begin Dec(children); k := kids.IndexOf(Pointer(PtrInt(pid))); if k >= 0 then kids.Delete(k); end else Sleep(50);
  end;
  for i := 0 to kids.Count - 1 do fpKill(PtrInt(kids[i]), SIGTERM);      // the stragglers, by pid (never the whole process group)
  for i := 1 to 40 do
  begin
    pid := fpWaitPid(-1, st, WNOHANG);
    if pid > 0 then Dec(children);
    if children <= 0 then Break;
    Sleep(50);
  end;
  kids.Free;
end;

end.
