(* =============================================================================
  aic_history — the chat-history half of the agent loop, native:   aicengine history needs|build|sync|add|append ...

  The same interface and the same results as scripts/history_cli.php (which is the byte-exact reference of the Bash it replaced; every quirk is kept):
    needs   --agent UC                       prompt on stdin; exit 0 = include earlier turns, 1 = skip           (the gate)
    build   --chat F --format text|json --mode inline|pointer --agent UC      prompt on stdin     (which turns, rendered)
    sync    --chat F --agent UC              reconcile the derived index with the chat JSON
    add     --chat F --id N --role R --agent A --ts T --text-file F
    append  --chat F --project P --chat-name N --user-file F --agent-file F --model M --duration D --style S --mode M --agent A --supplier S --agent-uc UC
  Exit codes as the PHP helper's (0/1 answered, 2 bad usage, 3 = append wrote nothing). NEW: exit 9 = REFUSED before touching anything, for the few inputs
  this program does not copy exactly (text that is not valid UTF-8; a character FPC's Unicode tables do not know; an agent name that does not start with an
  ASCII letter; a chat file that is not strict JSON, which only old loops wrote; unusual field types): the caller then uses the PHP helper.
  The relevance index is the same SQLite FTS5 file the PHP side uses (porter unicode61, bm25), reached through the system's SQLite library loaded at run
  time; without it (no library, no FTS5, HISTORY_CLI_NO_INDEX) the whole-tail fallbacks answer, exactly as in the Bash.
  tests/history_native_parity.sh runs this and history_cli.php on the same inputs and compares output, log lines, exit codes, chat files and index rows.
  ============================================================================= *)
unit aic_history;

{$mode objfpc}{$H+}

interface

const
  HISTORY_REFUSED = 9;

function HistoryRun(const Cmd: string; const Args: array of string; const StdinData: string; out OutS, ErrS: string): Integer;

implementation

uses
  SysUtils, Classes, BaseUnix, Unix, sqlite3dyn, unicodedata, fpjson, jsonparser, jsonscanner;

{$I aic_historytexts.inc}

const
  HISTORY_RELEVANT = 4;
  CONT: array[0..12] of string = ('and', 'but', 'so', 'then', 'ok', 'okay', 'yes', 'no', 'also', 'now', 'what about', 'how about', 'instead');

type
  EHistRefuse = class(Exception);
  TRow = record
    Id: Int64;
    Role, Agent, Ts, Body: string;
  end;
  TRows = array of TRow;

var
  GOut, GErr: string;
  GArgs: array of string;
  GMax: Integer;
  GIndexReady: Integer = -1;       // -1 unknown, 0 no, 1 yes

procedure Refuse(const Why: string);
begin
  raise EHistRefuse.Create(Why);
end;

procedure Out_(const S: string);
begin
  GOut := GOut + S;
end;

procedure Err_(const S: string);
begin
  GErr := GErr + S;
end;

function Opt(const Name: string; const Def: string = ''): string;
var
  i: Integer;
begin
  for i := 0 to High(GArgs) - 1 do if GArgs[i] = Name then Exit(GArgs[i + 1]);
  Result := Def;
end;

function ReadFile_(const F: string; out Ok: Boolean): string;
var
  fs: TFileStream;
begin
  Result := ''; Ok := False;
  if not FileExists(F) then Exit;
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

function ReadFileS(const F: string): string;
var
  ok: Boolean;
begin
  Result := ReadFile_(F, ok);
end;

{ ---- strings, PHP style ------------------------------------------------------------------------------------------------------------ }

function Explode(const Sep, S: string): TStringList;       // PHP explode: "a\n" gives ["a", ""]
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

function IsWs(c: Char): Boolean;            // PCRE \s: space, \t \n \v \f \r
begin
  Result := c in [' ', #9, #10, #11, #12, #13];
end;

function IsVws(c: Char): Boolean;           // a class written [ \t\n\v\f\r]: PCRE's \v also takes the byte 0x85 (NEL)
begin
  Result := c in [' ', #9, #10, #11, #12, #13, #133];
end;

function ValidUtf8(const S: string): Boolean;
var
  i, n: Integer;
  c, c0: Byte;
  cp: Cardinal;
  need: Integer;
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

{ code points of a valid UTF-8 string }
procedure Decode(const S: string; Cps: TList);
var
  i, n, need: Integer;
  c: Byte;
  cp: Cardinal;
begin
  i := 1; n := Length(S);
  while i <= n do
  begin
    c := Ord(S[i]);
    if c < $80 then begin Cps.Add(Pointer(PtrUInt(c))); Inc(i); Continue; end;
    if c >= $F0 then begin need := 3; cp := c and $07; end
    else if c >= $E0 then begin need := 2; cp := c and $0F; end
    else begin need := 1; cp := c and $1F; end;
    while need > 0 do begin Inc(i); cp := (cp shl 6) or (Ord(S[i]) and $3F); Dec(need); end;
    Cps.Add(Pointer(PtrUInt(cp)));
    Inc(i);
  end;
end;

function Utf8Len(const S: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to Length(S) do if (Ord(S[i]) and $C0) <> $80 then Inc(Result);
end;

function Utf8Head(const S: string; N: Integer): string;      // mb_substr($s, 0, N)
var
  i, cnt: Integer;
begin
  cnt := 0;
  for i := 1 to Length(S) do
  begin
    if (Ord(S[i]) and $C0) <> $80 then
    begin
      if cnt = N then Exit(Copy(S, 1, i - 1));
      Inc(cnt);
    end;
  end;
  Result := S;
end;

function Cap(const S: string): string;
begin
  if Utf8Len(S) > 1500 then Result := Utf8Head(S, 1500) + '... [truncated]' else Result := S;
end;

function UcFirst(const S: string): string;
begin
  if S = '' then Exit('');
  if Ord(S[1]) >= $80 then Refuse('an agent name that does not start with an ASCII letter');
  Result := S;
  if S[1] in ['a'..'z'] then Result[1] := Chr(Ord(S[1]) - 32);
end;

function LowerAscii(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do if Result[i] in ['A'..'Z'] then Result[i] := Chr(Ord(Result[i]) + 32);
end;

function IsWordCh(c: Char): Boolean;
begin
  Result := c in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

{ ---- the prompt's own words ---------------------------------------------------------------------------------------------------------- }

{ sed '1{/^\[[A-Z][A-Z ]* MODE\] /d}' then s/\(Now: ....-..-..[^)]*\)//g, both line by line }
function UserText(const P: string): string;
var
  lines: TStringList;
  i, j, k, q: Integer;
  l, o: string;

  function ModeLine(const s: string): Boolean;
  var
    t: Integer;
  begin
    Result := False;
    if (Length(s) < 3) or (s[1] <> '[') or not (s[2] in ['A'..'Z']) then Exit;
    t := 3;
    while (t <= Length(s)) and (s[t] in ['A'..'Z', ' ']) do Inc(t);
    if (t > Length(s)) or (s[t] <> ']') then Exit;
    if (t - 5 < 3) or (Copy(s, t - 5, 5) <> ' MODE') then Exit;
    Result := (t < Length(s)) and (s[t + 1] = ' ');
  end;

begin
  lines := Explode(#10, P);
  try
    if (lines.Count > 0) and ModeLine(lines[0]) then lines.Delete(0);
    Result := '';
    for i := 0 to lines.Count - 1 do
    begin
      l := lines[i]; o := ''; j := 1;
      while j <= Length(l) do
      begin
        if (Copy(l, j, 6) = '(Now: ') and (j + 16 <= Length(l)) then
        begin
          k := j + 6;
          if (l[k] in ['0'..'9']) and (l[k+1] in ['0'..'9']) and (l[k+2] in ['0'..'9']) and (l[k+3] in ['0'..'9']) and (l[k+4] = '-') and
             (l[k+5] in ['0'..'9']) and (l[k+6] in ['0'..'9']) and (l[k+7] = '-') and (l[k+8] in ['0'..'9']) and (l[k+9] in ['0'..'9']) then
          begin
            q := k + 10;
            while (q <= Length(l)) and (l[q] <> ')') do Inc(q);
            if q <= Length(l) then begin j := q + 1; Continue; end;
          end;
        end;
        o := o + l[j]; Inc(j);
      end;
      if i > 0 then Result := Result + #10;
      Result := Result + o;
    end;
  finally
    lines.Free;
  end;
end;

{ GNU wc -w in a UTF-8 locale, as the PHP helper reproduces it }
function WcWords(const S: string): Integer;
var
  cps: TList;
  i: Integer;
  cp: Cardinal;
  inWord: Boolean;
  props: PUC_Prop;

  function IsSpace(c: Cardinal): Boolean;
  begin
    Result := (c = 32) or (c in [9, 10, 11, 12, 13]) or (c = $A0) or (c = $1680) or ((c >= $2000) and (c <= $200A)) or (c = $202F) or (c = $205F) or (c = $3000) or (c = $2060);
  end;

begin
  if not ValidUtf8(S) then Refuse('not valid UTF-8');
  cps := TList.Create;
  try
    Decode(S, cps);
    Result := 0; inWord := False;
    for i := 0 to cps.Count - 1 do
    begin
      cp := Cardinal(PtrUInt(cps[i]));
      if cp >= $80 then
      begin
        props := GetProps(cp);
        if props^.Category = UGC_Unassigned then Refuse('a character FPC does not know');
        if (props^.Category = UGC_Control) or (props^.Category = UGC_LineSeparator) or (props^.Category = UGC_ParagraphSeparator) or (cp = $180E) then Continue;   // removed: neither starts nor ends a word
      end
      else if (cp < 32) and not (cp in [9, 10, 11, 12, 13]) then Continue
      else if cp = 127 then Continue;
      if IsSpace(cp) then inWord := False
      else if not inWord then begin inWord := True; Inc(Result); end;
    end;
  finally
    cps.Free;
  end;
end;

{ ---- the gate ------------------------------------------------------------------------------------------------------------------------ }

function Needs(const Prompt, UC: string): Integer;
var
  p, lower, mode: string;
  words, i, a, k, st: Integer;
  lines: TStringList;
  l: string;

  function StartsAt(const s: string; pos: Integer; const w: string): Boolean;
  begin
    Result := Copy(s, pos, Length(w)) = w;
  end;

begin
  p := RTrimNl(UserText(Prompt));
  mode := GetEnvironmentVariable('COCKPIT_HISTORY');
  if mode = '' then mode := 'auto';
  if mode = 'always' then begin Out_('[' + UC + '] history: included (COCKPIT_HISTORY=always)' + #10); Exit(0); end;
  if mode = 'never' then begin Out_('[' + UC + '] history: skipped (COCKPIT_HISTORY=never)' + #10); Exit(1); end;
  lower := LowerAscii(p);
  words := WcWords(p);
  if words < 8 then begin Out_('[' + UC + '] history: included (short prompt, ' + IntToStr(words) + ' words)' + #10); Exit(0); end;
  lines := Explode(#10, lower);
  try
    // continuation opener, at the start of ANY line (grep works per line)
    for i := 0 to lines.Count - 1 do
    begin
      l := lines[i]; st := 1;
      while (st <= Length(l)) and (l[st] in [' ', #9, #13, #12, #11, #133]) do Inc(st);
      for a := 0 to High(CONT) do
        if StartsAt(l, st, CONT[a]) and ((st + Length(CONT[a]) > Length(l)) or not IsWordCh(l[st + Length(CONT[a])])) then
        begin Out_('[' + UC + '] history: included (continuation opener)' + #10); Exit(0); end;
    end;
    // back-references: a phrase between non-word characters, anywhere in any line
    for i := 0 to lines.Count - 1 do
    begin
      l := lines[i];
      for st := 1 to Length(l) do
      begin
        if (st > 1) and IsWordCh(l[st - 1]) then Continue;
        for k := 0 to HIST_BACK_COUNT - 1 do
          if StartsAt(l, st, HIST_BACK[k]) and ((st + Length(HIST_BACK[k]) > Length(l)) or not IsWordCh(l[st + Length(HIST_BACK[k])])) then
          begin Out_('[' + UC + '] history: included (back-reference)' + #10); Exit(0); end;
      end;
    end;
  finally
    lines.Free;
  end;
  Out_('[' + UC + '] history: skipped (self-contained prompt, ' + IntToStr(words) + ' words)' + #10);
  Result := 1;
end;

{ the FTS query: up to 12 distinct keyword terms, quoted, joined by OR }
function Terms(const Prompt: string): string;
var
  t, w: string;
  i: Integer;
  seen, stop: TStringList;
  parts: TStringList;
  keep: Integer;
  ok: Boolean;
begin
  t := LowerAscii(UserText(Prompt));
  for i := 1 to Length(t) do if not (t[i] in ['a'..'z', '0'..'9', #10]) then t[i] := ' ' else if t[i] = #10 then t[i] := ' ';
  stop := TStringList.Create; seen := TStringList.Create; parts := TStringList.Create;
  try
    stop.Delimiter := '|'; stop.StrictDelimiter := True; stop.DelimitedText := HIST_STOPWORDS;
    stop.Sorted := True; seen.Sorted := True;
    w := ''; keep := 0; Result := '';
    for i := 1 to Length(t) + 1 do
    begin
      if (i <= Length(t)) and (t[i] <> ' ') then begin w := w + t[i]; Continue; end;
      if w <> '' then
      begin
        ok := (Length(w) >= 4) and (w[1] in ['a'..'z']);
        if ok and (stop.IndexOf(w) < 0) and (seen.IndexOf(w) < 0) then
        begin
          seen.Add(w);
          if Result <> '' then Result := Result + ' OR ';
          Result := Result + '"' + w + '"';
          Inc(keep);
          if keep >= 12 then Break;
        end;
        w := '';
      end;
    end;
  finally
    stop.Free; seen.Free; parts.Free;
  end;
end;

{ ---- the index (SQLite FTS5, loaded at run time) ----------------------------------------------------------------------------------------- }

var
  GLoaded: Boolean = False;

function SqliteReady: Boolean;
var
  db: psqlite3;
  st: psqlite3_stmt;
  names: array[0..2] of string = ('libsqlite3.so.0', 'libsqlite3.so', 'libsqlite3.dylib');
  i: Integer;
  rc: Integer;
begin
  if GIndexReady >= 0 then Exit(GIndexReady = 1);
  GIndexReady := 0;
  if (GetEnvironmentVariable('HISTORY_CLI_NO_INDEX') <> '') and (GetEnvironmentVariable('HISTORY_CLI_NO_INDEX') <> '0') then Exit(False);
  if not GLoaded then
  begin
    for i := 0 to 2 do
      try
        InitialiseSQLite(names[i]);
        if Assigned(sqlite3_open) then begin GLoaded := True; Break; end;
      except
        on E: Exception do ;
      end;
  end;
  if not GLoaded then Exit(False);
  db := nil;
  if sqlite3_open(PChar(':memory:'), @db) <> 0 then Exit(False);
  st := nil;
  rc := sqlite3_prepare_v2(db, PChar('CREATE VIRTUAL TABLE t USING fts5(x)'), -1, @st, nil);
  if rc = 0 then begin rc := sqlite3_step(st); sqlite3_finalize(st); end;
  sqlite3_close(db);
  if (rc = 101) or (rc = 0) then GIndexReady := 1;
  Result := GIndexReady = 1;
end;

function DbPath(const Chat: string): string;
begin
  Result := ExtractFileDir(ExtractFileDir(Chat)) + '/.chat_index.db';
end;

procedure ShareFiles(const Db: string);
var
  st, dst: Stat;
  p: string;
  i: Integer;
begin
  if fpStat(PChar(ExtractFileDir(Db)), dst) <> 0 then Exit;
  for i := 0 to 2 do
  begin
    case i of 0: p := Db; 1: p := Db + '-wal'; else p := Db + '-shm'; end;
    if fpStat(PChar(p), st) <> 0 then Continue;
    fpChmod(PChar(p), &664);
    if st.st_gid <> dst.st_gid then fpChown(PChar(p), TUid(-1), dst.st_gid);
  end;
end;

function Exec(Db: psqlite3; const Sql: string): Integer;
begin
  Result := sqlite3_exec(Db, PChar(Sql), nil, nil, nil);
end;

function OpenDb(const Chat: string): psqlite3;
var
  db: psqlite3;
  p: string;
begin
  Result := nil;
  if not SqliteReady then Exit;
  p := DbPath(Chat);
  db := nil;
  if sqlite3_open(PChar(p), @db) <> 0 then begin if db <> nil then sqlite3_close(db); Exit; end;
  sqlite3_busy_timeout(db, 3000);
  Exec(db, 'PRAGMA journal_mode=WAL');
  if Exec(db, 'CREATE VIRTUAL TABLE IF NOT EXISTS ex USING fts5(chat UNINDEXED, id UNINDEXED, role UNINDEXED, agent UNINDEXED, ts UNINDEXED, body, tokenize="porter unicode61")') <> 0 then
  begin sqlite3_close(db); Exit; end;
  ShareFiles(p);
  Result := db;
end;

function Prep(Db: psqlite3; const Sql: string): psqlite3_stmt;
begin
  Result := nil;
  if sqlite3_prepare_v2(Db, PChar(Sql), -1, @Result, nil) <> 0 then Result := nil;
end;

procedure BindText(St: psqlite3_stmt; I: Integer; const S: string);
begin
  sqlite3_bind_text(St, I, PChar(S), Length(S), sqlite3_destructor_type(Pointer(PtrInt(-1))));
end;

function ColText(St: psqlite3_stmt; I: Integer): string;
var
  p: PChar;
  n: Integer;
begin
  p := PChar(sqlite3_column_text(St, I));
  n := sqlite3_column_bytes(St, I);
  if (p = nil) or (n = 0) then Exit('');
  SetLength(Result, n); Move(p^, Result[1], n);
end;

function CountRows(Db: psqlite3; const Chat: string): Integer;
var
  st: psqlite3_stmt;
begin
  Result := 0;
  st := Prep(Db, 'SELECT count(*) FROM ex WHERE chat = ?1');
  if st = nil then Exit;
  BindText(st, 1, Chat);
  if sqlite3_step(st) = 100 then Result := sqlite3_column_int(st, 0);
  sqlite3_finalize(st);
end;

{ ---- chat_rows: every exchange of a chat as an index row ----------------------------------------------------------------------------------- }

function JStr(D: TJSONData; const Key: string; Missing: Boolean = True): string;      // a string field, '' when absent or null; anything else is refused
var
  v: TJSONData;
begin
  Result := '';
  if D.JSONType <> jtObject then Refuse('an exchange that is not an object');
  v := TJSONObject(D).Find(Key);
  if (v = nil) or (v.JSONType = jtNull) then Exit;
  if v.JSONType <> jtString then Refuse('a field that is not a string: ' + Key);
  Result := v.AsString;
end;

function ChatRows(const Chat: string): TRows;
var
  raw: string;
  ok: Boolean;
  d, ex, e, v: TJSONData;
  parser: TJSONParser;
  i, n: Integer;
  r: TRow;
  idv: string;
begin
  SetLength(Result, 0);
  raw := '';
  if FileExists(Chat) then raw := ReadFile_(Chat, ok);
  if raw = '' then Exit;
  if not ValidUtf8(raw) then Refuse('chat file is not valid UTF-8');
  if Pos(#0, raw) > 0 then Refuse('NUL in the chat file');
  d := nil;
  try
    parser := TJSONParser.Create(raw, [joUTF8, joStrict]);
    try
      d := parser.Parse;
    finally
      parser.Free;
    end;
  except
    d := nil;
  end;
  if d = nil then Refuse('the chat file is not strict JSON (the lenient reader is the PHP helper)');
  try
    if d.JSONType <> jtObject then
    begin
      if d.JSONType = jtArray then Exit;                   // valid JSON without an "exchanges" list: nothing
      Refuse('unexpected JSON');
    end;
    ex := TJSONObject(d).Find('exchanges');
    if (ex = nil) or (ex.JSONType = jtNull) then Exit;
    if ex.JSONType <> jtArray then Refuse('exchanges is not a list');
    n := 0;
    for i := 0 to ex.Count - 1 do
    begin
      e := TJSONArray(ex).Items[i];
      if e.JSONType = jtArray then Refuse('an exchange that is a list');
      if e.JSONType <> jtObject then Continue;             // PHP skips what is not an array
      r.Role := JStr(e, 'role'); r.Agent := JStr(e, 'agent');
      v := TJSONObject(e).Find('id');
      if (v = nil) or (v.JSONType = jtNull) then idv := IntToStr(i + 1)
      else if (v.JSONType = jtNumber) and (TJSONNumber(v).NumberType in [ntInteger, ntInt64]) then idv := IntToStr(v.AsInt64)
      else if (v.JSONType = jtString) and (v.AsString <> '') and (Length(v.AsString) < 18) and (Pos('-', v.AsString) = 0) and (StrToInt64Def(v.AsString, -1) >= 0) and (IntToStr(StrToInt64Def(v.AsString, -1)) = v.AsString) then idv := v.AsString
      else Refuse('an id of an unusual kind');
      r.Id := StrToInt64(idv);
      r.Ts := JStr(e, 'timestamp');
      if (r.Ts = '') or (r.Ts = '0') then r.Ts := JStr(e, 'ts');
      r.Body := JStr(e, 'text');
      if Pos(#0, r.Body) > 0 then Refuse('NUL in a text');
      r.Body := StrRep(StrRep(StrRep(r.Body, #31, ' '), #9, ' '), #10, '\n');
      SetLength(Result, n + 1); Result[n] := r; Inc(n);
    end;
  finally
    d.Free;
  end;
end;

{ sync: reconcile the index with the chat JSON; returns the log line ('' when nothing was rebuilt) }
function Sync(const Chat, UC: string): string;
var
  db: psqlite3;
  rows: TRows;
  nj, nd, nw, i: Integer;
  st: psqlite3_stmt;
begin
  Result := '';
  if not SqliteReady then Exit;
  rows := ChatRows(Chat);                       // may refuse: before any change
  db := OpenDb(Chat);
  if db = nil then Exit;
  try
    nj := Length(rows);
    nd := CountRows(db, Chat);
    if nj = nd then Exit;
    Exec(db, 'BEGIN');
    st := Prep(db, 'DELETE FROM ex WHERE chat = ?1'); BindText(st, 1, Chat); sqlite3_step(st); sqlite3_finalize(st);
    st := Prep(db, 'INSERT INTO ex(chat,id,role,agent,ts,body) VALUES(?1,?2,?3,?4,?5,?6)');
    for i := 0 to nj - 1 do
    begin
      sqlite3_reset(st);
      BindText(st, 1, Chat); sqlite3_bind_int64(st, 2, rows[i].Id); BindText(st, 3, rows[i].Role); BindText(st, 4, rows[i].Agent);
      BindText(st, 5, rows[i].Ts); BindText(st, 6, rows[i].Body);
      sqlite3_step(st);
    end;
    sqlite3_finalize(st);
    Exec(db, 'COMMIT');
    nw := CountRows(db, Chat);
    Result := '[' + UC + '] chat index: rebuilt ' + ExtractFileName(Chat) + ' (' + IntToStr(nd) + ' -> ' + IntToStr(nw) + ' rows, json has ' + IntToStr(nj) + ')' + #10;
  finally
    sqlite3_close(db);
  end;
end;

{ add: the fast path after an append (the Bash's quirks: tabs to space, one final newline dropped, then newlines to \n; NOT replacing the unit separator) }
procedure AddRow(const Chat: string; Id: Int64; const Role, Agent, Ts, Text: string);
var
  db: psqlite3;
  st: psqlite3_stmt;
  body: string;
begin
  if Copy(ExtractFileName(Chat), 1, 6) = 'chat__' then Exit;
  db := OpenDb(Chat);
  if db = nil then Exit;
  try
    body := StrRep(Text, #9, ' ');
    if (body <> '') and (body[Length(body)] = #10) then SetLength(body, Length(body) - 1);
    body := StrRep(body, #10, '\n');
    st := Prep(db, 'INSERT INTO ex(chat,id,role,agent,ts,body) VALUES(?1,?2,?3,?4,?5,?6)');
    if st = nil then Exit;
    BindText(st, 1, Chat); sqlite3_bind_int64(st, 2, Id); BindText(st, 3, Role); BindText(st, 4, Agent); BindText(st, 5, Ts); BindText(st, 6, body);
    sqlite3_step(st); sqlite3_finalize(st);
  finally
    sqlite3_close(db);
  end;
end;

{ ---- which exchanges ------------------------------------------------------------------------------------------------------------------ }

type
  TIdArr = array of Int64;

procedure SortIds(var A: TIdArr);
var
  i, j: Integer;
  t: Int64;
begin
  for i := 1 to High(A) do
  begin
    t := A[i]; j := i - 1;
    while (j >= 0) and (A[j] > t) do begin A[j + 1] := A[j]; Dec(j); end;
    A[j + 1] := t;
  end;
end;

function SelectIds(const Chat, Prompt: string; MaxHistory: Integer): TIdArr;
var
  db: psqlite3;
  st: psqlite3_stmt;
  q: string;
  top, last, pairs, ids: TIdArr;
  i, k, n: Integer;
  id: Int64;
  seen: Boolean;
begin
  SetLength(Result, 0);
  db := OpenDb(Chat);
  if db = nil then Exit;
  SetLength(top, 0); SetLength(last, 0);
  try
    q := Terms(Prompt);
    if q <> '' then
    begin
      st := Prep(db, 'SELECT id FROM ex WHERE chat = ?1 AND ex MATCH ?2 ORDER BY bm25(ex) LIMIT ' + IntToStr(HISTORY_RELEVANT * 2));
      if st <> nil then
      begin
        BindText(st, 1, Chat); BindText(st, 2, q);
        while sqlite3_step(st) = 100 do begin SetLength(top, Length(top) + 1); top[High(top)] := sqlite3_column_int64(st, 0); end;
        sqlite3_finalize(st);
      end;
    end;
    st := Prep(db, 'SELECT id FROM ex WHERE chat = ?1 ORDER BY id DESC LIMIT 4');
    if st <> nil then
    begin
      BindText(st, 1, Chat);
      while sqlite3_step(st) = 100 do begin SetLength(last, Length(last) + 1); last[High(last)] := sqlite3_column_int64(st, 0); end;
      sqlite3_finalize(st);
    end;
  finally
    sqlite3_close(db);
  end;
  // every id becomes its pair (a user row, odd id, owns the next row; an agent row, even, the one before); head -n 8
  SetLength(pairs, 0);
  for i := 0 to High(top) do
  begin
    SetLength(pairs, Length(pairs) + 2);
    if top[i] mod 2 = 1 then begin pairs[High(pairs) - 1] := top[i]; pairs[High(pairs)] := top[i] + 1; end
    else begin pairs[High(pairs) - 1] := top[i] - 1; pairs[High(pairs)] := top[i]; end;
  end;
  if Length(pairs) > HISTORY_RELEVANT * 2 then SetLength(pairs, HISTORY_RELEVANT * 2);
  SetLength(ids, 0);
  for k := 0 to 1 do
    for i := 0 to (Length(pairs) - 1) * Ord(k = 0) + (Length(last) - 1) * Ord(k = 1) do
    begin
      if k = 0 then id := pairs[i] else id := last[i];
      seen := False; for n := 0 to High(ids) do if ids[n] = id then seen := True;
      if not seen then begin SetLength(ids, Length(ids) + 1); ids[High(ids)] := id; end;
    end;
  SortIds(ids);
  n := MaxHistory * 2;
  if Length(ids) > n then
  begin
    for i := 0 to n - 1 do ids[i] := ids[Length(ids) - n + i];
    SetLength(ids, n);
  end;
  Result := ids;
end;

function RowsFor(const Chat: string; const Ids: TIdArr): TRows;
var
  db: psqlite3;
  st: psqlite3_stmt;
  inl: string;
  i, n: Integer;
begin
  SetLength(Result, 0);
  if Length(Ids) = 0 then Exit;
  db := OpenDb(Chat);
  if db = nil then Exit;
  try
    inl := '';
    for i := 0 to High(Ids) do begin if i > 0 then inl := inl + ','; inl := inl + IntToStr(Ids[i]); end;
    st := Prep(db, 'SELECT id, role, agent, body FROM ex WHERE chat = ?1 AND id IN (' + inl + ') ORDER BY id');
    if st = nil then Exit;
    BindText(st, 1, Chat);
    n := 0;
    while sqlite3_step(st) = 100 do
    begin
      SetLength(Result, n + 1);
      Result[n].Id := sqlite3_column_int64(st, 0); Result[n].Role := ColText(st, 1); Result[n].Agent := ColText(st, 2); Result[n].Body := ColText(st, 3);
      Inc(n);
    end;
    sqlite3_finalize(st);
  finally
    sqlite3_close(db);
  end;
end;

{ ---- renderers ------------------------------------------------------------------------------------------------------------------------ }

function RowWho(const R: TRow): string;
begin
  if R.Role = 'user' then Result := 'User'
  else if R.Agent <> '' then Result := UcFirst(R.Agent) else Result := 'Agent';
end;

function RenderInline(const Chat: string; const Ids: TIdArr): string;
var
  rows: TRows;
  i: Integer;
  body: string;
begin
  if Length(Ids) = 0 then Exit('');
  Result := HIST_FRAME_INLINE + #10;
  rows := RowsFor(Chat, Ids);
  for i := 0 to High(rows) do
  begin
    body := RTrimNl(StrRep(rows[i].Body, '\n', #10));
    Result := Result + '#' + IntToStr(rows[i].Id) + ' ' + RowWho(rows[i]) + ': ' + Cap(body) + #10#10;
  end;
  Result := Result + HIST_FRAME_END + #10#10;
end;

function JqStr(const S: string): string;                 // jq -c string escaping
var
  i: Integer;
  b: Byte;
begin
  Result := '"';
  for i := 1 to Length(S) do
  begin
    b := Ord(S[i]);
    case S[i] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      #8: Result := Result + '\b';
      #12: Result := Result + '\f';
    else
      if (b < 32) or (b = 127) then Result := Result + '\u' + LowerCase(IntToHex(b, 4)) else Result := Result + S[i];
    end;
  end;
  Result := Result + '"';
end;

function PyStr(const S: string): string;                 // python json.dumps(ensure_ascii=False)
var
  i: Integer;
  b: Byte;
begin
  Result := '"';
  for i := 1 to Length(S) do
  begin
    b := Ord(S[i]);
    case S[i] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      #8: Result := Result + '\b';
      #12: Result := Result + '\f';
    else
      if b < 32 then Result := Result + '\u' + LowerCase(IntToHex(b, 4)) else Result := Result + S[i];
    end;
  end;
  Result := Result + '"';
end;

function RenderJson(const Chat: string; const Ids: TIdArr): string;
var
  rows: TRows;
  i: Integer;
  content, role: string;
  first: Boolean;
begin
  if Length(Ids) = 0 then Exit('[]' + #10);
  rows := RowsFor(Chat, Ids);
  if Length(rows) = 0 then Exit('');
  Result := '['; first := True;
  for i := 0 to High(rows) do
  begin
    content := StrRep(rows[i].Body, '\n', #10);
    if content = '' then Continue;
    if rows[i].Role = 'user' then role := 'user' else role := 'assistant';
    if not first then Result := Result + ',';
    first := False;
    Result := Result + '{"role":' + JqStr(role) + ',"content":' + JqStr(content) + '}';
  end;
  Result := Result + ']' + #10;
end;

function RenderPointer(const Chat: string; Ids: TIdArr): string;
var
  n, i: Integer;
  rest, lastpair: TIdArr;
  lst: string;
begin
  SortIds(Ids);
  n := Length(Ids);
  SetLength(rest, 0); SetLength(lastpair, 0);
  if n >= 2 then
  begin
    SetLength(rest, n - 2); for i := 0 to n - 3 do rest[i] := Ids[i];
    SetLength(lastpair, 2); lastpair[0] := Ids[n - 2]; lastpair[1] := Ids[n - 1];
  end
  else lastpair := Ids;
  if Length(lastpair) > 0 then Result := RenderInline(Chat, lastpair) else Result := '';
  if Length(rest) > 0 then
  begin
    lst := '';
    for i := 0 to High(rest) do begin if i > 0 then lst := lst + ','; lst := lst + IntToStr(rest[i]); end;
    Result := Result + '[Earlier turns of this chat that look relevant to the new message (by keyword index): exchange ids ' + lst +
      '. The full transcript is the JSON file ' + Chat + ' -- .exchanges[] items carry id, role, agent, text. Read only those turns, and only if the new message depends on them:' + #10;
    Result := Result + '  jq ''.exchanges[] | select(.id as $i | [' + lst + '] | index($i)) | {id,role,text}'' ''' + Chat + '''' + #10 + ']' + #10#10;
  end;
end;

{ ---- the whole-tail fallbacks ---------------------------------------------------------------------------------------------------------- }

function FieldOf(const Line, Key: string): string;
var
  needle, s: string;
  p, q, startAt: Integer;
  found: Boolean;
begin
  needle := '"' + Key + '"';
  s := Line; found := False;
  p := Length(Line) - Length(needle) + 1;
  while p >= 1 do
  begin
    if Copy(Line, p, Length(needle)) = needle then
    begin
      startAt := p + Length(needle);
      q := startAt;
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

function TextFieldOf(const Line: string): string;
var
  needle, s: string;
  p, q, i, j: Integer;
  found, tailOk: Boolean;
begin
  needle := '"text"';
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
  // preg_replace('/"[,]?[ \t]*$/', '', $s, 1): the FIRST quote that is followed only by an optional comma and blanks to the end
  for i := 1 to Length(s) do
    if s[i] = '"' then
    begin
      j := i + 1;
      if (j <= Length(s)) and (s[j] = ',') then Inc(j);
      while (j <= Length(s)) and (s[j] in [' ', #9]) do Inc(j);
      tailOk := j > Length(s);
      if tailOk then begin s := Copy(s, 1, i - 1); Break; end;
    end;
  Result := StrRep(StrRep(s, '\n', ' '), '\t', ' ');
end;

function WholeTailText(const Chat: string; MaxHistory: Integer): string;
var
  content: string;
  ok: Boolean;
  lines: TStringList;
  i, depth, start, n: Integer;
  inEx: Boolean;
  role, text, agent, model, line, who, t: string;
  exR, exT, exA, exM: TStringList;

  function BlankBrace(const l, c: string): Boolean;     // ^[ \t\r\n\f\v]*c
  var
    k: Integer;
  begin
    k := 1;
    while (k <= Length(l)) and IsVws(l[k]) do Inc(k);
    Result := (k <= Length(l)) and (l[k] = c[1]);
  end;

begin
  Result := '';
  if not FileExists(Chat) then Exit;
  content := ReadFile_(Chat, ok);
  if not ValidUtf8(content) then Refuse('chat file is not valid UTF-8');
  lines := Explode(#10, content);
  exR := TStringList.Create; exT := TStringList.Create; exA := TStringList.Create; exM := TStringList.Create;
  try
    inEx := False; depth := 0; role := ''; text := ''; agent := ''; model := '';
    for i := 0 to lines.Count - 1 do
    begin
      line := lines[i];
      if (Pos('"exchanges"', line) > 0) and (Pos('[', line) > 0) then begin inEx := True; Continue; end;
      if inEx and ((Copy(line, 1, 1) = '{') or (Copy(line, 1, 3) = '  {') or (Copy(line, 1, 5) = '    {')) then
      begin Inc(depth); role := ''; text := ''; agent := ''; model := ''; end;
      if inEx and (depth = 1) then
      begin
        if Pos('"role"', line) > 0 then role := FieldOf(line, 'role');
        if Pos('"agent"', line) > 0 then agent := FieldOf(line, 'agent');
        if (Pos('"model"', line) > 0) and (Pos('null', line) = 0) then model := FieldOf(line, 'model');
        if Pos('"text"', line) > 0 then text := TextFieldOf(line);
      end;
      if inEx and (depth = 1) and BlankBrace(line, '}') then
      begin
        Dec(depth);
        if role <> '' then begin exR.Add(role); exT.Add(text); exA.Add(agent); exM.Add(model); end;
      end;
      if inEx and BlankBrace(line, ']') then inEx := False;
    end;
    if exR.Count = 0 then Exit;
    start := exR.Count - MaxHistory * 2; if start < 0 then start := 0;
    Result := HIST_FRAME_TAIL + #10;
    for n := start to exR.Count - 1 do
    begin
      if exR[n] = 'user' then who := 'User'
      else begin who := UcFirst(exA[n]); if exM[n] <> '' then who := who + ' (' + exM[n] + ')'; end;
      t := exT[n];
      if Utf8Len(t) > 1500 then t := Utf8Head(t, 1500) + '... [truncated]';
      Result := Result + who + ': ' + t + #10#10;
    end;
    Result := Result + HIST_FRAME_END + #10#10;
  finally
    lines.Free; exR.Free; exT.Free; exA.Free; exM.Free;
  end;
end;

function IfThen_(C: Boolean; const A, B: string): string;
begin
  if C then Result := A else Result := B;
end;

function WholeTailJson(const Chat: string; MaxHistory: Integer): string;
var
  raw: string;
  ok: Boolean;
  cur, p, q, t, e, j, k, textStart, endAt: Integer;
  roles, texts: TStringList;
  role, text: string;
  matched: Boolean;
  start, i: Integer;

  function SkipWs(const s: string; i: Integer): Integer;
  begin
    while (i <= Length(s)) and IsWs(s[i]) do Inc(i);
    Result := i;
  end;

  function TailOK(const s: string; i: Integer; out EndPos: Integer): Boolean;
  var
    a, b: Integer;
  begin
    Result := False;
    a := SkipWs(s, i);
    if (a <= Length(s)) and (s[a] = ',') then
    begin
      b := SkipWs(s, a + 1);
      if (b <= Length(s)) and (s[b] = '"') then
      begin
        Inc(b); k := b;
        while (b <= Length(s)) and (s[b] in ['a'..'z', '_']) do Inc(b);
        if (b > k) and (b <= Length(s)) and (s[b] = '"') then
        begin
          b := SkipWs(s, b + 1);
          if (b <= Length(s)) and (s[b] = ':') then begin EndPos := b + 1; Exit(True); end;
        end;
      end;
      b := SkipWs(s, a + 1);                       // ,?\s*\}  with the comma
      if (b <= Length(s)) and (s[b] = '}') then begin EndPos := b + 1; Exit(True); end;
    end;
    if (a <= Length(s)) and (s[a] = '}') then begin EndPos := a + 1; Exit(True); end;     // ,?\s*\}  without the comma
  end;

begin
  Result := '[]' + #10;
  if not FileExists(Chat) then Exit;
  raw := ReadFile_(Chat, ok);
  if not ValidUtf8(raw) then Refuse('chat file is not valid UTF-8');
  if Length(raw) > 1048576 then Refuse('chat file too large for the lenient reader');
  roles := TStringList.Create; texts := TStringList.Create;
  try
    cur := 1;
    while cur <= Length(raw) do
    begin
      p := Pos('"role"', Copy(raw, cur, MaxInt));
      if p = 0 then Break;
      p := cur + p - 1;
      // "role"\s*:\s*"([^"]+)"
      q := SkipWs(raw, p + 6);
      matched := False;
      if (q <= Length(raw)) and (raw[q] = ':') then
      begin
        q := SkipWs(raw, q + 1);
        if (q <= Length(raw)) and (raw[q] = '"') then
        begin
          j := q + 1;
          while (j <= Length(raw)) and (raw[j] <> '"') do Inc(j);
          if (j > q + 1) and (j <= Length(raw)) then
          begin
            role := Copy(raw, q + 1, j - q - 1);
            // .*?"text"\s*:\s*"(.*?)"\s*(?:,\s*"[a-z_]+"\s*:|,?\s*\})
            t := j + 1;
            while (not matched) and (t <= Length(raw)) do
            begin
              k := Pos('"text"', Copy(raw, t, MaxInt));
              if k = 0 then Break;
              t := t + k - 1;
              textStart := SkipWs(raw, t + 6);
              if (textStart <= Length(raw)) and (raw[textStart] = ':') then
              begin
                textStart := SkipWs(raw, textStart + 1);
                if (textStart <= Length(raw)) and (raw[textStart] = '"') then
                begin
                  Inc(textStart);
                  e := textStart;
                  while e <= Length(raw) do
                  begin
                    if raw[e] = '"' then
                      if TailOK(raw, e + 1, endAt) then
                      begin
                        text := Copy(raw, textStart, e - textStart);
                        matched := True; Break;
                      end;
                    Inc(e);
                  end;
                end;
              end;
              if not matched then Inc(t);
            end;
          end;
        end;
      end;
      if matched then begin roles.Add(role); texts.Add(text); cur := endAt; end
      else cur := p + 1;
    end;
    // decode, drop blanks, keep the last MaxHistory*2
    Result := '';
    start := 0;
    for i := 0 to roles.Count - 1 do
    begin
      text := texts[i];
      text := StrRep(text, '\n', #10); text := StrRep(text, '\t', #9); text := StrRep(text, '\r', #13); text := StrRep(text, '\"', '"'); text := StrRep(text, '\\', '\');
      k := 1;
      while (k <= Length(text)) and (text[k] in [' ', #9, #10, #13, #0, #11]) do Inc(k);
      if k > Length(text) then begin texts[i] := ''; roles[i] := ''; Continue; end;
      texts[i] := text;
    end;
    j := 0;
    for i := 0 to roles.Count - 1 do if roles[i] <> '' then Inc(j);
    start := j - MaxHistory * 2; if start < 0 then start := 0;
    Result := '['; k := 0; j := 0;
    for i := 0 to roles.Count - 1 do
    begin
      if roles[i] = '' then Continue;
      Inc(j);
      if j <= start then Continue;
      if k > 0 then Result := Result + ', ';
      Inc(k);
      Result := Result + '{"role": ' + PyStr(IfThen_(roles[i] = 'user', 'user', 'assistant')) + ', "content": ' + PyStr(texts[i]) + '}';
    end;
    Result := Result + ']' + #10;
  finally
    roles.Free; texts.Free;
  end;
end;

{ ---- append_to_chat ------------------------------------------------------------------------------------------------------------------- }

function LoopJsonEscape(const S: string): string;
var
  i: Integer;
  t: string;
begin
  t := StrRep(StrRep(StrRep(StrRep(StrRep(S, '\', '\\'), '"', '\"'), #10, '\n'), #13, '\r'), #9, '\t');
  Result := '';
  for i := 1 to Length(t) do
    if not (t[i] in [#0..#8, #11, #12, #14..#31]) then Result := Result + t[i];
  // echo "$s" taking the whole text for options
  if (Length(Result) >= 2) and (Result[1] = '-') then
  begin
    t := Copy(Result, 2, MaxInt);
    for i := 1 to Length(t) do if not (t[i] in ['n', 'e', 'E']) then begin t := ''; Break; end;
    if t <> '' then Exit('');
  end;
  Result := RTrimNl(Result);
end;

function CmdSubst(const S: string): string;
begin
  Result := RTrimNl(StrRep(S, #0, ''));
end;

function DurJson(const D: string): string;
var
  i: Integer;
  hasDigit, nonZero, dot: Boolean;
begin
  Result := 'null';
  if D = '' then Exit;
  hasDigit := False; nonZero := False; dot := False;
  for i := 1 to Length(D) do
    case D[i] of
      '0'..'9': begin hasDigit := True; if D[i] <> '0' then nonZero := True; end;
      '.': if dot then Exit else dot := True;
    else Exit;
    end;
  if (not hasDigit) or (not nonZero) then Exit;
  Result := D;
  if D[1] = '.' then Result := '0' + D;
end;

function NowStamp: string;
begin
  Result := GetEnvironmentVariable('CHAT_CLI_NOW');
  if Result <> '' then Exit;
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', EncodeDate(1970, 1, 1) + fpTime / 86400.0);
end;

procedure WriteWhole(const F, Data: string);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(F, fmCreate);
  try
    if Data <> '' then fs.WriteBuffer(Data[1], Length(Data));
  finally
    fs.Free;
  end;
end;

function PosFrom(const Sub, S: string; From: Integer): Integer;
var
  p: Integer;
begin
  p := Pos(Sub, Copy(S, From, MaxInt));
  if p = 0 then Result := 0 else Result := p + From - 1;
end;

{ heal: an empty array written on one line ("exchanges": [] or [],) is opened up so the insertion can find its bracket.
  preg_replace('/"exchanges":ws*\[\](ws*,?)ws*$/', '"exchanges": [\n  ]$1', $line, 1) }
function HealLine(const L: string): string;
var
  p, q, g: Integer;
  g1: string;
begin
  Result := L;
  p := PosFrom('"exchanges":', L, 1);
  while p > 0 do
  begin
    q := p + 12;
    while (q <= Length(L)) and IsVws(L[q]) do Inc(q);
    if Copy(L, q, 2) = '[]' then
    begin
      g := q + 2; g1 := '';
      while (g <= Length(L)) and IsVws(L[g]) do begin g1 := g1 + L[g]; Inc(g); end;
      if (g <= Length(L)) and (L[g] = ',') then begin g1 := g1 + ','; Inc(g); end;
      while (g <= Length(L)) and IsVws(L[g]) do Inc(g);
      if g > Length(L) then Exit(Copy(L, 1, p - 1) + '"exchanges": [' + #10 + '  ]' + g1);
    end;
    p := PosFrom('"exchanges":', L, p + 1);
  end;
end;

{ the "updated" stamp, first occurrence on the line: "updated":ws*"[^"]*" }
function ReplaceUpdated(const L, Now_: string): string;
var
  p, q: Integer;
begin
  Result := L;
  p := PosFrom('"updated":', L, 1);
  while p > 0 do
  begin
    q := p + 10;
    while (q <= Length(L)) and IsVws(L[q]) do Inc(q);
    if (q <= Length(L)) and (L[q] = '"') then
    begin
      Inc(q);
      while (q <= Length(L)) and (L[q] <> '"') do Inc(q);
      if q <= Length(L) then Exit(Copy(L, 1, p - 1) + '"updated": "' + Now_ + '"' + Copy(L, q + 1, MaxInt));
    end;
    p := PosFrom('"updated":', L, p + 1);
  end;
end;

function BracketLine(const L: string): Boolean;       // ^ws*\],?ws*$
var
  i: Integer;
begin
  i := 1;
  while (i <= Length(L)) and IsVws(L[i]) do Inc(i);
  if (i > Length(L)) or (L[i] <> ']') then Exit(False);
  Inc(i);
  if (i <= Length(L)) and (L[i] = ',') then Inc(i);
  while (i <= Length(L)) and IsVws(L[i]) do Inc(i);
  Result := i > Length(L);
end;

function JoinLines(L: TStringList): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to L.Count - 1 do begin if i > 0 then Result := Result + #10; Result := Result + L[i]; end;
end;

function AppendChat: Integer;
var
  chat, now_, userText, agentText, userEsc, agentEsc, modelEsc, agent, content, newBlk, tpl, text, tmp, l: string;
  ok: Boolean;
  lockFd: cint;
  rawCount, nextId, i: Integer;
  lines, healed, healedLines, outL, finalLines: TStringList;
  done, foundOpen, hasItems: Boolean;
  rows: TRows;
begin
  chat := Opt('--chat');
  if (chat = '') or (Opt('--user-file') = '') or (Opt('--agent-file') = '') then begin Err_('append needs --chat --user-file --agent-file' + #10); Exit(2); end;
  now_ := NowStamp;
  userText := CmdSubst(ReadFileS(Opt('--user-file')));
  agentText := CmdSubst(ReadFileS(Opt('--agent-file')));
  if FileExists(chat) and SqliteReady then begin rows := ChatRows(chat); SetLength(rows, 0); end;      // a chat that is not strict JSON is refused BEFORE any change
  userEsc := LoopJsonEscape(userText); agentEsc := LoopJsonEscape(agentText); modelEsc := LoopJsonEscape(Opt('--model'));
  agent := Opt('--agent');
  lockFd := fpOpen(PChar(chat + '.lock'), O_WRONLY or O_CREAT, &666);
  if lockFd < 0 then Exit(3);
  fpFlock(lockFd, LOCK_EX);
  try
    if FileExists(chat) then Out_(Sync(chat, Opt('--agent-uc')));
    if not FileExists(chat) then
    begin
      ForceDirectories(ExtractFileDir(chat));
      tpl := '{' + #10 + '  "schema_version": 1,' + #10 + '  "project": "' + Opt('--project') + '",' + #10 + '  "chat": "' + Opt('--chat-name') + '",' + #10 +
             '  "created": "' + now_ + '",' + #10 + '  "updated": "' + now_ + '",' + #10 + '  "exchanges": [' + #10 + '  ]' + #10 + '}' + #10;
      try WriteWhole(chat, tpl); except Exit(3); end;
      fpChmod(PChar(chat), &664);
    end;
    content := ReadFile_(chat, ok);
    lines := Explode(#10, content);
    rawCount := 0;
    for i := 0 to lines.Count - 1 do if Pos('"role"', lines[i]) > 0 then Inc(rawCount);
    nextId := rawCount + 1;
    newBlk := '    {' + #10 + '      "id": ' + IntToStr(nextId) + ',' + #10 + '      "timestamp": "' + now_ + '",' + #10 + '      "role": "user",' + #10 + '      "text": "' + userEsc + '"' + #10 + '    },' + #10 +
              '    {' + #10 + '      "id": ' + IntToStr(nextId + 1) + ',' + #10 + '      "timestamp": "' + now_ + '",' + #10 + '      "role": "agent",' + #10 + '      "agent": "' + agent + '",' + #10 +
              '      "supplier": "' + LoopJsonEscape(Opt('--supplier')) + '",' + #10 + '      "model": ' + IfThen_(modelEsc <> '', '"' + modelEsc + '"', 'null') + ',' + #10 +
              '      "duration_s": ' + DurJson(Opt('--duration')) + ',' + #10 + '      "style": "' + LoopJsonEscape(Opt('--style')) + '",' + #10 + '      "mode": "' + LoopJsonEscape(Opt('--mode')) + '",' + #10 +
              '      "text": "' + agentEsc + '"' + #10 + '    }';
    healed := TStringList.Create; outL := TStringList.Create; healedLines := nil; finalLines := nil;
    try
      for i := 0 to lines.Count - 1 do healed.Add(HealLine(lines[i]));
      healedLines := Explode(#10, JoinLines(healed));
      if (content <> '') and (content[Length(content)] = #10) and (healedLines.Count > 0) and (healedLines[healedLines.Count - 1] = '') then healedLines.Delete(healedLines.Count - 1);
      if content = '' then healedLines.Clear;
      done := False; foundOpen := False; hasItems := False;
      for i := 0 to healedLines.Count - 1 do
      begin
        l := healedLines[i];
        if (not done) and BracketLine(l) then
        begin
          if foundOpen and not hasItems then outL.Add(newBlk)
          else if foundOpen then begin outL.Add(','); outL.Add(newBlk); end;
          done := True;
        end;
        outL.Add(l);
        if Pos('"exchanges"', l) > 0 then foundOpen := True;
        if Pos('"role"', l) > 0 then hasItems := True;
      end;
      finalLines := Explode(#10, JoinLines(outL));
      text := '';
      for i := 0 to finalLines.Count - 1 do text := text + ReplaceUpdated(finalLines[i], now_) + #10;
      if outL.Count = 0 then text := '';
    finally
      healed.Free; outL.Free; lines.Free;
      if healedLines <> nil then healedLines.Free;
      if finalLines <> nil then finalLines.Free;
    end;
    tmp := chat + '.tmp' + IntToStr(fpGetPid);
    try WriteWhole(tmp, text); except Exit(3); end;
    if fpRename(PChar(tmp), PChar(chat)) <> 0 then begin DeleteFile(tmp); Exit(3); end;
    fpChmod(PChar(chat), &664);
    AddRow(chat, nextId, 'user', '', now_, userText);
    AddRow(chat, nextId + 1, 'agent', agent, now_, agentText);
  finally
    fpFlock(lockFd, LOCK_UN); fpClose(lockFd);
  end;
  Result := 0;
end;

{ ---- build_history -------------------------------------------------------------------------------------------------------------------- }

function Build(const Chat, Prompt, Fmt, Mode, UC: string): Integer;
var
  lockFd: cint;
  log: string;
  ids: TIdArr;
  i: Integer;
  lst: string;
begin
  if (not SqliteReady) or (not FileExists(Chat)) then
  begin
    Err_('[' + UC + '] history: whole tail (no index)' + #10);
    if Fmt = 'json' then Out_(WholeTailJson(Chat, GMax)) else Out_(WholeTailText(Chat, GMax));
    if (Fmt <> 'json') and not FileExists(Chat) then Exit(1);
    Exit(0);
  end;
  ChatRows(Chat);                                   // refuse a file this program cannot read exactly, before any change
  lockFd := fpOpen(PChar(Chat + '.lock'), O_WRONLY or O_CREAT, &666);
  if lockFd >= 0 then fpFlock(lockFd, LOCK_EX);
  try
    log := Sync(Chat, UC);
  finally
    if lockFd >= 0 then begin fpFlock(lockFd, LOCK_UN); fpClose(lockFd); end;
  end;
  Err_(log);
  ids := SelectIds(Chat, Prompt, GMax);
  if Length(ids) = 0 then
  begin
    Err_('[' + UC + '] history: whole tail (index empty)' + #10);
    if Fmt = 'json' then Out_(WholeTailJson(Chat, GMax)) else Out_(WholeTailText(Chat, GMax));
    Exit(0);
  end;
  lst := '';
  for i := 0 to High(ids) do begin if i > 0 then lst := lst + ','; lst := lst + IntToStr(ids[i]); end;
  if Fmt = 'json' then
  begin
    Err_('[' + UC + '] history: inline-json ids=' + lst + #10);
    Out_(RenderJson(Chat, ids));
    Exit(0);
  end;
  Err_('[' + UC + '] history: ' + Mode + ' ids=' + lst + #10);
  if Mode = 'pointer' then Out_(RenderPointer(Chat, ids)) else Out_(RenderInline(Chat, ids));
  Result := 0;
end;

{ ---- the commands --------------------------------------------------------------------------------------------------------------------- }

function HistoryRun(const Cmd: string; const Args: array of string; const StdinData: string; out OutS, ErrS: string): Integer;
var
  i: Integer;
  uc, s: string;
  ok: Boolean;
begin
  GOut := ''; GErr := ''; GIndexReady := -1;
  SetLength(GArgs, Length(Args));
  for i := 0 to High(Args) do GArgs[i] := Args[i];
  GMax := StrToIntDef(GetEnvironmentVariable('MAX_HISTORY'), 0);
  if GMax < 1 then GMax := 6;
  uc := Opt('--agent', 'AGENT');
  try
    if Cmd = 'append' then Result := AppendChat
    else if Cmd = 'needs' then Result := Needs(StdinData, uc)
    else if Cmd = 'build' then
    begin
      if Opt('--chat') = '' then begin Err_('build needs --chat' + #10); Result := 2; end
      else Result := Build(Opt('--chat'), StdinData, Opt('--format', 'text'), Opt('--mode', 'inline'), uc);
    end
    else if Cmd = 'sync' then
    begin
      if Opt('--chat') = '' then begin Err_('sync needs --chat' + #10); Result := 2; end
      else begin Out_(Sync(Opt('--chat'), uc)); Result := 0; end;
    end
    else if Cmd = 'add' then
    begin
      if (Opt('--chat') = '') or (Opt('--text-file') = '') then begin Err_('add needs --chat and --text-file' + #10); Result := 2; end
      else
      begin
        s := ReadFile_(Opt('--text-file'), ok);
        AddRow(Opt('--chat'), StrToInt64Def(Opt('--id', '0'), 0), Opt('--role'), Opt('--agent'), Opt('--ts'), s);
        Result := 0;
      end;
    end
    else begin Err_('usage: history_cli.php needs|build|sync|add ...' + #10); Result := 2; end;
  except
    on E: EHistRefuse do begin GOut := ''; GErr := E.Message + #10; Result := HISTORY_REFUSED; end;
  end;
  OutS := GOut; ErrS := GErr;
end;

end.
