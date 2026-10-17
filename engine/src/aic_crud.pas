(* =============================================================================
  aic_crud — carrying out the %%COMMAND%% markers of an agent's answer, native:   aicengine crud PROJECT_DIR RESPONSE_FILE [PROPOSER] [PROJECT_NAME]

  The same results as scripts/crud_cli.php (the byte-exact reference of crud_executor.sh): CREATE / UPDATE / APPEND blocks, PROPOSE blocks, READ, DELETE (with
  %%CONFIRM:DELETE%%), MKDIR, LIST, FETCH, SEARCH, WORKER, TOOL, LOAD_SKILL, LIB / SNIP / SRC; one result line (or block) per marker on standard output. Every quirk
  of the reference is kept (it is the contract the agents have been shown); the one deliberate difference, refusing to delete the project directory itself, is the
  reference's too. The web markers call Cockpit's own pages (search.php, workers.php, tools.php, library.php) with the loop's key in a header, through the engine's own
  HTTP client (aic_https: plain http, or https with the certificate and host name checked).
  Exit 9 = REFUSED before touching anything, for what this program does not copy exactly: text that is not valid UTF-8 where the reference counts characters, a result
  from a page that has a value this program would have to format as the reference's JSON printer does (non-integer numbers, arrays, objects), a provider name that is a
  regular expression in the reference. The caller then uses the PHP helper.
  tests/crud_parity.sh runs this against the reference on the same scenarios, with a mock web server that records the requests.
  ============================================================================= *)
unit aic_crud;

{$mode objfpc}{$H+}

interface

const
  CRUD_REFUSED = 9;

{ AllS = standard output and standard error as one stream in the order they were produced (what the loop shows the agent) }
function CrudRun(const ProjectDir, ResponseFile, Proposer, ProjectName: string; out OutS, ErrS, AllS: string): Integer;

implementation

uses
  SysUtils, Classes, BaseUnix, fpjson, jsonparser, jsonscanner, aic_https, aic_proc;

const
  READ_MAX = 16384;

type
  ECrudRefuse = class(Exception);

var
  GOut, GErr, GAll: string;
  GProject, GProposer, GProjName, GHome, GData, GDataUser, GBase: string;
  GHdrKey, GHdrUser: string;

function c_realpath(path, resolved: PChar): PChar; cdecl; external 'c' name 'realpath';

procedure Refuse(const Why: string);
begin
  raise ECrudRefuse.Create(Why);
end;

procedure Out_(const S: string);
begin
  GOut := GOut + S; GAll := GAll + S;
end;

procedure LineOut(const S: string);
begin
  GOut := GOut + S + #10; GAll := GAll + S + #10;
end;

procedure ErrOut(const S: string);
begin
  GErr := GErr + S; GAll := GAll + S;
end;

{ ---- strings ------------------------------------------------------------------------------------------------------------------------- }

function ReadFile_(const F: string; out Ok: Boolean): string;
var
  fs: TFileStream;
begin
  Result := ''; Ok := False;
  try
    fs := TFileStream.Create(F, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(Result[1], fs.Size);
      Ok := True;
    finally
      fs.Free;
    end;
  except
    Result := '';
  end;
end;

function StrRep(const S, A, B: string): string;
begin
  Result := StringReplace(S, A, B, [rfReplaceAll]);
end;

function RTrimNl(const S: string): string;
var
  n: Integer;
begin
  n := Length(S);
  while (n > 0) and (S[n] = #10) do Dec(n);
  Result := Copy(S, 1, n);
end;

function Explode(const Sep, S: string): TStringList;
var
  p, q: Integer;
begin
  Result := TStringList.Create;
  p := 1;
  repeat
    q := Pos(Sep, Copy(S, p, MaxInt));
    if q = 0 then begin Result.Add(Copy(S, p, MaxInt)); Break; end;
    Result.Add(Copy(S, p, q - 1));
    p := p + q - 1 + Length(Sep);
  until False;
end;

function IsVws(c: Char): Boolean;           // a class written [ \t\n\v\f\r]: PCRE's \v also takes the byte 0x85
begin
  Result := c in [' ', #9, #10, #11, #12, #13, #133];
end;

function LowerAscii(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do if Result[i] in ['A'..'Z'] then Result[i] := Chr(Ord(Result[i]) + 32);
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

function Utf8Len(const S: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to Length(S) do if (Ord(S[i]) and $C0) <> $80 then Inc(Result);
end;

function Utf8Head(const S: string; N: Integer): string;
var
  i, cnt: Integer;
begin
  cnt := 0;
  for i := 1 to Length(S) do
    if (Ord(S[i]) and $C0) <> $80 then
    begin
      if cnt = N then Exit(Copy(S, 1, i - 1));
      Inc(cnt);
    end;
  Result := S;
end;

function OnlyNeE(const S: string): Boolean;       // ^-[neE]+$  (what `echo "$x"` takes for options)
var
  i: Integer;
begin
  Result := (Length(S) >= 2) and (S[1] = '-');
  if not Result then Exit;
  for i := 2 to Length(S) do if not (S[i] in ['n', 'e', 'E']) then Exit(False);
end;

function PosFrom(const Sub, S: string; From: Integer): Integer;
var
  p: Integer;
begin
  p := Pos(Sub, Copy(S, From, MaxInt));
  if p = 0 then Result := 0 else Result := p + From - 1;
end;

{ ---- marker matching: the reference's regular expressions, as plain scans ------------------------------------------------------------------- }

{ %%NAME:([^%]+)%%   (Min1 = False: ([^%]*) )  case-insensitive NAME; the first place in the line where it matches }
function MatchOne(const Line, Name: string; Min1: Boolean; out Cap: string): Boolean;
var
  i, j, k: Integer;
  lname: string;
begin
  Result := False; Cap := '';
  lname := '%%' + LowerAscii(Name) + ':';
  i := 1;
  while i <= Length(Line) - Length(lname) do
  begin
    if LowerAscii(Copy(Line, i, Length(lname))) = lname then
    begin
      j := i + Length(lname); k := j;
      while (k <= Length(Line)) and (Line[k] <> '%') do Inc(k);
      if ((k > j) or not Min1) and (Copy(Line, k, 2) = '%%') then begin Cap := Copy(Line, j, k - j); Exit(True); end;
    end;
    Inc(i);
  end;
end;

{ %%NAME:([^:]+):([^:]+):([^%]+)%% }
function MatchThree(const Line, Name: string; out A, B, C: string): Boolean;
var
  i, j, k, l: Integer;
  lname: string;
begin
  Result := False;
  lname := '%%' + LowerAscii(Name) + ':';
  i := 1;
  while i <= Length(Line) - Length(lname) do
  begin
    if LowerAscii(Copy(Line, i, Length(lname))) = lname then
    begin
      j := i + Length(lname);
      k := j; while (k <= Length(Line)) and (Line[k] <> ':') do Inc(k);
      if (k > j) and (k <= Length(Line)) then
      begin
        A := Copy(Line, j, k - j);
        j := k + 1; l := j; while (l <= Length(Line)) and (Line[l] <> ':') do Inc(l);
        if (l > j) and (l <= Length(Line)) then
        begin
          B := Copy(Line, j, l - j);
          j := l + 1; k := j; while (k <= Length(Line)) and (Line[k] <> '%') do Inc(k);
          if (k > j) and (Copy(Line, k, 2) = '%%') then begin C := Copy(Line, j, k - j); Exit(True); end;
        end;
      end;
    end;
    Inc(i);
  end;
end;

{ ---- the sandbox ------------------------------------------------------------------------------------------------------------------------------ }

function RealPathM(const Path: string): string;           // realpath -m
var
  todo: TStringList;
  cur, c, cand, t: string;
  links, p, i: Integer;
  parts: TStringList;
  st: Stat;
  buf: array[0..4095] of Char;
  n: PtrInt;
begin
  todo := TStringList.Create; parts := nil;
  try
    parts := Explode('/', Path);
    for i := parts.Count - 1 downto 0 do todo.Add(parts[i]);        // a stack: the end is the top
    parts.Free; parts := nil;
    cur := ''; links := 0;
    while todo.Count > 0 do
    begin
      c := todo[todo.Count - 1]; todo.Delete(todo.Count - 1);
      if (c = '') or (c = '.') then Continue;
      if c = '..' then
      begin
        if cur = '' then cur := '' else begin p := LastDelimiter('/', cur); if p <= 1 then cur := '' else cur := Copy(cur, 1, p - 1); end;
        Continue;
      end;
      cand := cur + '/' + c;
      if (fpLstat(PChar(cand), st) = 0) and fpS_ISLNK(st.st_mode) then
      begin
        Inc(links);
        if links > 40 then Exit(Path);
        n := fpReadLink(PChar(cand), @buf[0], SizeOf(buf) - 1);
        if n < 0 then Exit(Path);
        SetLength(t, n); if n > 0 then Move(buf[0], t[1], n);
        if (t <> '') and (t[1] = '/') then cur := '';
        parts := Explode('/', t);
        for i := parts.Count - 1 downto 0 do todo.Add(parts[i]);
        parts.Free; parts := nil;
        Continue;
      end;
      cur := cand;
    end;
    if cur = '' then Result := '/' else Result := cur;
  finally
    todo.Free; parts.Free;
  end;
end;

function SafePath(const RelIn: string): string;
var
  rel, resolved: string;
begin
  rel := RelIn;
  if (rel <> '') and (rel[1] = '/') then rel := Copy(rel, 2, MaxInt);
  if OnlyNeE(rel) then rel := '';
  rel := StrRep(rel, '../', '');
  resolved := RealPathM(GProject + '/' + rel);
  if Copy(resolved + '/', 1, Length(GProject) + 1) = GProject + '/' then Result := resolved else Result := '';
end;

{ ---- the web markers' transport ---------------------------------------------------------------------------------------------------------------- }

type
  TFetch = record
    Ok: Boolean;
    Body: string;
  end;

{ curl_run: any HTTP answer is a body; a failure to connect, a timeout, is '' (Ok False) }
function HttpCall(const Url: string; MaxTime: Integer; const PostBody: string; HasPost: Boolean; Follow: Boolean; Internal: Boolean = True): TFetch;
var
  h: TStringList;
  r: THttpsResult;
  u, method: string;
  hops: Integer;
begin
  Result.Ok := False; Result.Body := '';
  u := Url; hops := 0; method := 'GET';
  if HasPost then method := 'POST';
  repeat
    h := TStringList.Create;
    try
      if Internal and (Copy(u, 1, Length(GBase) + 1) = GBase + '/') and (GHdrKey <> '') and (GHdrUser <> '') then
      begin h.Add('X-Cockpit-Internal: ' + GHdrKey); h.Add('X-Cockpit-User: ' + GHdrUser); end;
      if HasPost and (method = 'POST') then h.Add('Content-Type: application/json');
      if method = 'POST' then r := HttpsRequest('POST', u, PostBody, h, MaxTime, '', '') else r := HttpsRequest('GET', u, '', h, MaxTime, '', '');
    finally
      h.Free;
    end;
    if not r.Ok then Exit;
    if Follow and (r.Status >= 300) and (r.Status < 400) and (r.Location <> '') and (hops < 20) then
    begin
      Inc(hops);
      if Pos('://', r.Location) > 0 then u := r.Location
      else if r.Location[1] = '/' then u := Copy(u, 1, Pos('/', Copy(u, Pos('://', u) + 3, MaxInt)) + Pos('://', u) + 1) + Copy(r.Location, 2, MaxInt)
      else Exit;                                      // a relative redirect: not copied
      method := 'GET';
      Continue;
    end;
    Result.Ok := True; Result.Body := r.Body;
    Exit;
  until False;
end;

function HttpGet(const Url: string; MaxTime: Integer): string;
begin
  Result := HttpCall(Url, MaxTime, '', False, False).Body;
end;

{ ---- json ----------------------------------------------------------------------------------------------------------------------------- }

function ParseJson(const S: string): TJSONData;           // nil when not JSON; refuses text that looks like JSON but is not strictly so
var
  p: TJSONParser;
  t: string;
  i: Integer;
begin
  Result := nil;
  t := S; i := 1;
  while (i <= Length(t)) and (t[i] in [' ', #9, #10, #13]) do Inc(i);
  try
    p := TJSONParser.Create(S, [joUTF8, joStrict]);
    try
      Result := p.Parse;
    finally
      p.Free;
    end;
  except
    Result := nil;
  end;
  if (Result = nil) and (i <= Length(t)) and (t[i] in ['{', '[']) then Refuse('a JSON-looking answer that is not strictly valid');
end;

{ jq -r '.key // "default"' on a decoded object (PHP: arrays are lists, non-arrays have no keys) }
function JqAlt(D: TJSONData; const Key, Def: string): string;
var
  v: TJSONData;
begin
  if (D = nil) or (D.JSONType <> jtObject) then Exit(Def);
  v := TJSONObject(D).Find(Key);
  if (v = nil) or (v.JSONType = jtNull) or ((v.JSONType = jtBoolean) and not v.AsBoolean) then Exit(Def);
  case v.JSONType of
    jtString: Result := v.AsString;
    jtBoolean: Result := 'true';
    jtNumber:
      if TJSONNumber(v).NumberType in [ntInteger, ntInt64] then Result := IntToStr(v.AsInt64)
      else Refuse('a number that is not an integer');
  else Refuse('a value that is an array or object');
  end;
end;

function DecodeObj(const S: string): TJSONData;           // json_decode($s, true) when it is an array/object, else nil
begin
  Result := ParseJson(S);
  if (Result <> nil) and not (Result.JSONType in [jtObject, jtArray]) then FreeAndNil(Result);
end;

function JsonEsc(const S: string): string;                // ${s//\\/\\\\} ${s//\"/\\\"} then \n \r \t
begin
  Result := StrRep(StrRep(StrRep(StrRep(StrRep(S, '\', '\\'), '"', '\"'), #10, '\n'), #13, '\r'), #9, '\t');
end;

{ PHP json_encode(string, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) }
function PhpJsonStr(const S: string): string;
var
  i: Integer;
  b: Byte;
begin
  if not ValidUtf8(S) then Refuse('a text that is not valid UTF-8 cannot be sent as JSON');
  Result := '"';
  i := 1;
  while i <= Length(S) do
  begin
    b := Ord(S[i]);
    case S[i] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #12: Result := Result + '\f';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
    else
      if b < 32 then Result := Result + '\u' + LowerCase(IntToHex(b, 4))
      else if (b = $E2) and (Copy(S, i, 3) = #$E2#$80#$A8) then begin Result := Result + ' '; Inc(i, 2); end
      else if (b = $E2) and (Copy(S, i, 3) = #$E2#$80#$A9) then begin Result := Result + ' '; Inc(i, 2); end
      else Result := Result + S[i];
    end;
    Inc(i);
  end;
  Result := Result + '"';
end;

{ ---- file helpers ---------------------------------------------------------------------------------------------------------------------------- }

function IsRegFile(const P: string): Boolean;
var
  st: Stat;
begin
  Result := (fpStat(PChar(P), st) = 0) and fpS_ISREG(st.st_mode);
end;

function IsDirPath(const P: string): Boolean;
var
  st: Stat;
begin
  Result := (fpStat(PChar(P), st) = 0) and fpS_ISDIR(st.st_mode);
end;

procedure RmRf(const P: string);
var
  st: Stat;
  sr: TSearchRec;
begin
  if fpLstat(PChar(P), st) <> 0 then Exit;
  if fpS_ISLNK(st.st_mode) or not fpS_ISDIR(st.st_mode) then begin fpUnlink(PChar(P)); Exit; end;
  if FindFirst(P + '/*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then RmRf(P + '/' + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  fpRmdir(PChar(P));
end;

function FileSizeOf(const P: string): Int64;
var
  st: Stat;
begin
  if fpStat(PChar(P), st) = 0 then Result := st.st_size else Result := -1;
end;

procedure WriteFileData(const Full, Data: string; Append: Boolean; var Failed: Boolean);
var
  fd: cint;
  fl: cint;
  n: PtrInt;
  p: Integer;
begin
  Failed := False;
  fl := O_WRONLY or O_CREAT;
  if Append then fl := fl or O_APPEND else fl := fl or O_TRUNC;
  fd := fpOpen(PChar(Full), fl, &666);
  if fd < 0 then begin Failed := True; Exit; end;
  p := 1;
  while p <= Length(Data) do
  begin
    n := fpWrite(fd, Data[p], Length(Data) - p + 1);
    if n <= 0 then begin Failed := True; Break; end;
    Inc(p, n);
  end;
  fpClose(fd);
end;

{ the lines of a text as `while IFS= read -r line || [ -n "$line" ]` sees them }
function BashLines(const Raw: string): TStringList;
var
  t: string;
begin
  t := StrRep(Raw, #0, '');
  Result := Explode(#10, t);
  if (Result.Count > 0) and (Result[Result.Count - 1] = '') then Result.Delete(Result.Count - 1);
end;

{ the text after the LAST  "key"[^"]*"  on a line, cut at its first quote: sub(/.*"key"[^"]*"/, "") ; sub(/".*/, "") }
function FieldOf(const Line, Key: string): string;
var
  needle, s: string;
  p, q: Integer;
  found: Boolean;
begin
  needle := '"' + Key + '"';
  s := Line; found := False;
  p := Length(Line) - Length(needle) + 1;
  while p >= 1 do
  begin
    if Copy(Line, p, Length(needle)) = needle then
    begin
      q := p + Length(needle);
      while (q <= Length(Line)) and (Line[q] <> '"') do Inc(q);
      if q <= Length(Line) then begin s := Copy(Line, q + 1, MaxInt); found := True; Break; end;
    end;
    Dec(p);
  end;
  if not found then s := Line;
  q := Pos('"', s);
  if q > 0 then s := Copy(s, 1, q - 1);
  Result := s;
end;

function AfterField(const Line, Key: string): string;       // preg_replace('/^.*"key"[^"]*"/s', '', $line, 1), without the cut at the next quote
var
  needle: string;
  p, q: Integer;
begin
  needle := '"' + Key + '"';
  Result := Line;
  p := Length(Line) - Length(needle) + 1;
  while p >= 1 do
  begin
    if Copy(Line, p, Length(needle)) = needle then
    begin
      q := p + Length(needle);
      while (q <= Length(Line)) and (Line[q] <> '"') do Inc(q);
      if q <= Length(Line) then Exit(Copy(Line, q + 1, MaxInt));
    end;
    Dec(p);
  end;
end;

{ ---- catalog lookups (LIB / SNIP / SRC) --------------------------------------------------------------------------------------------------------- }

{ jq: (.[$k] // [])[] | select(id == q or title lowercased == q or title lowercased contains q) | head -1; a jq runtime error ends the scan }
function CatalogFind(const Json, Kind, Q: string; out Item: TJSONObject; out Owner: TJSONData; out Temp: Boolean): Boolean;
var
  d, arr, it, v: TJSONData;
  i: Integer;
  t: string;
begin
  Result := False; Item := nil; Owner := nil; Temp := False;
  d := ParseJson(Json);
  if d = nil then Exit;
  Owner := d;
  if d.JSONType <> jtObject then Exit;
  arr := TJSONObject(d).Find(Kind);
  if (arr = nil) or (arr.JSONType = jtNull) or ((arr.JSONType = jtBoolean) and not arr.AsBoolean) then Exit;
  if arr.JSONType = jtObject then Exit;                    // PHP: an associative array is_array; its values would be walked with string keys: not copied
  if arr.JSONType <> jtArray then Exit;
  for i := 0 to arr.Count - 1 do
  begin
    it := TJSONArray(arr).Items[i];
    if it.JSONType = jtArray then
    begin
      if it.Count > 0 then Exit(False);                    // a non-empty list: .id is an error
      Item := TJSONObject.Create; Temp := True;            // [] behaves as an empty object
    end
    else if it.JSONType <> jtObject then Exit(False)
    else Item := TJSONObject(it);
    v := Item.Find('id');
    if (v <> nil) and (v.JSONType = jtString) and (v.AsString = Q) then Exit(True);
    v := Item.Find('title');
    if (v = nil) or (v.JSONType = jtNull) or ((v.JSONType = jtBoolean) and not v.AsBoolean) then t := ''
    else if v.JSONType = jtString then t := v.AsString
    else begin if Temp then FreeAndNil(Item); Exit(False); end;      // ascii_downcase on a non-string: error, stop
    t := LowerAscii(t);
    if (t = Q) or (Pos(Q, t) > 0) or (Q = '') then Exit(True);
    if Temp then begin FreeAndNil(Item); Temp := False; end;
  end;
  Item := nil;
end;

{ ---- the marker handlers ------------------------------------------------------------------------------------------------------------------------ }

procedure DoPropose(const Kind, Collected: string);
var
  kv: TStringList;
  i: Integer;
  line, title, lang, location, kindKv, notes, content, rest, payload, body: string;
  inContent: Boolean;
  r: TFetch;
  h: TStringList;
  res: THttpsResult;

  function Val(const l, key: string): string;
  begin
    Result := Copy(l, Length(key) + 1, MaxInt);
    if (Result <> '') and (Result[1] = ' ') then Result := Copy(Result, 2, MaxInt);
    if (Result <> '') and (Result[Length(Result)] = #13) then SetLength(Result, Length(Result) - 1);
  end;

begin
  title := ''; lang := ''; location := ''; kindKv := ''; notes := ''; content := ''; inContent := False;
  if Collected = '' then begin kv := TStringList.Create; kv.Add(''); end else kv := Explode(#10, Collected);
  try
    for i := 0 to kv.Count - 1 do
    begin
      line := kv[i];
      if inContent then begin if content = '' then content := line else content := content + #10 + line; Continue; end;
      if Copy(line, 1, 6) = 'title:' then title := Val(line, 'title:')
      else if Copy(line, 1, 5) = 'lang:' then lang := Val(line, 'lang:')
      else if Copy(line, 1, 9) = 'location:' then location := Val(line, 'location:')
      else if Copy(line, 1, 5) = 'kind:' then kindKv := Val(line, 'kind:')
      else if Copy(line, 1, 6) = 'notes:' then notes := Val(line, 'notes:')
      else if Copy(line, 1, 8) = 'content:' then
      begin
        inContent := True;
        rest := Copy(line, 9, MaxInt);
        if (rest <> '') and (rest[1] = ' ') then rest := Copy(rest, 2, MaxInt);
        if rest <> '' then content := rest;
      end;
    end;
  finally
    kv.Free;
  end;
  payload := '';
  if Kind = 'library' then
  begin
    payload := '{"title":"' + JsonEsc(title) + '","location":"' + JsonEsc(location) + '","kind":"';
    if JsonEsc(kindKv) <> '' then payload := payload + JsonEsc(kindKv) else payload := payload + 'path';
    payload := payload + '","notes":"' + JsonEsc(notes) + '"}';
  end
  else if (Kind = 'snippet') or (Kind = 'source') then
    payload := '{"title":"' + JsonEsc(title) + '","lang":"' + JsonEsc(lang) + '","notes":"' + JsonEsc(notes) + '","content":"' + JsonEsc(content) + '"}';
  body := '{"action":"proposal_add","propose_kind":"' + Kind + '","proposer":"' + GProposer + '","project":"' + GProjName + '","payload":' + payload + '}';
  // curl: only a failure to connect is a failure; any HTTP answer counts as sent
  h := TStringList.Create;
  try
    h.Add('Content-Type: application/json');
    if (GHdrKey <> '') and (GHdrUser <> '') then begin h.Add('X-Cockpit-Internal: ' + GHdrKey); h.Add('X-Cockpit-User: ' + GHdrUser); end;
    res := HttpsRequest('POST', GBase + '/library.php', body, h, 60, '', '');
  finally
    h.Free;
  end;
  if res.Ok then LineOut('[CRUD:OK] PROPOSE ' + Kind + ': "' + title + '" — pending approval')
  else LineOut('[CRUD:ERR] PROPOSE ' + Kind + ': failed to enqueue');
  r.Ok := res.Ok;
end;

procedure DoBlock(const Cmd, CmdPath, Collected: string);
var
  full: string;
  failed: Boolean;
  sz: Int64;
begin
  full := SafePath(CmdPath);
  if full = '' then begin LineOut('[CRUD:ERR] ' + Cmd + ' rejected — path outside project: ' + CmdPath); Exit; end;
  ForceDirectories(ExtractFileDir(full));
  if (Cmd = 'CREATE') or (Cmd = 'UPDATE') then
  begin
    WriteFileData(full, Collected + #10, False, failed);
    if failed then ErrOut('crud_cli: cannot write ' + full + #10);
    fpChmod(PChar(full), &664);
    sz := -1; if IsRegFile(full) then sz := FileSizeOf(full);
    if sz >= 0 then LineOut('[CRUD:OK] CREATE ' + CmdPath + ' (' + IntToStr(sz) + ' bytes)') else LineOut('[CRUD:OK] CREATE ' + CmdPath + ' (? bytes)');
  end
  else
  begin
    WriteFileData(full, Collected + #10, True, failed);
    if failed then ErrOut('crud_cli: cannot append to ' + full + #10);
    sz := -1; if IsRegFile(full) then sz := FileSizeOf(full);
    if sz >= 0 then LineOut('[CRUD:OK] APPEND ' + CmdPath + ' (' + IntToStr(sz) + ' bytes)') else LineOut('[CRUD:OK] APPEND ' + CmdPath + ' (? bytes)');
  end;
end;

type
  TCap = class
    Data: string;
    procedure OnChunk(const D: string; IsStderr: Boolean);
  end;

procedure TCap.OnChunk(const D: string; IsStderr: Boolean);
begin
  if IsStderr then ErrOut(D) else Data := Data + D;
end;

{ `ls -la DIR | tail -n +4` }
function LsOutput(const Dir: string): string;
var
  args: TStringList;
  cap: TCap;
  exe, d: string;
  nl, i, p: Integer;
begin
  Result := '';
  exe := FindInPath('ls', GetEnvironmentVariable('PATH'));
  if exe = '' then Refuse('no ls on this machine');
  args := TStringList.Create; cap := TCap.Create;
  try
    args.Add('-la'); args.Add(Dir);
    RunProcess(exe, args, '', nil, '', 0, 0, nil, nil, @cap.OnChunk, False);
    d := cap.Data;
  finally
    args.Free; cap.Free;
  end;
  nl := 0; p := 0;
  for i := 1 to Length(d) do
    if d[i] = #10 then begin Inc(nl); if nl = 3 then begin p := i; Break; end; end;
  if p > 0 then Result := Copy(d, p + 1, MaxInt);
end;

(* the FIRST quote followed only by an optional comma or closing brace and white space to the end (preg_replace with limit 1) *)
function CutQuoteTail(const S: string): string;
var
  i, j: Integer;
begin
  Result := S;
  for i := 1 to Length(S) do
    if S[i] = '"' then
    begin
      j := i + 1;
      if (j <= Length(S)) and (S[j] in [',', '}']) then Inc(j);
      while (j <= Length(S)) and IsVws(S[j]) do Inc(j);
      if j > Length(S) then Exit(Copy(S, 1, i - 1));
    end;
end;

procedure DoFetch(const Url: string);
var
  enc, res, rl, s: string;
  lines: TStringList;
  i: Integer;
begin
  enc := Url;
  if OnlyNeE(enc) then enc := '';
  enc := RTrimNl(StrRep(StrRep(StrRep(enc, '&', '%26'), '?', '%3F'), ' ', '%20'));
  res := RTrimNl(HttpGet(GBase + '/search.php?action=fetch&url=' + enc, 20));
  if res = '' then begin LineOut('[CRUD:ERR] FETCH "' + Url + '" — no response'); Exit; end;
  LineOut('[CRUD:INFO] FETCH ' + Url + ':');
  lines := Explode(#10, res);
  try
    for i := 0 to lines.Count - 1 do
    begin
      rl := lines[i];
      if Pos('"text"', rl) = 0 then Continue;
      s := AfterField(rl, 'text');
      s := StrRep(s, '\n', #10); s := StrRep(s, '\t', #9); s := StrRep(s, '\"', '"'); s := StrRep(s, '\\', '\');
      LineOut(CutQuoteTail(s));
    end;
  finally
    lines.Free;
  end;
  LineOut('');
end;

procedure DoSearch(const Q: string);
var
  enc, res, rec, title, url, snip: string;
  recs: TStringList;
  i, n: Integer;
begin
  enc := Q;
  if OnlyNeE(enc) then enc := '';
  enc := RTrimNl(StrRep(StrRep(StrRep(enc, ' ', '+'), '&', '%26'), '?', '%3F'));
  res := RTrimNl(HttpGet(GBase + '/search.php?action=search&n=5&q=' + enc, 12));
  if res = '' then begin LineOut('[CRUD:ERR] SEARCH "' + Q + '" — no response'); Exit; end;
  LineOut('[CRUD:INFO] SEARCH "' + Q + '":');
  title := ''; url := ''; n := 0;
  recs := Explode(',', res + #10);
  try
    for i := 0 to recs.Count - 1 do
    begin
      rec := recs[i];
      if Pos('"title"', rec) > 0 then begin title := FieldOf(rec, 'title'); Inc(n); end;
      if Pos('"url"', rec) > 0 then url := FieldOf(rec, 'url');
      if Pos('"snippet"', rec) > 0 then
      begin
        snip := FieldOf(rec, 'snippet');
        LineOut(IntToStr(n) + '. ' + title);
        LineOut('   ' + url);
        if Length(snip) > 0 then LineOut('   ' + snip);
        LineOut('');
      end;
    end;
  finally
    recs.Free;
  end;
end;

procedure DoWorker(const Prov, Task, Prompt: string);
var
  models, model, payload, res, kind, output, err, needle: string;
  d: TJSONData;
  p, q, i: Integer;
begin
  for i := 1 to Length(Prov) do
    if Prov[i] in ['\', '^', '$', '.', '[', ']', '|', '(', ')', '?', '*', '+', '{', '}'] then Refuse('a provider name that is a regular expression in the reference');
  models := RTrimNl(HttpGet(GBase + '/workers.php?action=models', 6));
  model := '';
  needle := '"provider":"' + Prov + '","model":"';
  p := 1;
  while True do
  begin
    p := PosFrom(needle, models, p);
    if p = 0 then Break;
    q := p + Length(needle);
    i := q;
    while (i <= Length(models)) and (models[i] <> '"') do Inc(i);
    if (i > q) and (i <= Length(models)) then begin model := Copy(models, q, i - q); Break; end;
    Inc(p);
  end;
  if model = '' then begin LineOut('[CRUD:ERR] WORKER ' + Prov + ' — no enabled model. Configure provider via WORKERS settings.'); Exit; end;
  payload := '{"provider":' + PhpJsonStr(Prov) + ',"model":' + PhpJsonStr(model) + ',"task":' + PhpJsonStr(Task) + ',"prompt":' + PhpJsonStr(Prompt) + ',"extra":{}}';
  res := RTrimNl(HttpCall(GBase + '/workers.php?action=invoke', 90, payload, True, False).Body);
  if res = '' then begin LineOut('[CRUD:ERR] WORKER ' + Prov + ' — no response'); Exit; end;
  d := DecodeObj(res);
  try
    if (d <> nil) and (JqAlt(d, 'ok', 'false') = 'true') then
    begin
      kind := JqAlt(d, 'kind', 'text');
      output := RTrimNl(JqAlt(d, 'output', ''));
      if not ValidUtf8(output) then Refuse('a worker answer that is not valid UTF-8');
      if Utf8Len(output) > 4096 then output := Utf8Head(output, 4096) + '... [truncated, ' + IntToStr(Utf8Len(output) - 4096) + ' more chars]';
      LineOut('[CRUD:INFO] WORKER ' + Prov + ' · ' + model + ' · ' + kind + ':');
      LineOut(output);
      LineOut('[CRUD:OK] %%WORKER_RESULT:' + Prov + ':' + kind + ':done%%');
    end
    else
    begin
      err := '';
      if d <> nil then err := JqAlt(d, 'error', 'unknown');
      LineOut('[CRUD:ERR] WORKER ' + Prov + ' — ' + err);
    end;
  finally
    d.Free;
  end;
end;

procedure DoTool(const Tool, Preset, Rest: string);
var
  p: Integer;
  input, extra, payload, res, output, size, ms, err, rc, log, sq: string;
  d: TJSONData;
  i: Integer;
  ch: Char;
  prevSp: Boolean;
begin
  p := Pos('|', Rest);
  if p > 0 then begin input := Copy(Rest, 1, p - 1); extra := Copy(Rest, p + 1, MaxInt); end else begin input := Rest; extra := ''; end;
  payload := '{"tool":' + PhpJsonStr(Tool) + ',"preset":' + PhpJsonStr(Preset) + ',"input":' + PhpJsonStr(input) + ',"extra_args":' + PhpJsonStr(extra) + ',"project":' + PhpJsonStr(GProjName) + '}';
  res := RTrimNl(HttpCall(GBase + '/tools.php?action=run', 320, payload, True, False).Body);
  if res = '' then begin LineOut('[CRUD:ERR] TOOL ' + Tool + ' — no response'); Exit; end;
  d := DecodeObj(res);
  if d = nil then
  begin
    // the page did not answer JSON (wrong address, not signed in): say so, with the start of what it answered (as crud_executor.sh does: tr -s ' \\n' | head -c 160)
    sq := ''; prevSp := False;
    for i := 1 to Length(res) + 1 do
    begin
      if i > Length(res) then ch := #10 else ch := res[i];
      if (ch = ' ') or (ch = #10) then begin if not prevSp then sq := sq + ' '; prevSp := True; end
      else begin sq := sq + ch; prevSp := False; end;
    end;
    LineOut('[CRUD:ERR] TOOL ' + Tool + ' — the tools page did not answer in the expected form (wrong address or not signed in): ' + Copy(sq, 1, 160));
    Exit;
  end;
  try
    if (JqAlt(d, 'ok', 'false') = 'true') then
    begin
      output := RTrimNl(JqAlt(d, 'output', ''));
      size := RTrimNl(JqAlt(d, 'output_size', '0'));
      ms := RTrimNl(JqAlt(d, 'elapsed_ms', '0'));
      LineOut('[CRUD:INFO] TOOL ' + Tool + ' · ' + Preset + ' done in ' + ms + 'ms (' + size + ' bytes):');
      LineOut('  Output: ' + output);
      LineOut('[CRUD:OK] %%TOOL_RESULT:' + Tool + ':' + output + '%%');
    end
    else
    begin
      err := ''; rc := '';
      if d <> nil then begin err := JqAlt(d, 'error', 'unknown'); rc := JqAlt(d, 'rc', '-1'); end;
      LineOut('[CRUD:ERR] TOOL ' + Tool + ' — ' + err + ' (rc=' + rc + ')');
      log := '';
      if d <> nil then log := Copy(RTrimNl(JqAlt(d, 'log', '')) + #10, 1, 400);
      log := RTrimNl(log);
      if log <> '' then LineOut('  Log: ' + log);
    end;
  finally
    d.Free;
  end;
end;

procedure DoLoadSkill(const IdIn: string);
var
  id, f, content, kept, sl: string;
  i: Integer;
  ok, fm: Boolean;
  all: TStringList;
  idx: Integer;

  function IsFence(const s: string): Boolean;      // ^---[ \t\r\n\f\v]*$
  var
    k: Integer;
  begin
    Result := Copy(s, 1, 3) = '---';
    if not Result then Exit;
    for k := 4 to Length(s) do if not IsVws(s[k]) then Exit(False);
  end;

begin
  id := '';
  for i := 1 to Length(IdIn) do if IdIn[i] in ['a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'] then id := id + IdIn[i];
  f := GData + '/skills/' + id + '/SKILL.md';
  if (id <> '') and IsRegFile(f) then
  begin
    LineOut('[CRUD:INFO] LOAD_SKILL ' + id + ':');
    content := ReadFile_(f, ok);
    kept := '';
    if content <> '' then
    begin
      all := Explode(#10, content);
      try
        if content[Length(content)] = #10 then all.Delete(all.Count - 1);
        fm := False;
        for idx := 0 to all.Count - 1 do
        begin
          sl := all[idx];
          if (idx = 0) and IsFence(sl) then begin fm := True; Continue; end;
          if fm and IsFence(sl) then begin fm := False; Continue; end;
          if not fm then kept := kept + sl + #10;
        end;
      finally
        all.Free;
      end;
    end;
    Out_(Copy(kept, 1, READ_MAX));
    LineOut('');
  end
  else
  begin
    if id <> '' then LineOut('[CRUD:ERR] LOAD_SKILL ' + id + ' — skill not found') else LineOut('[CRUD:ERR] LOAD_SKILL ? — skill not found');
  end;
end;

procedure DoRead(const Rel: string);
var
  full, data: string;
  ok: Boolean;
begin
  full := SafePath(Rel);
  if full = '' then LineOut('[CRUD:ERR] READ rejected — path outside project: ' + Rel)
  else if not IsRegFile(full) then LineOut('[CRUD:ERR] READ ' + Rel + ' — file not found')
  else
  begin
    LineOut('[CRUD:INFO] READ ' + Rel + ':');
    data := ReadFile_(full, ok);
    Out_(Copy(data, 1, READ_MAX));
    LineOut('');
    if Length(data) > READ_MAX then LineOut('[... truncated to first ' + IntToStr(READ_MAX) + ' bytes]');
  end;
end;

procedure DoCatalog(const Tag, Kind, Q: string);
var
  cq, idxText, mid, title, mfile, murl, mpath, data, body, txt, sq: string;
  hit: TJSONObject;
  owner: TJSONData;
  temp, ok, found: Boolean;
  idxs: array[0..2] of string;
  k, i, j: Integer;
  last: Char;
  d: string;
begin
  // trim(strtr($cq, A-Z, a-z), " \t\n\r\f\v")
  cq := LowerAscii(Q);
  i := 1; j := Length(cq);
  while (i <= j) and (cq[i] in [' ', #9, #10, #13, #12, #11]) do Inc(i);
  while (j >= i) and (cq[j] in [' ', #9, #10, #13, #12, #11]) do Dec(j);
  cq := Copy(cq, i, j - i + 1);
  idxs[0] := GDataUser + '/library_index.json'; idxs[1] := GData + '/library_index.json'; idxs[2] := GProject + '/library_index.json';
  found := False; hit := nil; owner := nil; temp := False;
  for k := 0 to 2 do
  begin
    if not IsRegFile(idxs[k]) then Continue;
    idxText := ReadFile_(idxs[k], ok);
    found := CatalogFind(idxText, Kind, cq, hit, owner, temp);
    if found then Break;
    owner.Free; owner := nil;
  end;
  try
    if not found then begin LineOut('[CRUD:ERR] ' + Tag + ' "' + Q + '" — no entry found'); LineOut(''); Exit; end;
    mid := JqAlt(hit, 'id', ''); title := JqAlt(hit, 'title', ''); mfile := JqAlt(hit, 'file_path', '');
    murl := JqAlt(hit, 'url', ''); mpath := JqAlt(hit, 'path', '');
    if (mfile = '') and (Kind = 'library') and (mid <> '') then
    begin
      if IsRegFile(GDataUser + '/library_text/' + mid + '.txt') then mfile := GDataUser + '/library_text/' + mid + '.txt'
      else if IsRegFile(GData + '/library_text/' + mid + '.txt') then mfile := GData + '/library_text/' + mid + '.txt';
    end;
    if (mfile = '') and (mpath <> '') and IsRegFile(mpath) then mfile := mpath;
    LineOut('[CRUD:INFO] ' + Tag + ' "' + title + '":');
    if (mfile <> '') and IsRegFile(mfile) then
    begin
      data := ReadFile_(mfile, ok);
      Out_(Copy(data, 1, 16384)); LineOut('');
      if Length(data) > 16384 then LineOut('[... truncated to first 16KB]');
    end
    else if murl <> '' then
    begin
      body := HttpCall(murl, 20, '', False, True, False).Body;
      // sed 's/<[^>]*>/ /g' as the reference does it (a tag may span lines)
      txt := ''; i := 1;
      while i <= Length(body) do
      begin
        if body[i] = '<' then
        begin
          j := PosFrom('>', body, i + 1);
          if j > 0 then begin txt := txt + ' '; i := j + 1; Continue; end;
        end;
        txt := txt + body[i]; Inc(i);
      end;
      // tr -s ' \n': squeeze runs of the SAME character
      sq := ''; last := #0;
      for i := 1 to Length(txt) do
      begin
        if (txt[i] in [' ', #10]) and (txt[i] = last) then Continue;
        sq := sq + txt[i]; last := txt[i];
      end;
      Out_(Copy(sq, 1, 8192)); LineOut('');
    end
    else LineOut('[CRUD:ERR] ' + Tag + ' "' + title + '" — nothing stored to read (no file, path or url)');
    LineOut('');
  finally
    if temp and (hit <> nil) then hit.Free;
    owner.Free;
  end;
  d := '';
end;

procedure DoDelete(const Rel: string; HasConfirm: Boolean);
var
  full: string;
  st: Stat;
begin
  if not HasConfirm then begin LineOut('[CRUD:ERR] DELETE ' + Rel + ' — missing %%CONFIRM:DELETE%% in response'); Exit; end;
  full := SafePath(Rel);
  if full = '' then LineOut('[CRUD:ERR] DELETE rejected — path outside project: ' + Rel)
  else if full = GProject then LineOut('[CRUD:ERR] DELETE rejected — that is the project directory itself: ' + Rel)
  else if fpLstat(PChar(full), st) <> 0 then LineOut('[CRUD:ERR] DELETE ' + Rel + ' — not found')
  else begin RmRf(full); LineOut('[CRUD:OK] DELETE ' + Rel); end;
end;

procedure DoMkdir(const Rel: string);
var
  full: string;
begin
  full := SafePath(Rel);
  if full = '' then begin LineOut('[CRUD:ERR] MKDIR rejected — path outside project: ' + Rel); Exit; end;
  ForceDirectories(full);
  fpChmod(PChar(full), &775);
  LineOut('[CRUD:OK] MKDIR ' + Rel);
end;

procedure DoList(const Rel: string);
var
  dir, lab: string;
begin
  if Rel = '' then begin dir := GProject; lab := '.'; end else begin dir := SafePath(Rel); lab := Rel; end;
  if (dir = '') or not IsDirPath(dir) then
  begin
    if Rel <> '' then LineOut('[CRUD:ERR] LIST ' + Rel + ' — directory not found') else LineOut('[CRUD:ERR] LIST . — directory not found');
  end
  else begin LineOut('[CRUD:INFO] LIST ' + lab + ':'); Out_(LsOutput(dir)); LineOut(''); end;
end;

{ %%(CREATE|UPDATE|APPEND):([^%]+)%%, the leftmost place in the line }
function MatchBlockStart(const Line: string; out Name, Path: string): Boolean;
const
  Names: array[0..2] of string = ('CREATE', 'UPDATE', 'APPEND');
var
  i, k, j, e: Integer;
  lname: string;
begin
  Result := False;
  for i := 1 to Length(Line) - 3 do
  begin
    if (Line[i] <> '%') or (Line[i + 1] <> '%') then Continue;
    for k := 0 to 2 do
    begin
      lname := '%%' + LowerAscii(Names[k]) + ':';
      if LowerAscii(Copy(Line, i, Length(lname))) = lname then
      begin
        j := i + Length(lname); e := j;
        while (e <= Length(Line)) and (Line[e] <> '%') do Inc(e);
        if (e > j) and (Copy(Line, e, 2) = '%%') then begin Name := Names[k]; Path := Copy(Line, j, e - j); Exit(True); end;
      end;
    end;
  end;
end;

function MatchProposeStart(const Line: string; out Kind: string): Boolean;
const
  Kinds: array[0..2] of string = ('snippet', 'source', 'library');
var
  i, k: Integer;
  w: string;
begin
  Result := False;
  for i := 1 to Length(Line) do
  begin
    if LowerAscii(Copy(Line, i, 10)) <> '%%propose:' then Continue;
    for k := 0 to 2 do
    begin
      w := Kinds[k] + '%%';
      if LowerAscii(Copy(Line, i + 10, Length(w))) = w then begin Kind := Kinds[k]; Exit(True); end;
    end;
  end;
end;

{ AllS = standard output and standard error as one stream in the order they were produced (what the loop shows the agent) }
function CrudRun(const ProjectDir, ResponseFile, Proposer, ProjectName: string; out OutS, ErrS, AllS: string): Integer;
var
  raw: string;
  ok, hasConfirm: Boolean;
  lines: TStringList;
  i, mode: Integer;
  line, cmd, cmdPath, collected, kind, cap, a, b, c, rest: string;
  names: string;
begin
  GOut := ''; GErr := ''; GAll := ''; Result := 0;
  try
    if (ProjectDir = '') or not IsDirPath(ProjectDir) then Exit;
    if (ResponseFile = '') or not IsRegFile(ResponseFile) then Exit;
    raw := ReadFile_(ResponseFile, ok);
    if Pos('%%', raw) = 0 then Exit;
    GProject := RealPathM(ProjectDir);
    c := ''; SetLength(c, 4096); FillChar(c[1], 4096, 0);
    if c_realpath(PChar(ProjectDir), PChar(c)) <> nil then GProject := StrPas(PChar(c));
    GHome := GetEnvironmentVariable('HOME');
    GData := GHome + '/scripts/cockpit_data';
    ForceDirectories(GData);
    GDataUser := GetEnvironmentVariable('COCKPIT_DATA_USER');
    GBase := GetEnvironmentVariable('COCKPIT_BASE_URL');
    if GBase = '' then GBase := 'http://localhost/cockpit';
    while (GBase <> '') and (GBase[Length(GBase)] = '/') do SetLength(GBase, Length(GBase) - 1);
    GHdrKey := GetEnvironmentVariable('COCKPIT_INTERNAL_KEY'); GHdrUser := GetEnvironmentVariable('COCKPIT_INTERNAL_USER');
    GProposer := Proposer; if GProposer = '' then GProposer := 'unknown';
    GProjName := ProjectName; if GProjName = '' then GProjName := 'default';

    lines := BashLines(raw);
    try
      hasConfirm := Pos('%%CONFIRM:DELETE%%', raw) > 0;
      // ---- pass 1: the multi-line blocks
      mode := 0; cmd := ''; cmdPath := ''; collected := ''; kind := '';
      for i := 0 to lines.Count - 1 do
      begin
        line := lines[i];
        if mode = 0 then
        begin
          if MatchBlockStart(line, a, b) then begin cmd := a; cmdPath := b; collected := ''; mode := 1; Continue; end;
          if MatchProposeStart(line, a) then begin cmd := 'PROPOSE'; kind := a; collected := ''; mode := 1; Continue; end;
          Continue;
        end;
        if Pos('%%END%%', line) = 0 then
        begin
          if collected = '' then collected := line else collected := collected + #10 + line;
          Continue;
        end;
        if cmd = 'PROPOSE' then DoPropose(kind, collected) else DoBlock(cmd, cmdPath, collected);
        mode := 0; cmd := ''; cmdPath := ''; collected := ''; kind := '';
      end;
      // ---- pass 2: every line again (a marker inside a block's content runs too: the reference's quirk)
      for i := 0 to lines.Count - 1 do
      begin
        line := lines[i];
        if MatchOne(line, 'FETCH', True, cap) then begin DoFetch(cap); Continue; end;
        if MatchOne(line, 'LOAD_SKILL', True, cap) then begin DoLoadSkill(cap); Continue; end;
        if MatchOne(line, 'READ', True, cap) then begin DoRead(cap); Continue; end;
        if MatchOne(line, 'SEARCH', True, cap) then begin DoSearch(cap); Continue; end;
        if MatchThree(line, 'WORKER', a, b, c) then begin DoWorker(a, b, c); Continue; end;
        if MatchThree(line, 'TOOL', a, b, c) then begin DoTool(a, b, c); Continue; end;
        if MatchOne(line, 'LIB', True, cap) then begin DoCatalog('LIB', 'library', cap); Continue; end
        else if MatchOne(line, 'SNIP', True, cap) then begin DoCatalog('SNIP', 'snippets', cap); Continue; end
        else if MatchOne(line, 'SRC', True, cap) then begin DoCatalog('SRC', 'sources', cap); Continue; end;
        if MatchOne(line, 'DELETE', True, cap) then begin DoDelete(cap, hasConfirm); Continue; end;
        if MatchOne(line, 'MKDIR', True, cap) then begin DoMkdir(cap); Continue; end;
        if MatchOne(line, 'LIST', False, cap) then begin DoList(cap); Continue; end;
        if Pos('%%list%%', LowerAscii(line)) > 0 then
        begin LineOut('[CRUD:INFO] LIST .:'); Out_(LsOutput(GProject)); LineOut(''); Continue; end;
      end;
    finally
      lines.Free;
    end;
  except
    on E: ECrudRefuse do begin GOut := ''; GAll := ''; GErr := E.Message + #10; Result := CRUD_REFUSED; end;
  end;
  OutS := GOut; ErrS := GErr; AllS := GAll;
  names := rest;
end;

end.
