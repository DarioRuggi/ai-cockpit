(* =============================================================================
  aic_tls — a TLS CLIENT through the system's libssl.so.3 (OpenSSL 3), bound at run time.

  Free Pascal 3.2.2's own `openssl` unit knows only OpenSSL 1.x and cannot load libssl 3, so (like the server side in aicserver's
  srv_tls) this binds the handful of functions it needs by name. Nothing is linked: where the library is missing the engine
  simply cannot speak HTTPS and says so; plain HTTP and every other command are unaffected.

    TlsClientOpen(fd, host, cafile, ms, err)   handshake over a connected TCP socket, with a deadline. NEVER succeeds without
                                               verifying the server certificate: chain against the system trust store (or the
                                               given PEM bundle) AND the host name against the certificate.
    TlsClientRead / TlsClientWrite             blocking style with a deadline: >0 bytes, 0 = closed by the peer, -1 = timed out, -2 = error
    TlsClientClose

  TLS 1.2 minimum, no compression. Verification failures come back as text ("certificate verify failed: Hostname mismatch").
  A host given as an IP address is refused: certificates for them are rare and checking them is a different path.
  ============================================================================= *)
unit aic_tls;

{$mode objfpc}{$H+}

interface

function TlsClientOpen(Fd: Integer; const Host, CaFile: string; TimeoutMs: Integer; out Err: string): Pointer;
function TlsClientRead(S: Pointer; var Buf; Len: Integer; TimeoutMs: Integer): Integer;
function TlsClientWrite(S: Pointer; const Buf; Len: Integer; TimeoutMs: Integer): Integer;
procedure TlsClientClose(S: Pointer);
{ true when libssl 3 can be loaded here (the engine uses this to refuse an https:// URL early) }
function TlsAvailable(out Why: string): Boolean;

implementation

uses
  SysUtils, dynlibs, BaseUnix, Unix;

const
  SSL_ERROR_SSL = 1;
  SSL_ERROR_WANT_READ = 2;
  SSL_ERROR_WANT_WRITE = 3;
  SSL_ERROR_SYSCALL = 5;
  SSL_ERROR_ZERO_RETURN = 6;
  SSL_VERIFY_PEER = 1;
  SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
  TLSEXT_NAMETYPE_host_name = 0;
  SSL_CTRL_MODE = 33;
  SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
  TLS1_2_VERSION = $0303;
  SSL_MODE_ENABLE_PARTIAL_WRITE = 1;
  SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER = 2;
  SSL_OP_NO_COMPRESSION = QWord(1) shl 17;

type
  TTlsConn = record
    Ctx: Pointer;
    Ssl: Pointer;
    Fd: Integer;
  end;
  PTlsConn = ^TTlsConn;

var
  hSsl, hCrypto: TLibHandle;
  Loaded: Boolean = False;
  LoadErr: string = '';

  TLS_client_method: function: Pointer; cdecl;
  SSL_CTX_new: function(Method: Pointer): Pointer; cdecl;
  SSL_CTX_free: procedure(C: Pointer); cdecl;
  SSL_CTX_ctrl: function(C: Pointer; Cmd: LongInt; Larg: LongInt; Parg: Pointer): LongInt; cdecl;
  SSL_CTX_set_options: function(C: Pointer; Op: QWord): QWord; cdecl;
  SSL_CTX_set_verify: procedure(C: Pointer; Mode: LongInt; Cb: Pointer); cdecl;
  SSL_CTX_set_default_verify_paths: function(C: Pointer): LongInt; cdecl;
  SSL_CTX_load_verify_locations: function(C: Pointer; CaFile, CaPath: PChar): LongInt; cdecl;
  SSL_new: function(C: Pointer): Pointer; cdecl;
  SSL_free: procedure(S: Pointer); cdecl;
  SSL_set_fd: function(S: Pointer; Fd: LongInt): LongInt; cdecl;
  SSL_ctrl: function(S: Pointer; Cmd: LongInt; Larg: LongInt; Parg: Pointer): LongInt; cdecl;
  SSL_set1_host: function(S: Pointer; Name: PChar): LongInt; cdecl;
  SSL_connect: function(S: Pointer): LongInt; cdecl;
  SSL_read: function(S: Pointer; Buf: Pointer; Num: LongInt): LongInt; cdecl;
  SSL_write: function(S: Pointer; Buf: Pointer; Num: LongInt): LongInt; cdecl;
  SSL_get_error: function(S: Pointer; Ret: LongInt): LongInt; cdecl;
  SSL_shutdown: function(S: Pointer): LongInt; cdecl;
  SSL_get_verify_result: function(S: Pointer): LongInt; cdecl;
  X509_verify_cert_error_string: function(N: LongInt): PChar; cdecl;
  ERR_get_error: function: QWord; cdecl;
  ERR_error_string_n: procedure(E: QWord; Buf: PChar; Len: PtrUInt); cdecl;
  ERR_clear_error: procedure; cdecl;

function Load(out Err: string): Boolean;
var
  ok: Boolean;
  function G(const N: string; H: TLibHandle; var F): Boolean;
  var p: Pointer;
  begin
    p := GetProcedureAddress(H, N);
    Pointer(F) := p;
    Result := p <> nil;
    if not Result then Err := Err + 'missing symbol ' + N + #10;
  end;
begin
  if Loaded then begin Err := LoadErr; Exit(LoadErr = ''); end;
  Err := '';
  hSsl := LoadLibrary('libssl.so.3');
  hCrypto := LoadLibrary('libcrypto.so.3');
  if (hSsl = NilHandle) or (hCrypto = NilHandle) then
  begin
    Err := 'cannot load libssl.so.3 / libcrypto.so.3 (install OpenSSL 3: libssl3)';
    Loaded := True; LoadErr := Err;
    Exit(False);
  end;
  ok := True;
  ok := G('TLS_client_method', hSsl, TLS_client_method) and ok;
  ok := G('SSL_CTX_new', hSsl, SSL_CTX_new) and ok;
  ok := G('SSL_CTX_free', hSsl, SSL_CTX_free) and ok;
  ok := G('SSL_CTX_ctrl', hSsl, SSL_CTX_ctrl) and ok;
  ok := G('SSL_CTX_set_options', hSsl, SSL_CTX_set_options) and ok;
  ok := G('SSL_CTX_set_verify', hSsl, SSL_CTX_set_verify) and ok;
  ok := G('SSL_CTX_set_default_verify_paths', hSsl, SSL_CTX_set_default_verify_paths) and ok;
  ok := G('SSL_CTX_load_verify_locations', hSsl, SSL_CTX_load_verify_locations) and ok;
  ok := G('SSL_new', hSsl, SSL_new) and ok;
  ok := G('SSL_free', hSsl, SSL_free) and ok;
  ok := G('SSL_set_fd', hSsl, SSL_set_fd) and ok;
  ok := G('SSL_ctrl', hSsl, SSL_ctrl) and ok;
  ok := G('SSL_set1_host', hSsl, SSL_set1_host) and ok;
  ok := G('SSL_connect', hSsl, SSL_connect) and ok;
  ok := G('SSL_read', hSsl, SSL_read) and ok;
  ok := G('SSL_write', hSsl, SSL_write) and ok;
  ok := G('SSL_get_error', hSsl, SSL_get_error) and ok;
  ok := G('SSL_shutdown', hSsl, SSL_shutdown) and ok;
  ok := G('SSL_get_verify_result', hSsl, SSL_get_verify_result) and ok;
  ok := G('X509_verify_cert_error_string', hCrypto, X509_verify_cert_error_string) and ok;
  ok := G('ERR_get_error', hCrypto, ERR_get_error) and ok;
  ok := G('ERR_error_string_n', hCrypto, ERR_error_string_n) and ok;
  ok := G('ERR_clear_error', hCrypto, ERR_clear_error) and ok;
  Loaded := True;
  if not ok then LoadErr := Err;
  Result := ok;
end;

function TlsAvailable(out Why: string): Boolean;
begin
  Result := Load(Why);
end;

function LastError: string;
var
  e: QWord;
  b: array[0..255] of Char;
begin
  Result := '';
  if not Assigned(ERR_get_error) then Exit;
  e := ERR_get_error();
  if e = 0 then Exit;
  FillChar(b, SizeOf(b), 0);
  ERR_error_string_n(e, @b[0], SizeOf(b) - 1);
  Result := StrPas(@b[0]);
end;

function WaitFd(Fd: Integer; Events: SmallInt; Ms: Integer): Boolean;
var
  pfd: TPollFd;
  rc: Integer;
begin
  if Ms < 0 then Ms := 0;
  pfd.fd := Fd; pfd.events := Events; pfd.revents := 0;
  repeat
    rc := fpPoll(@pfd, 1, Ms);
  until (rc >= 0) or (fpGetErrno <> ESysEINTR);
  Result := rc > 0;
end;

function IsIpLiteral(const H: string): Boolean;
var
  i: Integer;
begin
  Result := (H <> '') and (Pos(':', H) > 0);               // IPv6
  if Result then Exit;
  Result := H <> '';
  for i := 1 to Length(H) do if not (H[i] in ['0'..'9', '.']) then Exit(False);
end;

function TlsClientOpen(Fd: Integer; const Host, CaFile: string; TimeoutMs: Integer; out Err: string): Pointer;
var
  c: PTlsConn;
  rc, e: Integer;
  deadline: QWord;
  left: Int64;
  vr: LongInt;
  why: string;
begin
  Result := nil; Err := '';
  if not Load(Err) then Exit;
  if Host = '' then begin Err := 'no host name'; Exit; end;
  if IsIpLiteral(Host) then begin Err := 'TLS to an IP address is not supported (' + Host + '): use the host name'; Exit; end;
  New(c);
  FillChar(c^, SizeOf(c^), 0);
  c^.Fd := Fd;
  c^.Ctx := SSL_CTX_new(TLS_client_method());
  if c^.Ctx = nil then begin Err := 'SSL_CTX_new failed: ' + LastError; Dispose(c); Exit; end;
  SSL_CTX_ctrl(c^.Ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil);
  SSL_CTX_ctrl(c^.Ctx, SSL_CTRL_MODE, SSL_MODE_ENABLE_PARTIAL_WRITE or SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER, nil);
  SSL_CTX_set_options(c^.Ctx, SSL_OP_NO_COMPRESSION);
  SSL_CTX_set_verify(c^.Ctx, SSL_VERIFY_PEER, nil);                 { the handshake FAILS if the certificate does not verify }
  if CaFile <> '' then
  begin
    if SSL_CTX_load_verify_locations(c^.Ctx, PChar(CaFile), nil) <> 1 then
    begin Err := 'cannot read the CA file ' + CaFile + ': ' + LastError; SSL_CTX_free(c^.Ctx); Dispose(c); Exit; end;
  end
  else if SSL_CTX_set_default_verify_paths(c^.Ctx) <> 1 then
  begin Err := 'no system certificate store found: ' + LastError; SSL_CTX_free(c^.Ctx); Dispose(c); Exit; end;
  c^.Ssl := SSL_new(c^.Ctx);
  if c^.Ssl = nil then begin Err := 'SSL_new failed: ' + LastError; SSL_CTX_free(c^.Ctx); Dispose(c); Exit; end;
  SSL_set_fd(c^.Ssl, Fd);
  SSL_ctrl(c^.Ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, PChar(Host));   { SNI }
  if SSL_set1_host(c^.Ssl, PChar(Host)) <> 1 then                   { the certificate must be FOR this host name }
  begin Err := 'cannot set the host name to verify: ' + LastError; TlsClientClose(c); Exit; end;
  deadline := GetTickCount64 + QWord(TimeoutMs);
  while True do
  begin
    ERR_clear_error;
    rc := SSL_connect(c^.Ssl);
    if rc = 1 then Break;
    e := SSL_get_error(c^.Ssl, rc);
    left := Int64(deadline) - Int64(GetTickCount64);
    if left <= 0 then begin Err := 'TLS handshake timed out'; TlsClientClose(c); Exit; end;
    if e = SSL_ERROR_WANT_READ then begin if not WaitFd(Fd, POLLIN, Integer(left)) then begin Err := 'TLS handshake timed out'; TlsClientClose(c); Exit; end; end
    else if e = SSL_ERROR_WANT_WRITE then begin if not WaitFd(Fd, POLLOUT, Integer(left)) then begin Err := 'TLS handshake timed out'; TlsClientClose(c); Exit; end; end
    else
    begin
      why := LastError;
      vr := SSL_get_verify_result(c^.Ssl);
      if vr <> 0 then Err := 'certificate verify failed: ' + StrPas(X509_verify_cert_error_string(vr))
      else if why <> '' then Err := 'TLS handshake failed: ' + why
      else Err := 'TLS handshake failed';
      TlsClientClose(c);
      Exit;
    end;
  end;
  vr := SSL_get_verify_result(c^.Ssl);                              { belt and braces: the handshake only returns 1 when this is 0 }
  if vr <> 0 then begin Err := 'certificate verify failed: ' + StrPas(X509_verify_cert_error_string(vr)); TlsClientClose(c); Exit; end;
  Result := c;
end;

function TlsClientRead(S: Pointer; var Buf; Len: Integer; TimeoutMs: Integer): Integer;
var
  c: PTlsConn;
  rc, e: Integer;
  deadline: QWord;
  left: Int64;
begin
  c := PTlsConn(S);
  deadline := GetTickCount64 + QWord(TimeoutMs);
  while True do
  begin
    ERR_clear_error;
    rc := SSL_read(c^.Ssl, @Buf, Len);
    if rc > 0 then Exit(rc);
    e := SSL_get_error(c^.Ssl, rc);
    left := Int64(deadline) - Int64(GetTickCount64);
    case e of
      SSL_ERROR_ZERO_RETURN: Exit(0);
      SSL_ERROR_SYSCALL: if rc = 0 then Exit(0) else Exit(-2);       { a peer that closes without close_notify }
      SSL_ERROR_WANT_READ: if (left <= 0) or not WaitFd(c^.Fd, POLLIN, Integer(left)) then Exit(-1);
      SSL_ERROR_WANT_WRITE: if (left <= 0) or not WaitFd(c^.Fd, POLLOUT, Integer(left)) then Exit(-1);
    else
      Exit(-2);
    end;
  end;
end;

function TlsClientWrite(S: Pointer; const Buf; Len: Integer; TimeoutMs: Integer): Integer;
var
  c: PTlsConn;
  rc, e: Integer;
  deadline: QWord;
  left: Int64;
begin
  c := PTlsConn(S);
  deadline := GetTickCount64 + QWord(TimeoutMs);
  while True do
  begin
    ERR_clear_error;
    rc := SSL_write(c^.Ssl, @Buf, Len);
    if rc > 0 then Exit(rc);
    e := SSL_get_error(c^.Ssl, rc);
    left := Int64(deadline) - Int64(GetTickCount64);
    case e of
      SSL_ERROR_WANT_WRITE: if (left <= 0) or not WaitFd(c^.Fd, POLLOUT, Integer(left)) then Exit(-1);
      SSL_ERROR_WANT_READ: if (left <= 0) or not WaitFd(c^.Fd, POLLIN, Integer(left)) then Exit(-1);
    else
      Exit(-2);
    end;
  end;
end;

procedure TlsClientClose(S: Pointer);
var
  c: PTlsConn;
begin
  if S = nil then Exit;
  c := PTlsConn(S);
  if c^.Ssl <> nil then
  begin
    ERR_clear_error;
    SSL_shutdown(c^.Ssl);                                           { best effort: close_notify, no waiting for the answer }
    SSL_free(c^.Ssl);
  end;
  if c^.Ctx <> nil then SSL_CTX_free(c^.Ctx);
  Dispose(c);
end;

end.
