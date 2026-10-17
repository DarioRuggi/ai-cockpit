(* =============================================================================
  srv_tls — server-side TLS through the system's libssl.so.3 (OpenSSL 3), bound at run time.

  Why our own binding: Free Pascal 3.2.2's `openssl` unit only knows OpenSSL 1.x and cannot load libssl 3 (the reason
  cockpit_auth needed a shim).  Nothing is linked: if the library is missing the server says so and refuses to start
  with a certificate configured; without TLS configured the library is never touched.

    TlsInit(cert, key)     once, in the parent, before forking: loads the library, the certificate chain and the key
    TlsAccept(fd, ms)      in the child: the handshake, with a deadline; nil on failure
    TlsRead / TlsWrite     non-blocking style: >0 bytes, 0 = closed, -1 = would block (wait on `WantWrite`), -2 = error
    TlsClose
  TLS 1.2 minimum, no compression, no renegotiation.  The socket must be non-blocking.
  ============================================================================= *)
unit srv_tls;

{$mode objfpc}{$H+}

interface

function TlsInit(const CertFile, KeyFile: string; out Err: string): Boolean;
function TlsReady: Boolean;
function TlsAccept(Fd: Integer; TimeoutMs: Integer): Pointer;
function TlsRead(S: Pointer; var Buf; Len: Integer; out WantWrite: Boolean): Integer;
function TlsWrite(S: Pointer; const Buf; Len: Integer; out WantRead: Boolean): Integer;
function TlsPending(S: Pointer): Integer;
procedure TlsClose(S: Pointer);

implementation

uses
  SysUtils, dynlibs, BaseUnix, Unix;

const
  SSL_ERROR_NONE = 0;
  SSL_ERROR_SSL = 1;
  SSL_ERROR_WANT_READ = 2;
  SSL_ERROR_WANT_WRITE = 3;
  SSL_ERROR_SYSCALL = 5;
  SSL_ERROR_ZERO_RETURN = 6;
  SSL_FILETYPE_PEM = 1;
  SSL_CTRL_MODE = 33;
  SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
  TLS1_2_VERSION = $0303;
  SSL_MODE_ENABLE_PARTIAL_WRITE = 1;
  SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER = 2;
  SSL_OP_NO_COMPRESSION = QWord(1) shl 17;
  SSL_OP_NO_RENEGOTIATION = QWord(1) shl 30;

var
  hSsl, hCrypto: TLibHandle;
  Ctx: Pointer = nil;

  TLS_server_method: function: Pointer; cdecl;
  SSL_CTX_new: function(Method: Pointer): Pointer; cdecl;
  SSL_CTX_free: procedure(C: Pointer); cdecl;
  SSL_CTX_ctrl: function(C: Pointer; Cmd: LongInt; Larg: LongInt; Parg: Pointer): LongInt; cdecl;
  SSL_CTX_set_options: function(C: Pointer; Op: QWord): QWord; cdecl;
  SSL_CTX_use_certificate_chain_file: function(C: Pointer; F: PChar): LongInt; cdecl;
  SSL_CTX_use_PrivateKey_file: function(C: Pointer; F: PChar; T: LongInt): LongInt; cdecl;
  SSL_CTX_check_private_key: function(C: Pointer): LongInt; cdecl;
  SSL_new: function(C: Pointer): Pointer; cdecl;
  SSL_free: procedure(S: Pointer); cdecl;
  SSL_set_fd: function(S: Pointer; Fd: LongInt): LongInt; cdecl;
  SSL_accept: function(S: Pointer): LongInt; cdecl;
  SSL_read: function(S: Pointer; Buf: Pointer; Num: LongInt): LongInt; cdecl;
  SSL_write: function(S: Pointer; Buf: Pointer; Num: LongInt): LongInt; cdecl;
  SSL_get_error: function(S: Pointer; Ret: LongInt): LongInt; cdecl;
  SSL_shutdown: function(S: Pointer): LongInt; cdecl;
  SSL_pending: function(S: Pointer): LongInt; cdecl;
  ERR_get_error: function: QWord; cdecl;
  ERR_error_string_n: procedure(E: QWord; Buf: PChar; Len: PtrUInt); cdecl;
  ERR_clear_error: procedure; cdecl;

function Sym(H: TLibHandle; const Name: string; out P: Pointer): Boolean;
begin
  P := GetProcedureAddress(H, Name);
  Result := P <> nil;
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

function Load(out Err: string): Boolean;
var
  ok: Boolean;
  p: Pointer;
  function G(const N: string; H: TLibHandle; var F): Boolean;
  begin
    Result := Sym(H, N, p);
    Pointer(F) := p;
    if not Result then Err := Err + 'missing symbol ' + N + #10;
  end;
begin
  Err := '';
  hSsl := LoadLibrary('libssl.so.3');
  hCrypto := LoadLibrary('libcrypto.so.3');
  if (hSsl = NilHandle) or (hCrypto = NilHandle) then
  begin
    Err := 'cannot load libssl.so.3 / libcrypto.so.3 (install OpenSSL 3: libssl3)';
    Exit(False);
  end;
  ok := True;
  ok := G('TLS_server_method', hSsl, TLS_server_method) and ok;
  ok := G('SSL_CTX_new', hSsl, SSL_CTX_new) and ok;
  ok := G('SSL_CTX_free', hSsl, SSL_CTX_free) and ok;
  ok := G('SSL_CTX_ctrl', hSsl, SSL_CTX_ctrl) and ok;
  ok := G('SSL_CTX_set_options', hSsl, SSL_CTX_set_options) and ok;
  ok := G('SSL_CTX_use_certificate_chain_file', hSsl, SSL_CTX_use_certificate_chain_file) and ok;
  ok := G('SSL_CTX_use_PrivateKey_file', hSsl, SSL_CTX_use_PrivateKey_file) and ok;
  ok := G('SSL_CTX_check_private_key', hSsl, SSL_CTX_check_private_key) and ok;
  ok := G('SSL_new', hSsl, SSL_new) and ok;
  ok := G('SSL_free', hSsl, SSL_free) and ok;
  ok := G('SSL_set_fd', hSsl, SSL_set_fd) and ok;
  ok := G('SSL_accept', hSsl, SSL_accept) and ok;
  ok := G('SSL_read', hSsl, SSL_read) and ok;
  ok := G('SSL_write', hSsl, SSL_write) and ok;
  ok := G('SSL_get_error', hSsl, SSL_get_error) and ok;
  ok := G('SSL_shutdown', hSsl, SSL_shutdown) and ok;
  ok := G('SSL_pending', hSsl, SSL_pending) and ok;
  ok := G('ERR_get_error', hCrypto, ERR_get_error) and ok;
  ok := G('ERR_error_string_n', hCrypto, ERR_error_string_n) and ok;
  ok := G('ERR_clear_error', hCrypto, ERR_clear_error) and ok;
  Result := ok;
end;

function TlsInit(const CertFile, KeyFile: string; out Err: string): Boolean;
begin
  Result := False;
  if not Load(Err) then Exit;
  if not FileExists(CertFile) then begin Err := 'certificate file not found: ' + CertFile; Exit; end;
  if not FileExists(KeyFile) then begin Err := 'private key file not found: ' + KeyFile; Exit; end;
  Ctx := SSL_CTX_new(TLS_server_method());
  if Ctx = nil then begin Err := 'SSL_CTX_new failed: ' + LastError; Exit; end;
  SSL_CTX_ctrl(Ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil);
  SSL_CTX_ctrl(Ctx, SSL_CTRL_MODE, SSL_MODE_ENABLE_PARTIAL_WRITE or SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER, nil);
  SSL_CTX_set_options(Ctx, SSL_OP_NO_COMPRESSION or SSL_OP_NO_RENEGOTIATION);
  if SSL_CTX_use_certificate_chain_file(Ctx, PChar(CertFile)) <> 1 then begin Err := 'certificate: ' + LastError; Exit; end;
  if SSL_CTX_use_PrivateKey_file(Ctx, PChar(KeyFile), SSL_FILETYPE_PEM) <> 1 then begin Err := 'private key: ' + LastError; Exit; end;
  if SSL_CTX_check_private_key(Ctx) <> 1 then begin Err := 'the private key does not match the certificate'; Exit; end;
  Result := True;
end;

function TlsReady: Boolean;
begin
  Result := Ctx <> nil;
end;

function WaitFd(Fd: Integer; Events: SmallInt; Ms: Integer): Boolean;
var
  pfd: TPollFd;
  rc: Integer;
begin
  pfd.fd := Fd; pfd.events := Events; pfd.revents := 0;
  repeat
    rc := fpPoll(@pfd, 1, Ms);
  until (rc >= 0) or (fpGetErrno <> ESysEINTR);
  Result := rc > 0;
end;

function TlsAccept(Fd: Integer; TimeoutMs: Integer): Pointer;
var
  s: Pointer;
  rc, e: Integer;
  deadline: QWord;
  left: Int64;
begin
  Result := nil;
  if Ctx = nil then Exit;
  s := SSL_new(Ctx);
  if s = nil then Exit;
  SSL_set_fd(s, Fd);
  deadline := GetTickCount64 + QWord(TimeoutMs);
  while True do
  begin
    ERR_clear_error;
    rc := SSL_accept(s);
    if rc = 1 then Exit(s);
    e := SSL_get_error(s, rc);
    left := Int64(deadline) - Int64(GetTickCount64);
    if left <= 0 then Break;
    if e = SSL_ERROR_WANT_READ then begin if not WaitFd(Fd, POLLIN, Integer(left)) then Break; end
    else if e = SSL_ERROR_WANT_WRITE then begin if not WaitFd(Fd, POLLOUT, Integer(left)) then Break; end
    else Break;                                                   // a failed handshake: wrong protocol, bad client, no shared cipher
  end;
  SSL_free(s);
end;

function TlsRead(S: Pointer; var Buf; Len: Integer; out WantWrite: Boolean): Integer;
var
  rc, e: Integer;
begin
  WantWrite := False;
  ERR_clear_error;
  rc := SSL_read(S, @Buf, Len);
  if rc > 0 then Exit(rc);
  e := SSL_get_error(S, rc);
  case e of
    SSL_ERROR_WANT_READ: Result := -1;
    SSL_ERROR_WANT_WRITE: begin WantWrite := True; Result := -1; end;
    SSL_ERROR_ZERO_RETURN: Result := 0;
    SSL_ERROR_SYSCALL: if rc = 0 then Result := 0 else Result := -2;      // a peer that closes without close_notify
  else
    Result := -2;
  end;
end;

function TlsWrite(S: Pointer; const Buf; Len: Integer; out WantRead: Boolean): Integer;
var
  rc, e: Integer;
begin
  WantRead := False;
  ERR_clear_error;
  rc := SSL_write(S, @Buf, Len);
  if rc > 0 then Exit(rc);
  e := SSL_get_error(S, rc);
  case e of
    SSL_ERROR_WANT_WRITE: Result := -1;
    SSL_ERROR_WANT_READ: begin WantRead := True; Result := -1; end;
  else
    Result := -2;
  end;
end;

function TlsPending(S: Pointer): Integer;
begin
  if S = nil then Exit(0);
  Result := SSL_pending(S);
end;

procedure TlsClose(S: Pointer);
begin
  if S = nil then Exit;
  ERR_clear_error;
  SSL_shutdown(S);                                              // best effort: close_notify, no waiting for the answer
  SSL_free(S);
end;

end.
