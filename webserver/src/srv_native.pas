(* =============================================================================
  srv_native — requests aicserver answers ITSELF instead of handing them to PHP (opt-in, per config "native").

  The first one: bridge.php's  mode=poll  (the chat's "give me the new bytes of the answer" call, made every few hundred ms).

  The rule that keeps this safe: the server answers ONLY when it can prove the request is one PHP would answer the same way, and passes
  EVERYTHING ELSE to PHP, untouched, before it has changed anything:
    * the person must hold a valid PHP session: the cockpit_sid cookie names a session file in the session folder (the same one php-cgi
      writes), which carries cockpit_user and cockpit_role and is younger than the cookie lifetime. No session / unreadable / odd -> PHP
      (it does the remember-me logic and answers 401);
    * the request body is a small JSON object with mode "poll", a plain string token and a plain integer offset;
    * while the answer is still being written, the agent's loop must be reported running by the supervisor (so the PHP's tmux fallback and
      its "session died" answer stay PHP's); the supervisor's control socket is asked, as session_backend.php does;
    * the new bytes are valid UTF-8 and contain no diff marker ("@@") - the cases whose PHP result depends on regular-expression details.
  When it answers it does what bridge.php does: reads the bytes from the offset, strips terminal escape sequences and control characters
  (cleanChunk), and on the final poll removes the .out and .done files.

  Output: {"ok":true,"chunk":"...","offset":N,"done":false}  written the way PHP's json_encode(JSON_UNESCAPED_UNICODE) writes it.
  ============================================================================= *)
unit srv_native;

{$mode objfpc}{$H+}

interface

{ True = Reply is the whole JSON answer (status 200); False = not handled here: give the request to PHP }
function NativeBridgePoll(const MountRoot, SessionDir, SupervisorDir: string; SessionDays: Integer; const CookieHeader, Body: string;
  out Reply: string): Boolean;

implementation

uses
  SysUtils, Classes, BaseUnix, Unix, Sockets, fpjson, jsonparser;

function ReadAll(const F: string; out S: string): Boolean;
var
  fs: TFileStream;
begin
  S := ''; Result := False;
  try
    fs := TFileStream.Create(F, fmOpenRead or fmShareDenyNone);
    try
      SetLength(S, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(S[1], fs.Size);
      Result := True;
    finally
      fs.Free;
    end;
  except
    S := '';
  end;
end;

function CookieValue(const Header, Name: string): string;
var
  i, j: Integer;
  h: string;
begin
  Result := '';
  h := '; ' + Header;
  i := Pos('; ' + Name + '=', h);
  if i = 0 then Exit;
  i := i + Length(Name) + 3;
  j := i;
  while (j <= Length(h)) and (h[j] <> ';') do Inc(j);
  Result := Trim(Copy(h, i, j - i));
end;

{ the value of  key|s:N:"value";  at the top level of a PHP session file ('' when absent) }
function SessionString(const Data, Key: string): string;
var
  p, q, n, k: Integer;
  lenS: string;
begin
  Result := '';
  p := Pos(Key + '|s:', Data);
  while p > 0 do
  begin
    if (p = 1) or (Data[p - 1] in [';', '}']) then
    begin
      q := p + Length(Key) + 3; lenS := '';
      while (q <= Length(Data)) and (Data[q] in ['0'..'9']) do begin lenS := lenS + Data[q]; Inc(q); end;
      n := StrToIntDef(lenS, -1);
      if (n >= 0) and (q + 1 + n <= Length(Data)) and (Copy(Data, q, 2) = ':"') and (Data[q + 2 + n] = '"') then
      begin
        Result := Copy(Data, q + 2, n);
        Exit;
      end;
      Exit('');
    end;
    k := Pos(Key + '|s:', Copy(Data, p + 1, MaxInt));
    if k = 0 then Break;
    p := p + k;
  end;
end;

function SessionValid(const SessionDir, CookieHeader: string; SessionDays: Integer): Boolean;
var
  sid, data, u, r, f: string;
  i: Integer;
  age: LongInt;
begin
  Result := False;
  sid := CookieValue(CookieHeader, 'cockpit_sid');
  if (Length(sid) < 22) or (Length(sid) > 256) then Exit;
  for i := 1 to Length(sid) do if not (sid[i] in ['A'..'Z', 'a'..'z', '0'..'9', ',', '-']) then Exit;
  f := IncludeTrailingPathDelimiter(SessionDir) + 'sess_' + sid;
  age := FileAge(f);
  if age = -1 then Exit;
  if (Now - FileDateToDateTime(age)) > SessionDays then Exit;
  if not ReadAll(f, data) then Exit;
  u := SessionString(data, 'cockpit_user'); r := SessionString(data, 'cockpit_role');
  Result := (u <> '') and (r <> '');
end;

{ one request to the supervisor's control socket; '' when nobody answered }
function SupervisorCall(const Dir, ReqJson: string): string;
var
  fd: cint;
  au: sockaddr_un;
  tv: TTimeVal;
  buf: array[0..16383] of Char;
  n: PtrInt;
  tok, s: string;
begin
  Result := '';
  if not ReadAll(Dir + '/token', tok) then Exit;
  tok := Trim(tok);
  if (tok = '') or not FileExists(Dir + '/sup.sock') then Exit;
  fd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if fd < 0 then Exit;
  try
    fpFcntl(fd, F_SETFD, 1);
    tv.tv_sec := 2; tv.tv_usec := 0;
    fpSetSockOpt(fd, SOL_SOCKET, SO_RCVTIMEO, @tv, SizeOf(tv));
    fpSetSockOpt(fd, SOL_SOCKET, SO_SNDTIMEO, @tv, SizeOf(tv));
    FillChar(au, SizeOf(au), 0); au.sun_family := AF_UNIX; StrPCopy(au.sun_path, Dir + '/sup.sock');
    if fpConnect(fd, @au, SizeOf(au)) <> 0 then Exit;
    s := '{"token":"' + tok + '",' + ReqJson + '}' + #10;
    if fpSend(fd, @s[1], Length(s), 0) <> Length(s) then Exit;
    s := '';
    repeat
      n := fpRecv(fd, @buf[0], SizeOf(buf), 0);
      if n > 0 then begin SetString(s, PChar(@buf[0]), n); Result := Result + s; if Pos(#10, s) > 0 then Break; end;
    until n <= 0;
  finally
    fpClose(fd);
  end;
end;

{ the supervisor says cockpit_<agent> is running or starting with a real pid }
function AgentAlive(const SupDir, Agent: string): Boolean;
var
  r: string;
  j, sv: TJSONData;
  a: TJSONArray;
  i: Integer;
  st: string;
begin
  Result := False;
  if not FileExists(ExtractFileDir(ExcludeTrailingPathDelimiter(SupDir)) + '/use_supervisor') then Exit;    // switch off: PHP asks tmux
  r := SupervisorCall(SupDir, '"op":"status"');
  if r = '' then Exit;
  try
    j := GetJSON(r);
  except
    Exit;
  end;
  try
    if j.JSONType <> jtObject then Exit;
    sv := TJSONObject(j).Find('services');
    if (sv = nil) or (sv.JSONType <> jtArray) then Exit;
    a := TJSONArray(sv);
    for i := 0 to a.Count - 1 do
      if (a[i].JSONType = jtObject) and (TJSONObject(a[i]).Get('name', '') = 'cockpit_' + Agent) then
      begin
        st := TJSONObject(a[i]).Get('state', '');
        Result := ((st = 'running') or (st = 'starting')) and (TJSONObject(a[i]).Get('pid', 0) > 1);
        Exit;
      end;
  finally
    j.Free;
  end;
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

{ bridge.php cleanChunk(), step by step; the caller has made sure the text is valid UTF-8 }
function CleanChunk(const S: string): string;
var
  r: string;
  i, n, j: Integer;
  c: Char;

  procedure Step1;     { \x1B\[[0-9;?]*[a-zA-Z] }
  var o: string; k, m: Integer;
  begin
    o := ''; k := 1; m := Length(r);
    while k <= m do
    begin
      if (r[k] = #27) and (k < m) and (r[k + 1] = '[') then
      begin
        j := k + 2;
        while (j <= m) and (r[j] in ['0'..'9', ';', '?']) do Inc(j);
        if (j <= m) and (r[j] in ['a'..'z', 'A'..'Z']) then begin k := j + 1; Continue; end;
      end;
      o := o + r[k]; Inc(k);
    end;
    r := o;
  end;

  procedure Step2;     { \x1B[=>] }
  var o: string; k, m: Integer;
  begin
    o := ''; k := 1; m := Length(r);
    while k <= m do
    begin
      if (r[k] = #27) and (k < m) and (r[k + 1] in ['=', '>']) then begin Inc(k, 2); Continue; end;
      o := o + r[k]; Inc(k);
    end;
    r := o;
  end;

  procedure Step4;     { \[\?[0-9]+[hl] }
  var o: string; k, m: Integer;
  begin
    o := ''; k := 1; m := Length(r);
    while k <= m do
    begin
      if (r[k] = '[') and (k + 1 <= m) and (r[k + 1] = '?') then
      begin
        j := k + 2;
        while (j <= m) and (r[j] in ['0'..'9']) do Inc(j);
        if (j > k + 2) and (j <= m) and (r[j] in ['h', 'l']) then begin k := j + 1; Continue; end;
      end;
      o := o + r[k]; Inc(k);
    end;
    r := o;
  end;

  procedure Step5;     { \[[0-9]*[ABCDGJKM] }
  var o: string; k, m: Integer;
  begin
    o := ''; k := 1; m := Length(r);
    while k <= m do
    begin
      if r[k] = '[' then
      begin
        j := k + 1;
        while (j <= m) and (r[j] in ['0'..'9']) do Inc(j);
        if (j <= m) and (r[j] in ['A', 'B', 'C', 'D', 'G', 'J', 'K', 'M']) then begin k := j + 1; Continue; end;
      end;
      o := o + r[k]; Inc(k);
    end;
    r := o;
  end;

  procedure Step6;     { \?[0-9]+[hl] }
  var o: string; k, m: Integer;
  begin
    o := ''; k := 1; m := Length(r);
    while k <= m do
    begin
      if r[k] = '?' then
      begin
        j := k + 1;
        while (j <= m) and (r[j] in ['0'..'9']) do Inc(j);
        if (j > k + 1) and (j <= m) and (r[j] in ['h', 'l']) then begin k := j + 1; Continue; end;
      end;
      o := o + r[k]; Inc(k);
    end;
    r := o;
  end;

begin
  r := S;
  Step1; Step2;
  { \r }
  n := 0; for i := 1 to Length(r) do if r[i] <> #13 then begin Inc(n); r[n] := r[i]; end;
  SetLength(r, n);
  Step4; Step5; Step6;
  { [\x00-\x08\x0B\x0C\x0E-\x1F\x7F] }
  n := 0;
  for i := 1 to Length(r) do
  begin
    c := r[i];
    if (Ord(c) <= 8) or (Ord(c) in [$0B, $0C]) or ((Ord(c) >= $0E) and (Ord(c) <= $1F)) or (Ord(c) = $7F) then Continue;
    Inc(n); r[n] := c;
  end;
  SetLength(r, n);
  { the braille spinner [\x{2800}-\x{28FF}]+\s*  (U+2800..U+28FF = E2 A0..A3 80..BF) followed by white space }
  Result := '';
  i := 1; n := Length(r);
  while i <= n do
  begin
    if (r[i] = #$E2) and (i + 2 <= n) and (Ord(r[i + 1]) in [$A0..$A3]) and (Ord(r[i + 2]) in [$80..$BF]) then
    begin
      while (i + 2 <= n) and (r[i] = #$E2) and (Ord(r[i + 1]) in [$A0..$A3]) and (Ord(r[i + 2]) in [$80..$BF]) do Inc(i, 3);
      { \s in PCRE with /u: space, \t \n \v(0B) \f \r  (ASCII; the other Unicode spaces are not matched without UCP) }
      while (i <= n) and (r[i] in [' ', #9, #10, #11, #12, #13]) do Inc(i);
      Continue;
    end;
    Result := Result + r[i]; Inc(i);
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

function ReadRange(const F: string; From, Count: Int64; out S: string): Boolean;
var
  fs: TFileStream;
begin
  S := ''; Result := False;
  try
    fs := TFileStream.Create(F, fmOpenRead or fmShareDenyNone);
    try
      fs.Position := From;
      SetLength(S, Count);
      if Count > 0 then
      begin
        Count := fs.Read(S[1], Count);
        SetLength(S, Count);
      end;
      Result := True;
    finally
      fs.Free;
    end;
  except
    S := '';
  end;
end;

function FileSizeOf(const F: string): Int64;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(F, faAnyFile, sr) = 0 then begin Result := sr.Size; FindClose(sr); end;
end;

function NativeBridgePoll(const MountRoot, SessionDir, SupervisorDir: string; SessionDays: Integer; const CookieHeader, Body: string;
  out Reply: string): Boolean;
var
  j, v: TJSONData;
  o: TJSONObject;
  token, agent, respDir, outF, doneF, pj, chunk, more: string;
  i: Integer;
  offset, size, finalSize, rawLen: Int64;
  exists, done: Boolean;
  pjo: TJSONData;
  agentRaw: string;
begin
  Result := False; Reply := '';
  j := nil; pjo := nil;
  try
    if (Length(Body) = 0) or (Length(Body) > 65536) then Exit;
    try
      j := GetJSON(Body);
    except
      Exit;
    end;
    if (j = nil) or (j.JSONType <> jtObject) then Exit;
    o := TJSONObject(j);
    v := o.Find('mode');
    if (v = nil) or (v.JSONType <> jtString) or (v.AsString <> 'poll') then Exit;
    if not SessionValid(SessionDir, CookieHeader, SessionDays) then Exit;

    v := o.Find('token');
    if (v <> nil) and (v.JSONType <> jtString) and (v.JSONType <> jtNull) then Exit;
    token := '';
    if (v <> nil) and (v.JSONType = jtString) then
      for i := 1 to Length(v.AsString) do if v.AsString[i] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '.'] then token := token + v.AsString[i];
    offset := 0;
    v := o.Find('offset');
    if v <> nil then
    begin
      if (v.JSONType = jtNumber) and (TJSONNumber(v).NumberType in [ntInteger, ntInt64]) then offset := v.AsInt64
      else if v.JSONType = jtNull then offset := 0
      else if (v.JSONType = jtString) and (StrToInt64Def(v.AsString, -1) >= 0) and (IntToStr(StrToInt64Def(v.AsString, -1)) = v.AsString) then offset := StrToInt64(v.AsString)
      else Exit;
    end;
    if offset < 0 then offset := 0;
    if (token = '') or (token = '0') then          { PHP: !$token }
    begin
      Reply := '{"error":true,"message":"Missing token"}';
      Exit(True);
    end;

    { where the responses are: paths.json's response_dir, else <web root>/responses (paths.php) }
    respDir := IncludeTrailingPathDelimiter(MountRoot) + 'responses';
    if ReadAll(IncludeTrailingPathDelimiter(MountRoot) + 'paths.json', pj) then
    begin
      try
        pjo := GetJSON(pj);
      except
        Exit;
      end;
      if (pjo <> nil) and (pjo.JSONType = jtObject) then
      begin
        v := TJSONObject(pjo).Find('response_dir');
        if (v <> nil) and (v.JSONType <> jtNull) then
        begin
          if v.JSONType <> jtString then Exit;
          respDir := v.AsString;
        end;
      end;
    end;
    respDir := ExcludeTrailingPathDelimiter(respDir);
    outF := respDir + '/' + token + '.out'; doneF := respDir + '/' + token + '.done';

    exists := FileExists(outF); done := FileExists(doneF);
    size := 0; if exists then size := FileSizeOf(outF);
    chunk := ''; rawLen := 0;
    if exists and (size > offset) then
    begin
      if not ReadRange(outF, offset, size - offset, chunk) then Exit;
      rawLen := Length(chunk);
    end;
    if done then
    begin
      finalSize := 0; if exists then finalSize := FileSizeOf(outF);
      if finalSize > offset + rawLen then
      begin
        if not ReadRange(outF, offset + rawLen, finalSize - offset - rawLen, more) then Exit;
        Exit;                       { a write landed between the two reads: rare; PHP does it }
      end;
    end;
    if not ValidUtf8(chunk) then Exit;
    if done and (Pos('@@', chunk) > 0) then Exit;          { the diff re-marking: PHP }
    chunk := CleanChunk(chunk);

    { the loop must be running while the answer is not complete }
    agentRaw := '';
    v := o.Find('agent');
    if (not done) and (v <> nil) and (v.JSONType <> jtNull) then
    begin
      if v.JSONType <> jtString then Exit;
      agentRaw := v.AsString;
    end;
    agent := '';
    for i := 1 to Length(agentRaw) do if agentRaw[i] in ['a'..'z'] then agent := agent + agentRaw[i];
    if (not done) and (agentRaw <> '') then
    begin
      { PHP's !empty($in['agent']): the string "0" counts as empty }
      if agentRaw <> '0' then
      begin
        if agent = '' then Exit;
        if not AgentAlive(SupervisorDir, agent) then Exit;
      end;
    end;

    { all decided: now the one side effect }
    if done then
    begin
      DeleteFile(doneF);
      DeleteFile(outF);
    end;
    Reply := '{"ok":true,"chunk":' + PhpJsonStr(chunk) + ',"offset":' + IntToStr(size) + ',"done":' + BoolToStr(done, 'true', 'false') + '}';
    Result := True;
  finally
    j.Free; pjo.Free;
  end;
end;

end.
