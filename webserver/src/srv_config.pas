(* =============================================================================
  srv_config — aicserver.json

  {
    "listen": {"host": "127.0.0.1", "port": 8081},        127.0.0.1 unless the person opts in to the LAN
    "server_name": "aicserver",                             "" = send no Server header
    "allowed_hosts": ["localhost", "127.0.0.1", "[::1]"],   Host must match (DNS-rebinding guard); [] = any
    "mounts": [
      {"prefix": "/cockpit", "root": "/var/www/html/cockpit", "index": ["index.php", "index.html"],
       "static_only_dirs": ["attachments", "generated"],     .php files below these folders are never executed
       "deny": ["config/*"]}                                 extra globs for this mount (relative path)
    ],
    "root_redirect": "/cockpit/",                           where "/" goes ("" = 404)
    "php": {"extensions": [".php"], "fastcgi": "127.0.0.1:9000" | "unix:/run/php.sock",
            "connect_timeout_s": 3, "idle_timeout_s": 300},
    "deny": [".*", "*~", "*.bak", "*.orig", "*.swp", "*.pas", "*.lpr", "*.sh"],     globs per path SEGMENT
    "allow": [".well-known"],                                                       segments exempt from "deny"
    "cache_rules": [{"match": "*.html", "value": "no-cache, must-revalidate"}],
    "headers": {"X-Content-Type-Options": "nosniff", "X-Frame-Options": "SAMEORIGIN", "Referrer-Policy": "same-origin"},
    "limits": {"max_line": 8192, "max_header_kb": 32, "max_headers": 100, "max_body_mb": 64,
               "header_timeout_s": 10, "body_idle_s": 30, "keepalive_s": 5, "write_timeout_s": 30,
               "max_connections": 64, "max_requests_per_connection": 1000},
    "access_log": "/path/access.log"                         "" = none
  }
  ============================================================================= *)
unit srv_config;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, srv_util, srv_http;

type
  TMount = class
    Prefix, Root, RootReal: string;
    Index, StaticOnly, Deny: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  TCacheRule = record
    Match, Value: string;
  end;

  TServerConfig = class
  public
    Host: string;
    Port: Integer;
    ServerName: string;
    AllowedHosts: TStringList;
    Mounts: TList;
    RootRedirect: string;
    PhpExt: TStringList;
    FcgiAddr: string;
    FcgiConnectS, FcgiIdleS: Integer;
    Deny, Allow: TStringList;
    Cache: array of TCacheRule;
    Headers: TStringList;                 // Name: value
    Lim: TLimits;
    MaxConnections, MaxRequestsPerConn: Integer;
    TlsCert, TlsKey: string;              // both set = HTTPS on the listener
    GzipOn: Boolean;                      // compress text responses for clients that accept gzip
    GzipMin, GzipLevel: Integer;
    AccessLog: string;
    ConfigDir: string;
    NativePoll: Boolean;                  { answer bridge.php mode=poll itself (srv_native); everything it is unsure about goes to PHP }
    NativeSessionDir, NativeSupDir: string;
    NativeSessionDays: Integer;
    constructor Create;
    destructor Destroy; override;
    function MountFor(const Path: string; out Rest: string): TMount;
  end;

function LoadServerConfig(const FileName: string; out Errors: string): TServerConfig;

implementation

constructor TMount.Create;
begin
  Index := TStringList.Create; StaticOnly := TStringList.Create; Deny := TStringList.Create;
end;

destructor TMount.Destroy;
begin
  Index.Free; StaticOnly.Free; Deny.Free;
  inherited Destroy;
end;

constructor TServerConfig.Create;
begin
  Host := '127.0.0.1'; Port := 8081; ServerName := 'aicserver';
  AllowedHosts := TStringList.Create; Mounts := TList.Create; PhpExt := TStringList.Create;
  Deny := TStringList.Create; Allow := TStringList.Create; Headers := TStringList.Create;
  FcgiConnectS := 3; FcgiIdleS := 300;
  with Lim do
  begin
    MaxLineBytes := 8192; MaxHeaderBytes := 32768; MaxHeaders := 100; MaxBodyBytes := 64 * 1048576;
    HeaderTimeoutMs := 10000; BodyIdleMs := 30000; KeepAliveMs := 5000; WriteTimeoutMs := 30000;
  end;
  MaxConnections := 64; MaxRequestsPerConn := 1000;
  GzipOn := False; GzipMin := 1024; GzipLevel := 6;
end;

destructor TServerConfig.Destroy;
var
  i: Integer;
begin
  for i := 0 to Mounts.Count - 1 do TMount(Mounts[i]).Free;
  Mounts.Free; AllowedHosts.Free; PhpExt.Free; Deny.Free; Allow.Free; Headers.Free;
  inherited Destroy;
end;

{ The mount whose prefix matches on a path-segment boundary, longest first.  Rest is the path below it. }
function TServerConfig.MountFor(const Path: string; out Rest: string): TMount;
var
  i, bestLen: Integer;
  m: TMount;
  pre: string;
begin
  Result := nil; Rest := '';
  bestLen := -1;
  for i := 0 to Mounts.Count - 1 do
  begin
    m := TMount(Mounts[i]);
    pre := m.Prefix;
    if pre = '/' then
    begin
      if Length(pre) > bestLen then begin Result := m; bestLen := Length(pre); Rest := Path; end;
    end
    else if (Path = pre) or (Copy(Path, 1, Length(pre) + 1) = pre + '/') then
      if Length(pre) > bestLen then begin Result := m; bestLen := Length(pre); Rest := Copy(Path, Length(pre) + 1, MaxInt); if Rest = '' then Rest := '/'; end;
  end;
end;

procedure ReadList(O: TJSONObject; const Key: string; Dest: TStrings);
var
  a: TJSONData;
  i: Integer;
begin
  a := O.Find(Key);
  if (a <> nil) and (a.JSONType = jtArray) then
    for i := 0 to TJSONArray(a).Count - 1 do Dest.Add(TJSONArray(a)[i].AsString);
end;

function ReadFile(const F: string): string;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.LoadFromFile(F);
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

function Expand(const S, Dir: string): string;
begin
  Result := StringReplace(S, '${CONFIG_DIR}', Dir, [rfReplaceAll]);
  Result := StringReplace(Result, '${HOME}', GetEnvironmentVariable('HOME'), [rfReplaceAll]);
end;

function LoadServerConfig(const FileName: string; out Errors: string): TServerConfig;
var
  doc: TJSONData;
  root, o, lim, gz, php, hd, ls, tl, nat: TJSONObject;
  a: TJSONData;
  i: Integer;
  c: TServerConfig;
  m: TMount;
  s: string;
begin
  Result := nil; Errors := '';
  if not FileExists(FileName) then begin Errors := 'config file not found: ' + FileName; Exit; end;
  try doc := GetJSON(ReadFile(FileName)); except on E: Exception do begin Errors := 'config is not valid JSON: ' + E.Message; Exit; end; end;
  if doc.JSONType <> jtObject then begin doc.Free; Errors := 'config must be a JSON object'; Exit; end;
  root := TJSONObject(doc);
  c := TServerConfig.Create;
  try
    c.ConfigDir := ExtractFileDir(ExpandFileName(FileName));
    ls := root.Get('listen', TJSONObject(nil));
    if ls <> nil then
    begin
      c.Host := ls.Get('host', c.Host); c.Port := ls.Get('port', c.Port);
      tl := ls.Get('tls', TJSONObject(nil));
      if tl <> nil then
      begin
        c.TlsCert := Expand(tl.Get('cert', ''), c.ConfigDir); c.TlsKey := Expand(tl.Get('key', ''), c.ConfigDir);
        if (c.TlsCert = '') or (c.TlsKey = '') then Errors := Errors + 'listen.tls needs both cert and key' + #10;
      end;
    end;
    c.ServerName := root.Get('server_name', c.ServerName);
    ReadList(root, 'allowed_hosts', c.AllowedHosts);
    c.RootRedirect := root.Get('root_redirect', '');
    c.AccessLog := Expand(root.Get('access_log', ''), c.ConfigDir);
    a := root.Find('mounts');
    if (a <> nil) and (a.JSONType = jtArray) then
      for i := 0 to TJSONArray(a).Count - 1 do
      begin
        o := TJSONObject(TJSONArray(a)[i]);
        m := TMount.Create;
        m.Prefix := o.Get('prefix', '');
        m.Root := Expand(o.Get('root', ''), c.ConfigDir);
        ReadList(o, 'index', m.Index); ReadList(o, 'static_only_dirs', m.StaticOnly); ReadList(o, 'deny', m.Deny);
        if (m.Prefix = '') or (m.Prefix[1] <> '/') then Errors := Errors + 'mount #' + IntToStr(i + 1) + ': prefix must start with /' + #10;
        if (Length(m.Prefix) > 1) and (m.Prefix[Length(m.Prefix)] = '/') then Errors := Errors + 'mount "' + m.Prefix + '": prefix must not end with /' + #10;
        m.RootReal := RealPathOf(m.Root);
        if (m.Root = '') or (m.RootReal = '') or not DirectoryExists(m.RootReal) then Errors := Errors + 'mount "' + m.Prefix + '": root does not exist: ' + m.Root + #10;
        c.Mounts.Add(m);
      end;
    if c.Mounts.Count = 0 then Errors := Errors + 'no mounts: nothing to serve' + #10;
    php := root.Get('php', TJSONObject(nil));
    if php <> nil then
    begin
      ReadList(php, 'extensions', c.PhpExt);
      c.FcgiAddr := php.Get('fastcgi', '');
      c.FcgiConnectS := php.Get('connect_timeout_s', c.FcgiConnectS);
      c.FcgiIdleS := php.Get('idle_timeout_s', c.FcgiIdleS);
    end;
    if (c.PhpExt.Count > 0) and (c.FcgiAddr = '') then Errors := Errors + 'php extensions are set but php.fastcgi is empty' + #10;
    for i := 0 to c.PhpExt.Count - 1 do c.PhpExt[i] := LowerCase(c.PhpExt[i]);
    ReadList(root, 'deny', c.Deny); ReadList(root, 'allow', c.Allow);
    a := root.Find('cache_rules');
    if (a <> nil) and (a.JSONType = jtArray) then
    begin
      SetLength(c.Cache, TJSONArray(a).Count);
      for i := 0 to TJSONArray(a).Count - 1 do
      begin
        c.Cache[i].Match := TJSONObject(TJSONArray(a)[i]).Get('match', '');
        c.Cache[i].Value := TJSONObject(TJSONArray(a)[i]).Get('value', '');
      end;
    end;
    hd := root.Get('headers', TJSONObject(nil));
    if hd <> nil then
      for i := 0 to hd.Count - 1 do c.Headers.Add(hd.Names[i] + ': ' + hd.Items[i].AsString);
    nat := root.Get('native', TJSONObject(nil));
    if nat <> nil then
    begin
      c.NativePoll := nat.Get('bridge_poll', False);
      c.NativeSessionDir := nat.Get('session_dir', '');
      c.NativeSupDir := nat.Get('supervisor_dir', '');
      c.NativeSessionDays := nat.Get('session_days', 90);
      if c.NativePoll and ((c.NativeSessionDir = '') or (c.NativeSupDir = '')) then Errors := Errors + 'native.bridge_poll needs native.session_dir and native.supervisor_dir' + #10;
    end;
    gz := root.Get('gzip', TJSONObject(nil));
    if gz <> nil then
    begin
      c.GzipOn := gz.Get('enabled', c.GzipOn);
      c.GzipMin := gz.Get('min_bytes', c.GzipMin);
      c.GzipLevel := gz.Get('level', c.GzipLevel);
      if (c.GzipLevel < 1) or (c.GzipLevel > 9) then Errors := Errors + 'gzip.level must be 1-9' + #10;
    end;
    lim := root.Get('limits', TJSONObject(nil));
    if lim <> nil then
    begin
      c.Lim.MaxLineBytes := lim.Get('max_line', c.Lim.MaxLineBytes);
      c.Lim.MaxHeaderBytes := lim.Get('max_header_kb', c.Lim.MaxHeaderBytes div 1024) * 1024;
      c.Lim.MaxHeaders := lim.Get('max_headers', c.Lim.MaxHeaders);
      c.Lim.MaxBodyBytes := Int64(lim.Get('max_body_mb', Integer(c.Lim.MaxBodyBytes div 1048576))) * 1048576;
      c.Lim.HeaderTimeoutMs := lim.Get('header_timeout_s', c.Lim.HeaderTimeoutMs div 1000) * 1000;
      c.Lim.BodyIdleMs := lim.Get('body_idle_s', c.Lim.BodyIdleMs div 1000) * 1000;
      c.Lim.KeepAliveMs := lim.Get('keepalive_s', c.Lim.KeepAliveMs div 1000) * 1000;
      c.Lim.WriteTimeoutMs := lim.Get('write_timeout_s', c.Lim.WriteTimeoutMs div 1000) * 1000;
      c.MaxConnections := lim.Get('max_connections', c.MaxConnections);
      c.MaxRequestsPerConn := lim.Get('max_requests_per_connection', c.MaxRequestsPerConn);
    end;
    if (c.Port < 1) or (c.Port > 65535) then Errors := Errors + 'listen.port must be 1-65535' + #10;
    if c.Lim.MaxLineBytes < 256 then Errors := Errors + 'limits.max_line is too small' + #10;
    if Errors <> '' then begin FreeAndNil(c); Exit; end;
    Result := c;
    c := nil;
  finally
    c.Free;
    root.Free;
  end;
  s := '';
end;

end.
