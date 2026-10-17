(* =============================================================================
  aic_workers — the Workers relay (the free-REST suppliers of Card 2) with no PHP: what `php worker_relay.php PROVIDER MODEL PROMPT_FILE`
  prints, for groq, huggingface and cloudflare.

    WorkersRelay(Provider, Model, PromptFile, DataDir, Base, Output) -> 0 = Output is what the PHP prints, 9 = refused: use the PHP

  It decrypts <data>/workers_keys.enc exactly as workers.php does (AES-256-GCM through the system's libcrypto 3, key = sha256 of
  /etc/machine-id + the Cockpit salt), then makes the same one POST the invoke_* function makes and shapes the answer the same way.
  Anything it is not sure it reproduces to the byte is refused (exit 9) so the PHP does it: another provider, a key store it cannot read,
  a redirect, a response of an unusual shape (an error that is not text, a number where text is expected, HuggingFace's
  "pretty-printed JSON" fallback), a prompt that is not valid UTF-8. The one known difference: a transport failure reads "curl: <reason>"
  with this engine's reason text instead of libcurl's.
  `Base` (when not empty) replaces the provider's address: for tests.
  ============================================================================= *)
unit aic_workers;

{$mode objfpc}{$H+}

interface

function WorkersRelay(const Provider, Model, PromptFile, DataDir, Base: string; out Output: string): Integer;

implementation

uses
  SysUtils, Classes, dynlibs, fpjson, jsonparser, jsonscanner, aic_https;

const
  MASTER_SALT = 'AICockpit-WorkerKeys-v1-DarioRuggi';

type
  TRefused = class(Exception);

procedure Refuse(const Why: string);
begin
  raise TRefused.Create(Why);
end;

{ ---- libcrypto, bound at run time ---- }
var
  hCrypto: TLibHandle = NilHandle;
  CryptoTried: Boolean = False;
  fSHA256: function(D: PByte; N: PtrUInt; Md: PByte): PByte; cdecl;
  fCtxNew: function: Pointer; cdecl;
  fCtxFree: procedure(C: Pointer); cdecl;
  fAesGcm: function: Pointer; cdecl;
  fDecInit: function(C, Ciph, Eng: Pointer; Key, Iv: PByte): LongInt; cdecl;
  fDecUpdate: function(C: Pointer; Outp: PByte; var OutL: LongInt; Inp: PByte; InL: LongInt): LongInt; cdecl;
  fDecFinal: function(C: Pointer; Outp: PByte; var OutL: LongInt): LongInt; cdecl;
  fCtrl: function(C: Pointer; Typ, Arg: LongInt; Ptr: Pointer): LongInt; cdecl;

function CryptoReady: Boolean;
begin
  if not CryptoTried then
  begin
    CryptoTried := True;
    hCrypto := LoadLibrary('libcrypto.so.3');
    if hCrypto <> NilHandle then
    begin
      Pointer(fSHA256) := GetProcedureAddress(hCrypto, 'SHA256');
      Pointer(fCtxNew) := GetProcedureAddress(hCrypto, 'EVP_CIPHER_CTX_new');
      Pointer(fCtxFree) := GetProcedureAddress(hCrypto, 'EVP_CIPHER_CTX_free');
      Pointer(fAesGcm) := GetProcedureAddress(hCrypto, 'EVP_aes_256_gcm');
      Pointer(fDecInit) := GetProcedureAddress(hCrypto, 'EVP_DecryptInit_ex');
      Pointer(fDecUpdate) := GetProcedureAddress(hCrypto, 'EVP_DecryptUpdate');
      Pointer(fDecFinal) := GetProcedureAddress(hCrypto, 'EVP_DecryptFinal_ex');
      Pointer(fCtrl) := GetProcedureAddress(hCrypto, 'EVP_CIPHER_CTX_ctrl');
    end;
  end;
  Result := (hCrypto <> NilHandle) and Assigned(fSHA256) and Assigned(fCtxNew) and Assigned(fCtxFree) and Assigned(fAesGcm)
    and Assigned(fDecInit) and Assigned(fDecUpdate) and Assigned(fDecFinal) and Assigned(fCtrl);
end;

function ReadWhole(const F: string): string;
var
  fs: TFileStream;
begin
  Result := '';
  fs := TFileStream.Create(F, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[1], fs.Size);
  finally
    fs.Free;
  end;
end;

{ PHP trim() }
function PhpTrim(const S: string): string;
var
  a, b: Integer;
begin
  a := 1; b := Length(S);
  while (a <= b) and (S[a] in [' ', #9, #10, #13, #0, #11]) do Inc(a);
  while (b >= a) and (S[b] in [' ', #9, #10, #13, #0, #11]) do Dec(b);
  Result := Copy(S, a, b - a + 1);
end;

{ strict base64 (the alphabet and trailing '=' only); anything else is refused }
function B64Decode(const S: string; out Valid: Boolean): string;
var
  i, n, bits, acc, pad: Integer;
  v: Integer;
  c: Char;
begin
  Result := ''; acc := 0; bits := 0; pad := 0; n := 0; Valid := False;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if c in [' ', #9, #10, #13] then Continue;     { strict base64_decode skips these }
    Inc(n);
    if c = '=' then begin Inc(pad); Continue; end;
    if pad > 0 then Exit('');               { data after padding: false }
    case c of
      'A'..'Z': v := Ord(c) - 65;
      'a'..'z': v := Ord(c) - 71;
      '0'..'9': v := Ord(c) + 4;
      '+': v := 62;
      '/': v := 63;
    else Exit('');                         { a character outside the alphabet: false }
    end;
    acc := (acc shl 6) or v; bits := bits + 6;
    if bits >= 8 then
    begin
      bits := bits - 8;
      Result := Result + Chr((acc shr bits) and $FF);
      acc := acc and ((1 shl bits) - 1);
    end;
  end;
  if (pad > 2) or ((n mod 4) <> 0) then Refuse('base64 length');
  Valid := True;
end;

function B64Encode(const S: string): string;
const
  T = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  i, n, v: Integer;
begin
  Result := ''; n := Length(S); i := 1;
  while i <= n do
  begin
    v := Ord(S[i]) shl 16;
    if i + 1 <= n then v := v or (Ord(S[i + 1]) shl 8);
    if i + 2 <= n then v := v or Ord(S[i + 2]);
    Result := Result + T[((v shr 18) and 63) + 1] + T[((v shr 12) and 63) + 1];
    if i + 1 <= n then Result := Result + T[((v shr 6) and 63) + 1] else Result := Result + '=';
    if i + 2 <= n then Result := Result + T[(v and 63) + 1] else Result := Result + '=';
    Inc(i, 3);
  end;
end;

{ workers.php decrypt_blob(): '' when it cannot }
function DecryptBlob(const B64: string): string;
var
  raw, iv, tag, ct, mid, outb: string;
  key: array[0..31] of Byte;
  ctx: Pointer;
  ol, tl: LongInt;
  h: PByte;
  valid: Boolean;
begin
  Result := '';
  if B64 = '' then Exit;
  if not CryptoReady then Refuse('libcrypto.so.3 not available');
  raw := B64Decode(B64, valid);
  if not valid then Exit;
  if Length(raw) < 28 then Exit;
  iv := Copy(raw, 1, 12); tag := Copy(raw, 13, 16); ct := Copy(raw, 29, MaxInt);
  if FileExists('/etc/machine-id') then
  try
    mid := PhpTrim(ReadWhole('/etc/machine-id'));
  except
    mid := 'cockpit-default-machine';
  end
  else mid := 'cockpit-default-machine';
  mid := mid + MASTER_SALT;
  h := fSHA256(PByte(PChar(mid)), Length(mid), @key[0]);
  if h = nil then Refuse('sha256 failed');
  if ct = '' then Exit;
  SetLength(outb, Length(ct) + 32);
  ctx := fCtxNew();
  if ctx = nil then Refuse('cipher context');
  try
    if fDecInit(ctx, fAesGcm(), nil, nil, nil) <> 1 then Exit;
    if fCtrl(ctx, $9, 12, nil) <> 1 then Exit;
    if fDecInit(ctx, nil, nil, @key[0], PByte(PChar(iv))) <> 1 then Exit;
    ol := 0;
    if fDecUpdate(ctx, PByte(PChar(outb)), ol, PByte(PChar(ct)), Length(ct)) <> 1 then Exit;
    if fCtrl(ctx, $11, 16, PChar(tag)) <> 1 then Exit;
    tl := 0;
    if fDecFinal(ctx, PByte(PChar(outb)) + ol, tl) <> 1 then Exit;   // the tag does not match: PHP's openssl_decrypt gives false -> ''
    SetLength(outb, ol + tl);
    Result := outb;
  finally
    fCtxFree(ctx);
  end;
end;

{ ---- the JSON side: PHP's json_decode / isset / ?? semantics for the shapes used ---- }
function Parse(const S: string): TJSONData;
var
  P: TJSONParser;
begin
  Result := nil;
  P := TJSONParser.Create(S, [joUTF8]);
  try
    try
      Result := P.Parse;
    except
      Result := nil;
    end;
  finally
    P.Free;
  end;
  if (Result <> nil) and not (Result.JSONType in [jtObject, jtArray]) then begin Result.Free; Result := nil; end;
end;

{ $d[$k] ?? null : nil when unset or null }
function Get(D: TJSONData; const K: string): TJSONData; overload;
var
  i: Integer;
begin
  Result := nil;
  if D = nil then Exit;
  if D.JSONType = jtObject then Result := TJSONObject(D).Find(K)
  else if D.JSONType = jtArray then
  begin
    i := StrToIntDef(K, -1);
    if (i >= 0) and (IntToStr(i) = K) and (i < TJSONArray(D).Count) then Result := TJSONArray(D).Items[i];
  end;
  if (Result <> nil) and (Result.JSONType = jtNull) then Result := nil;
end;

function IsContainer(D: TJSONData): Boolean;
begin
  Result := (D <> nil) and (D.JSONType in [jtObject, jtArray]);
end;

{ a value that must be text for the byte-exact result: a string (or null/unset -> Def) }
function TextOr(D: TJSONData; const Def: string): string;
begin
  if D = nil then Exit(Def);
  if D.JSONType <> jtString then Refuse('a non-text value where text is expected');
  Result := D.AsString;
end;

{ PHP empty() negated }
function Truthy(D: TJSONData): Boolean;
begin
  if D = nil then Exit(False);
  case D.JSONType of
    jtBoolean: Result := D.AsBoolean;
    jtNumber: Result := D.AsFloat <> 0;
    jtString: Result := (D.AsString <> '') and (D.AsString <> '0');
    jtObject, jtArray: Result := D.Count > 0;
  else Result := False;
  end;
end;

{ json_encode($s, JSON_UNESCAPED_UNICODE) of a string }
function PhpJsonStr(const S: string): string;
var
  i: Integer;
  c: Byte;
  r: string;
begin
  r := '"'; i := 1;
  while i <= Length(S) do
  begin
    c := Ord(S[i]);
    case c of
      34: r := r + '\"';
      92: r := r + '\\';
      47: r := r + '\/';
      8: r := r + '\b';
      12: r := r + '\f';
      10: r := r + '\n';
      13: r := r + '\r';
      9: r := r + '\t';
      0..7, 11, 14..31: r := r + '\u00' + LowerCase(IntToHex(c, 2));
      $E2:
        if (i + 2 <= Length(S)) and (Ord(S[i + 1]) = $80) and (Ord(S[i + 2]) in [$A8, $A9]) then
        begin
          if Ord(S[i + 2]) = $A8 then r := r + '\' + 'u2028' else r := r + '\' + 'u2029';
          Inc(i, 2);
        end
        else r := r + Chr(c);
    else r := r + Chr(c);
    end;
    Inc(i);
  end;
  Result := r + '"';
end;

function ValidUtf8(const S: string): Boolean;
var
  i, n, need: Integer;
  c, c0: Byte;
  cp: Cardinal;
begin
  i := 1; n := Length(S);
  while i <= n do
  begin
    c := Ord(S[i]); c0 := c;
    if c < $80 then begin Inc(i); Continue; end;
    if (c >= $C2) and (c <= $DF) then begin need := 1; cp := c and $1F; end
    else if (c >= $E0) and (c <= $EF) then begin need := 2; cp := c and $0F; end
    else if (c >= $F0) and (c <= $F4) then begin need := 3; cp := c and $07; end
    else Exit(False);
    if i + need > n then Exit(False);
    while need > 0 do
    begin
      Inc(i); c := Ord(S[i]);
      if (c and $C0) <> $80 then Exit(False);
      cp := (cp shl 6) or (c and $3F); Dec(need);
    end;
    if ((cp < $800) and (c0 >= $E0)) or ((cp < $10000) and (c0 >= $F0)) or (cp > $10FFFF) or ((cp >= $D800) and (cp <= $DFFF)) then Exit(False);
    Inc(i);
  end;
  Result := True;
end;

function RawUrlEncode(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then Result := Result + S[i]
    else Result := Result + '%' + IntToHex(Ord(S[i]), 2);
end;

type
  TProv = (pvGroq, pvHF, pvCF);

{ the failure text of the _http_post_json for HTTP >= 400 }
function HttpError(Status: Integer; const Body: string): string;
var
  j, e, m: TJSONData;
  msg: string;
begin
  msg := '';
  j := Parse(Body);
  try
    if j <> nil then
    begin
      e := Get(j, 'error');
      if IsContainer(e) then
      begin
        m := Get(e, 'message');
        if m <> nil then msg := TextOr(m, '')
        else Refuse('error is not text');
      end
      else if e <> nil then msg := TextOr(e, '');
    end;
  finally
    j.Free;
  end;
  if (msg = '') or (msg = '0') then msg := Copy(Body, 1, 300);
  Result := 'HTTP ' + IntToStr(Status);
  if (msg <> '') and (msg <> '0') then Result := Result + ': ' + msg;
end;

function WorkersRelay(const Provider, Model, PromptFile, DataDir, Base: string; out Output: string): Integer;
var
  prompt, keysFile, blob, plain, key, token, acct, url, payload, root, up: string;
  kj, j, v, c0: TJSONData;
  prov: TProv;
  hdrs: TStringList;
  r: THttpsResult;
  p: Integer;
  ok: Boolean;
  fail: string;
  txt: string;
begin
  Output := '';
  Result := 9;
  kj := nil; j := nil;
  hdrs := TStringList.Create;
  try
    try
      if Provider = 'groq' then prov := pvGroq
      else if Provider = 'huggingface' then prov := pvHF
      else if Provider = 'cloudflare' then prov := pvCF
      else Refuse('provider not handled here');
      if (Model = '') or (PromptFile = '') then Refuse('missing model or prompt file');
      if not FileExists(PromptFile) then Refuse('prompt file not readable');
      prompt := ReadWhole(PromptFile);
      if prompt = '' then Refuse('empty prompt');
      if not ValidUtf8(prompt) or not ValidUtf8(Model) then Refuse('not valid UTF-8');
      up := UpperCase(Provider);

      { the key: load_keys() }
      key := '';
      if (DataDir = '') or not DirectoryExists(DataDir) then Refuse('no per-user data folder (the PHP then reads the shared one)');
      begin
        keysFile := IncludeTrailingPathDelimiter(DataDir) + 'workers_keys.enc';
        if FileExists(keysFile) then
        begin
          blob := PhpTrim(ReadWhole(keysFile));
          if blob <> '' then
          begin
            plain := DecryptBlob(blob);
            if plain <> '' then
            begin
              kj := Parse(plain);
              v := Get(kj, Provider);
              if v <> nil then
              begin
                if v.JSONType <> jtString then Refuse('key is not text');
                key := v.AsString;
              end;
            end;
          end;
        end;
      end;
      if (key = '') or (key = '0') then begin Output := '[' + up + ' ERROR] No API key'; Exit(0); end;

      hdrs.Add('Content-Type: application/json');
      case prov of
        pvGroq:
          begin
            if Base <> '' then root := Base else root := 'https://api.groq.com/openai/v1';
            url := root + '/chat/completions';
            payload := '{"model":' + PhpJsonStr(Model) + ',"messages":[{"role":"user","content":' + PhpJsonStr(prompt) + '}],"max_tokens":2000}';
            hdrs.Add('Authorization: Bearer ' + key);
          end;
        pvHF:
          begin
            if Base <> '' then root := Base else root := 'https://router.huggingface.co/hf-inference';
            url := root + '/models/' + Model;
            payload := '{"inputs":' + PhpJsonStr(prompt) + '}';
            hdrs.Add('Authorization: Bearer ' + key);
          end;
        pvCF:
          begin
            p := Pos(':', key);
            if (p <= 1) or (p = Length(key)) then begin Output := '[CLOUDFLARE ERROR] Cloudflare key must be "ACCOUNT_ID:API_TOKEN"'; Exit(0); end;
            acct := Copy(key, 1, p - 1); token := Copy(key, p + 1, MaxInt);
            if Base <> '' then root := Base else root := 'https://api.cloudflare.com/client/v4';
            url := root + '/accounts/' + RawUrlEncode(acct) + '/ai/run/' + Model;
            payload := '{"messages":[{"role":"user","content":' + PhpJsonStr(prompt) + '}]}';
            hdrs.Add('Authorization: Bearer ' + token);
          end;
      end;

      r := HttpsRequest('POST', url, payload, hdrs, 60, '', '');
      if not r.Ok then begin Output := '[' + up + ' ERROR] curl: ' + r.Err; Exit(0); end;
      if (r.Status >= 300) and (r.Status < 400) then Refuse('redirect');
      if r.Status >= 400 then begin Output := '[' + up + ' ERROR] ' + HttpError(r.Status, r.Body); Exit(0); end;

      ok := True; fail := ''; txt := '';
      if (prov = pvHF) and ((LowerCase(Copy(r.ContentType, 1, 6)) = 'image/') or (LowerCase(Copy(r.ContentType, 1, 6)) = 'audio/')) then
        txt := 'data:' + r.ContentType + ';base64,' + B64Encode(r.Body)
      else
      begin
        j := Parse(r.Body);
        case prov of
          pvGroq:
            begin
              if j = nil then begin ok := False; fail := 'Bad JSON from Groq'; end
              else if Get(j, 'error') <> nil then
              begin
                ok := False;
                v := Get(j, 'error');
                if IsContainer(v) then fail := TextOr(Get(v, 'message'), 'Groq error') else fail := 'Groq error';
              end
              else
              begin
                v := Get(j, 'choices'); v := Get(v, '0'); v := Get(v, 'message'); v := Get(v, 'content');
                txt := TextOr(v, '');
              end;
            end;
          pvHF:
            begin
              if j = nil then begin ok := False; fail := 'Bad response from HuggingFace'; end
              else if Get(j, 'error') <> nil then begin ok := False; fail := TextOr(Get(j, 'error'), ''); end
              else
              begin
                v := Get(j, '0'); c0 := v;
                if (j.JSONType <> jtArray) then Refuse('not a list');
                if Get(c0, 'generated_text') <> nil then txt := TextOr(Get(c0, 'generated_text'), '')
                else if Get(c0, 'translation_text') <> nil then txt := TextOr(Get(c0, 'translation_text'), '')
                else Refuse('pretty-printed JSON fallback');
              end;
            end;
          pvCF:
            begin
              if j = nil then begin ok := False; fail := 'Bad JSON from Cloudflare'; end
              else if not Truthy(Get(j, 'success')) then
              begin
                ok := False;
                v := Get(j, 'errors'); v := Get(v, '0');
                fail := TextOr(Get(v, 'message'), 'Cloudflare error');
              end
              else
              begin
                v := Get(j, 'result');
                txt := TextOr(Get(v, 'response'), '');
              end;
            end;
        end;
      end;
      if ok then Output := txt else Output := '[' + up + ' ERROR] ' + fail;
      Result := 0;
    except
      on E: TRefused do begin Output := ''; Result := 9; end;
    end;
  finally
    kj.Free; j.Free;
    hdrs.Free;
  end;
end;

end.
