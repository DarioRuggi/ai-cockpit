(* =============================================================================
  aic_legacy — the engine takes over what agent_loop.sh's `run_generic_cli` and its Claude branch do today.

  `aicengine legacy` builds the same command line from the same merged catalog (cli_catalog.json), runs it and
  leaves the answer in the same plain-text OUT_FILE that Cockpit already polls (bridge.php reads it as it grows).
  Nothing else about the loop changes: queue, history, RAG, chat saving and the done-file all stay in Bash for now.
  The point of this slice is the step that spawns the agent: process group, environment, signals, no hung stdin,
  and no dependence on jq, `sed -i` or `stdbuf`.

  What is reproduced EXACTLY (checked against the Bash by tests/legacy_parity.sh on identical inputs):
    * argument order:  binary, subcmd, model flag + (prefixed) model, catalog extra_args, request EXTRA_CLI_ARGS,
                       image flag per existing file (+ "--" for variadic flags), prompt flag + prompt | prompt;
    * the prompt is `$(cat file)`: trailing newlines stripped, NUL bytes dropped;
    * the environment: OLLAMA_API_BASE for backend=ollama; catalog `env` entries with %MODEL% = the raw model;
    * stdout and stderr land in OUT_FILE through ONE pipe (as `> file 2>&1`), in kernel order, as they are written;
    * a non-zero exit appends "[SUPPLIER ERROR] CLI failed or not installed — check ...cli_catalog.json.";
    * opencode's "> build · model" banner line and a blank first line are removed (the sed it replaces);
    * parse=claude_json (and the native Claude call): stdout is JSON, the answer is jq's
      `.result // .error.message // .error // empty` (including how it treats a value it cannot index),
      stderr is shown only when nothing came out (first 2000 bytes).
  Deliberate differences (all improvements, listed in the README):
    * the child's stdin is closed (EOF) instead of inheriting the terminal: an agent that waits for stdin can no
      longer look like a hung agent;
    * the child runs in its own process group, so Stop (SIGINT to the engine) kills the whole agent tree;
    * the Claude answer is extracted even when jq is not installed;
    * a program that does not exist writes the error line only (Bash also printed its own "command not found" text).
  ============================================================================= *)
unit aic_legacy;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, aic_proc, aic_http, aic_https;

type
  TLegacyOptions = record
    CatalogFile: string;       // merged catalog (cli_catalog.json)
    Supplier: string;          // catalog key (claude is the slot alias, the supplier decides)
    ClaudeModel: string;       // when set: the native Claude call with this full model string (catalog ignored)
    RawModel: string;          // the plain model (an ollama tag, ...), before the catalog prefix
    PromptFile: string;
    OutFile: string;
    Images: string;            // REQ_IMAGES: paths separated by |
    ExtraCliArgs: string;      // EXTRA_CLI_ARGS from the request (split on whitespace)
    LocalBase: string;         // LOCAL_BASE; default http://127.0.0.1:11434
    Cwd: string;
    TimeoutS: Integer;         // 0 = none (as today)
  end;

var
  LegacyCancel: Boolean = False;     // set by the signal handler: Stop was pressed

{ pieces exposed for the unit tests }
function LegacySplitWords(const S: string): TStringList;
function LegacyOpencodeStrip(const S: string): string;
function LegacyClaudeResult(const Raw: string): string;
function LegacyBuildCommand(const O: TLegacyOptions; out Exe: string; Args, Env: TStrings; out ParseMode, ErrLabel: string): string;

{ Run it. Returns the agent's exit code (130 when cancelled, 127 when the program does not exist, 2 on a bad request). }
function RunLegacy(const O: TLegacyOptions; out Msg: string): Integer;

{ opencode reaches Ollama through a provider block in ~/.config/opencode/opencode.json that must also list the model
  by name, else every run ends in "Unexpected server error". Merges ours in, keeping whatever else is there.
  Same as agent_loop.sh's opencode_ensure_provider (jq), including its result: no change when the model is already
  listed or the file is not usable JSON. True when the file was written. }
function EnsureOpencodeProvider(const Home, Tag, LocalBase: string): Boolean;

type
  TLocalChatOptions = record
    Base, Style, Model: string;          // server base URL; 'ollama' | 'openai'; model name
    SystemFile, HistoryFile, UserFile: string;
    OutFile: string;
    AgentUc: string;                     // for the log line
    TimeoutS: Integer;                   // whole request, curl -m 300 in the Bash
  end;

{ The Ollama / OpenAI-compatible branch of agent_loop.sh: build the chat request, make sure the model exists
  (Ollama only), stream the reply into OUT_FILE as it arrives.  0 = done (the file may still be empty: the loop
  words that), 2 = refused before anything was sent (bad history JSON ...): the Bash path then does it. }
function RunLocalChat(const O: TLocalChatOptions; out Msg: string): Integer;

type
  TGeminiOptions = record
    Base: string;              // https://generativelanguage.googleapis.com (tests point it at a local server)
    Model: string;             // gemini-2.5-flash ...
    PromptFile: string;        // the whole prompt, as agent_loop.sh built it
    OutFile: string;           // the answer (or an "[GEMINI ERROR] ..." line) is APPENDED, as the Bash does
    CaFile: string;            // PEM bundle to trust instead of the system store (tests)
    ResolveIp: string;         // use this address instead of DNS (tests)
    TimeoutS: Integer;         // curl -m 180
  end;

{ The Gemini REST branch of agent_loop.sh: one generateContent call, the answer text (or an error line) into OUT_FILE.
  The API key comes from the environment (GEMINI_API_KEY), never from the command line. 0 = done (the file holds an answer or
  an "[GEMINI ERROR]" line), 2 = refused before anything was sent (no key, no prompt file): the Bash path then does it. }
function RunGemini(const O: TGeminiOptions; out Msg: string): Integer;

type
  TPromptOptions = record
    Agent, Project, ProjectDir, ChatName, DataDir: string;
    CliSupplier, ClaudeModel, GeminiModel, Model, PromptStyle: string;      // identity line and dialect
    UserFile, HistoryFile, RagFile, WorkersFile, ToolsFile, CapsFile: string; // text blocks the loop computed (a missing/empty file = none)
    CrudFile, StyleFile: string;                                              // the two fixed system texts (CRUD protocol / Claude style guide)
    OutFile, SysOutFile: string;                                              // PROMPT_TMP and SYS_TMP
  end;

{ assemble_prompt of agent_loop.sh: goal / kind / descriptions of the chat and project, COCKPIT.md, the person's profile, the global
  directives and the identity line, laid out for Claude (one flat prompt) or for Gemini/Ollama (a system block, then the flat prompt).
  0 = both files written; 2 = refused before writing anything (a missing input file): the Bash then does it. }
function RunPrompt(const O: TPromptOptions; out Msg: string): Integer;

implementation

uses
  fpjson, jsonparser;

{ ---- helpers ---------------------------------------------------------------------------------------- }

{ Shell word splitting of an unquoted expansion: runs of space, tab and newline separate words. }
function LegacySplitWords(const S: string): TStringList;
var
  i: Integer;
  cur: string;
begin
  Result := TStringList.Create;
  cur := '';
  for i := 1 to Length(S) do
    if S[i] in [' ', #9, #10] then
    begin
      if cur <> '' then begin Result.Add(cur); cur := ''; end;
    end
    else cur := cur + S[i];
  if cur <> '' then Result.Add(cur);
end;

function ReadWhole(const F: string): string;
var
  fs: TFileStream;
begin
  Result := '';
  if not FileExists(F) then Exit;
  fs := TFileStream.Create(F, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[1], fs.Size);
  finally
    fs.Free;
  end;
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

{ `$(cat file)`: the shell removes every trailing newline and cannot hold a NUL byte. }
function CommandSubstitution(const S: string): string;
var
  i, n: Integer;
begin
  SetLength(Result, Length(S));
  n := 0;
  for i := 1 to Length(S) do
    if S[i] <> #0 then begin Inc(n); Result[n] := S[i]; end;
  SetLength(Result, n);
  while (Result <> '') and (Result[Length(Result)] = #10) do SetLength(Result, Length(Result) - 1);
end;

{ opencode prefixes its answer with "> build · <model>".  The sed this replaces:
    sed -e '/^[[:space:]]*> build · /d' -e '1{/^[[:space:]]*$/d}'
  i.e. drop banner lines, and drop line 1 if it is blank (line numbers are of the INPUT). }
function LegacyOpencodeStrip(const S: string): string;
var
  lines: TStringList;
  i: Integer;
  t, banner: string;
  outS: string;
  hadFinalNl: Boolean;
begin
  banner := '> build ' + #$C2#$B7 + ' ';                       // "> build · "
  if S = '' then Exit('');
  lines := TStringList.Create;
  try
    lines.LineBreak := #10;
    hadFinalNl := S[Length(S)] = #10;
    lines.Text := S;
    outS := '';
    for i := 0 to lines.Count - 1 do
    begin
      t := TrimLeft(lines[i]);
      if Copy(t, 1, Length(banner)) = banner then Continue;
      if (i = 0) and (Trim(lines[i]) = '') then Continue;
      outS := outS + lines[i] + #10;
    end;
    if (not hadFinalNl) and (outS <> '') then SetLength(outS, Length(outS) - 1);
    Result := outS;
  finally
    lines.Free;
  end;
end;

{ ---- jq -r '.result // .error.message // .error // empty', over a stream of JSON values --------------- }

function Truthy(D: TJSONData): Boolean;
begin
  if D = nil then Exit(False);
  if D.JSONType = jtNull then Exit(False);
  if (D.JSONType = jtBoolean) and (not D.AsBoolean) then Exit(False);
  Result := True;
end;

{ jq's string escaping: quote, backslash, the short control escapes, other control bytes as \u00XX (and DEL). }
function JqString(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '"';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      #8: Result := Result + '\b';
      #12: Result := Result + '\f';
    else
      if (c < #32) or (c = #127) then Result := Result + '\u' + LowerCase(IntToHex(Ord(c), 4)) else Result := Result + c;
    end;
  end;
  Result := Result + '"';
end;

{ jq's default output for a non-string: objects and arrays one member per line, two spaces per level; {} and [] stay inline. }
function JqPretty(D: TJSONData; Level: Integer): string;
var
  i: Integer;
  pad, pad1: string;
begin
  pad := StringOfChar(' ', 2 * Level); pad1 := StringOfChar(' ', 2 * (Level + 1));
  case D.JSONType of
    jtString: Result := JqString(D.AsString);
    jtObject:
      if D.Count = 0 then Result := '{}'
      else
      begin
        Result := '{'#10;
        for i := 0 to D.Count - 1 do
        begin
          Result := Result + pad1 + JqString(TJSONObject(D).Names[i]) + ': ' + JqPretty(TJSONObject(D).Items[i], Level + 1);
          if i < D.Count - 1 then Result := Result + ',';
          Result := Result + #10;
        end;
        Result := Result + pad + '}';
      end;
    jtArray:
      if D.Count = 0 then Result := '[]'
      else
      begin
        Result := '['#10;
        for i := 0 to D.Count - 1 do
        begin
          Result := Result + pad1 + JqPretty(TJSONArray(D).Items[i], Level + 1);
          if i < D.Count - 1 then Result := Result + ',';
          Result := Result + #10;
        end;
        Result := Result + pad + ']';
      end;
  else
    Result := D.AsJSON;                                            // numbers, true/false/null
  end;
end;

{ jq -r: a string is printed raw, anything else in jq's pretty form }
function Rendered(D: TJSONData): string;
begin
  if D.JSONType = jtString then Result := D.AsString else Result := JqPretty(D, 0);
end;

function NextJsonValue(const S: string; var Pos: Integer; out Piece: string): Boolean;
var
  i, depth: Integer;
  inStr, esc: Boolean;
  c: Char;
begin
  Result := False; Piece := '';
  i := Pos;
  while (i <= Length(S)) and (S[i] in [' ', #9, #10, #13]) do Inc(i);
  if i > Length(S) then begin Pos := i; Exit; end;
  Pos := i;
  if S[i] in ['{', '['] then
  begin
    depth := 0; inStr := False; esc := False;
    while i <= Length(S) do
    begin
      c := S[i];
      if inStr then
      begin
        if esc then esc := False
        else if c = '\' then esc := True
        else if c = '"' then inStr := False;
      end
      else if c = '"' then inStr := True
      else if c in ['{', '['] then Inc(depth)
      else if c in ['}', ']'] then
      begin
        Dec(depth);
        if depth = 0 then begin Piece := Copy(S, Pos, i - Pos + 1); Pos := i + 1; Exit(True); end;
      end;
      Inc(i);
    end;
    Exit(False);                                                  // an unfinished value: jq stops here too
  end;
  if S[i] = '"' then                                              // a top-level string
  begin
    Inc(i); esc := False;
    while i <= Length(S) do
    begin
      if esc then esc := False
      else if S[i] = '\' then esc := True
      else if S[i] = '"' then begin Piece := Copy(S, Pos, i - Pos + 1); Pos := i + 1; Exit(True); end;
      Inc(i);
    end;
    Exit(False);
  end;
  while (i <= Length(S)) and not (S[i] in [' ', #9, #10, #13]) do Inc(i);
  Piece := Copy(S, Pos, i - Pos); Pos := i;
  Result := True;
end;

{ `//` does not hide errors: indexing a string, number, boolean or array with a name is a runtime ERROR.  jq reports
  it on its own stderr and carries on with the NEXT input value (only text that is not JSON at all stops it, and what
  it printed before stays).  So, per value:
    object: .result if it is not null/false; else (.error absent/null -> nothing; .error an object -> .message if
            truthy, else the .error object itself; .error anything else -> error: nothing for this value)
    null:   nothing
    other:  error: nothing for this value }
function LegacyClaudeResult(const Raw: string): string;
var
  p: Integer;
  piece: string;
  d, r, e, m: TJSONData;
  o: TJSONObject;
begin
  Result := '';
  p := 1;
  while NextJsonValue(Raw, p, piece) do
  begin
    try
      d := GetJSON(piece);
    except
      Break;                                                      // invalid JSON: jq reports it and stops; what it printed stays
    end;
    try
      if d.JSONType = jtNull then Continue;
      if d.JSONType <> jtObject then Continue;                    // jq: runtime error on this value (message to its stderr), next input
      o := TJSONObject(d);
      r := o.Find('result');
      if Truthy(r) then begin Result := Result + Rendered(r) + #10; Continue; end;
      e := o.Find('error');
      if (e = nil) or (e.JSONType = jtNull) then Continue;        // .error.message -> null, .error -> null, empty
      if e.JSONType <> jtObject then Continue;                    // .error.message on a non-object: runtime error, next input
      m := TJSONObject(e).Find('message');
      if Truthy(m) then Result := Result + Rendered(m) + #10
      else Result := Result + Rendered(e) + #10;                  // message null/false: .error is the (truthy) object
    finally
      d.Free;
    end;
  end;
end;

{ ---- the command line ------------------------------------------------------------------------------ }

function CatStr(Cat: TJSONObject; const Key, Def: string): string;     // jq: .key // "def"  (null/false -> default)
var
  v: TJSONData;
begin
  Result := Def;
  v := Cat.Find(Key);
  if Truthy(v) then
    if v.JSONType = jtString then Result := v.AsString else Result := v.AsJSON;
end;

function CatTrue(Cat: TJSONObject; const Key: string): Boolean;
begin
  Result := Truthy(Cat.Find(Key));
end;

{ Returns '' when fine, else the reason the request cannot be built. }
function LegacyBuildCommand(const O: TLegacyOptions; out Exe: string; Args, Env: TStrings; out ParseMode, ErrLabel: string): string;
var
  doc: TJSONData;
  root, cat, emptyCat: TJSONObject;
  sup, binary, promptFlag, modelFlag, prefix, subcmd, imgFlag, envTxt, backend, m, prompt, kv: string;
  words: TStringList;
  imgs: TStringList;
  i, added: Integer;
  txt: string;
begin
  Result := '';
  emptyCat := nil;
  Exe := ''; ParseMode := 'text'; ErrLabel := '';
  Args.Clear; Env.Clear;
  if not FileExists(O.PromptFile) then Exit('prompt file not found: ' + O.PromptFile);
  prompt := CommandSubstitution(ReadWhole(O.PromptFile));

  // ---- the native Claude call (agent_loop.sh, claude branch) ----
  if O.ClaudeModel <> '' then
  begin
    Exe := 'claude'; ErrLabel := 'CLAUDE'; ParseMode := 'claude_json';
    Args.Add('--model'); Args.Add(O.ClaudeModel);
    words := LegacySplitWords(O.ExtraCliArgs);
    try for i := 0 to words.Count - 1 do Args.Add(words[i]); finally words.Free; end;
    Args.Add('--dangerously-skip-permissions');
    Args.Add('-p'); Args.Add(prompt);
    Args.Add('--output-format'); Args.Add('json');
    Exit;
  end;

  // ---- the catalog-driven call (run_generic_cli) ----
  sup := O.Supplier;
  if sup = '' then Exit('no supplier given');
  if not FileExists(O.CatalogFile) then Exit('catalog not found: ' + O.CatalogFile);
  txt := ReadWhole(O.CatalogFile);
  try
    doc := GetJSON(txt);
  except
    on E: Exception do Exit('catalog is not valid JSON: ' + E.Message);
  end;
  try
    if doc.JSONType <> jtObject then Exit('catalog is not a JSON object');
    root := TJSONObject(doc);
    if root.Find(sup) is TJSONObject then cat := TJSONObject(root.Find(sup))
    else begin emptyCat := TJSONObject.Create; cat := emptyCat; end;       // an unknown supplier: every default applies
    binary := CatStr(cat, 'binary', ''); if binary = '' then binary := sup;
    promptFlag := CatStr(cat, 'cli_flag', '-p');
    modelFlag := CatStr(cat, 'model_flag', '');
    prefix := CatStr(cat, 'model_prefix', '');
    subcmd := CatStr(cat, 'subcmd', '');
    ParseMode := CatStr(cat, 'parse', 'text');
    backend := CatStr(cat, 'backend', '');
    envTxt := CatStr(cat, 'env', '');
    if CatStr(cat, 'image_mode', '') = 'flag' then imgFlag := CatStr(cat, 'image_flag', '') else imgFlag := '';
    Exe := binary;
    ErrLabel := UpperCase(sup);

    m := O.RawModel;
    if (prefix <> '') and (m <> '') and (m <> 'auto') then m := prefix + m;
    if subcmd <> '' then begin words := LegacySplitWords(subcmd); try for i := 0 to words.Count - 1 do Args.Add(words[i]); finally words.Free; end; end;
    if (modelFlag <> '') and (m <> '') and (m <> 'auto') then begin Args.Add(modelFlag); Args.Add(m); end;
    words := LegacySplitWords(CatStr(cat, 'extra_args', ''));
    try for i := 0 to words.Count - 1 do Args.Add(words[i]); finally words.Free; end;
    words := LegacySplitWords(O.ExtraCliArgs);
    try for i := 0 to words.Count - 1 do Args.Add(words[i]); finally words.Free; end;

    added := 0;
    if (imgFlag <> '') and (O.Images <> '') then
    begin
      imgs := TStringList.Create;
      try
        imgs.Delimiter := '|'; imgs.StrictDelimiter := True; imgs.DelimitedText := O.Images;
        for i := 0 to imgs.Count - 1 do
          if (imgs[i] <> '') and FileExists(imgs[i]) then begin Args.Add(imgFlag); Args.Add(imgs[i]); Inc(added); end;
      finally
        imgs.Free;
      end;
    end;
    if (added > 0) and CatTrue(cat, 'image_needs_sep') then Args.Add('--');
    if promptFlag <> '' then begin Args.Add(promptFlag); Args.Add(prompt); end else Args.Add(prompt);

    if backend = 'ollama' then
      if O.LocalBase <> '' then Env.Add('OLLAMA_API_BASE=' + O.LocalBase) else Env.Add('OLLAMA_API_BASE=http://127.0.0.1:11434');
    words := LegacySplitWords(envTxt);
    try
      for i := 0 to words.Count - 1 do
      begin
        kv := StringReplace(words[i], '%MODEL%', O.RawModel, [rfReplaceAll]);
        if Pos('=', kv) > 1 then Env.Add(kv);
      end;
    finally
      words.Free;
    end;
  finally
    emptyCat.Free;
    doc.Free;
  end;
end;

{ ---- opencode's provider block ----------------------------------------------------------------------- }

{ The child object `Key` of Parent, created when absent or null; nil when the key holds something that is not an
  object (jq would raise an error there, and the Bash leaves the file alone). }
function ObjChild(Parent: TJSONObject; const Key: string): TJSONObject;
var
  v: TJSONData;
begin
  v := Parent.Find(Key);
  if (v = nil) or (v.JSONType = jtNull) then
  begin
    Result := TJSONObject.Create;
    if v <> nil then Parent.Delete(Key);
    Parent.Add(Key, Result);
  end
  else if v.JSONType = jtObject then Result := TJSONObject(v)
  else Result := nil;
end;

procedure ObjSetString(O: TJSONObject; const Key, Val: string);
begin
  O.Elements[Key] := TJSONString.Create(Val);          // an existing key keeps its position (as in jq), a new one is appended
end;

function EnsureOpencodeProvider(const Home, Tag, LocalBase: string): Boolean;
var
  dir, cfg, txt, base, tmp: string;
  doc: TJSONData;
  root, prov, oll, opts, models, one: TJSONObject;
  v: TJSONData;
begin
  Result := False;
  if (Tag = '') or (Tag = 'auto') or (Home = '') then Exit;
  dir := IncludeTrailingPathDelimiter(Home) + '.config/opencode';
  cfg := dir + '/opencode.json';
  ForceDirectories(dir);
  txt := ReadWhole(cfg);
  if txt = '' then
  begin
    WriteWhole(cfg, '{"$schema":"https://opencode.ai/config.json"}' + #10);       // [ -s file ] || printf ... > file
    txt := ReadWhole(cfg);
  end;
  try
    doc := GetJSON(txt);
  except
    Exit;                                                                         // not JSON: jq fails, the file stays as it is
  end;
  try
    if doc.JSONType = jtNull then begin doc.Free; doc := TJSONObject.Create; end;
    if doc.JSONType <> jtObject then Exit;
    root := TJSONObject(doc);
    // jq -e '.provider.ollama.models[$t] != null'  -> already there: nothing to do
    prov := nil; oll := nil; models := nil;
    v := root.Find('provider');
    if (v <> nil) and (v.JSONType = jtObject) then
    begin
      v := TJSONObject(v).Find('ollama');
      if (v <> nil) and (v.JSONType = jtObject) then
      begin
        v := TJSONObject(v).Find('models');
        if (v <> nil) and (v.JSONType = jtObject) then
        begin
          v := TJSONObject(v).Find(Tag);
          if (v <> nil) and (v.JSONType <> jtNull) then Exit;
        end;
      end;
    end;
    // .provider.ollama.npm = ... | .name = (.name // "Ollama (local)") | .options.baseURL = $b | .models[$t] = {name: $t}
    if LocalBase <> '' then base := LocalBase else base := 'http://127.0.0.1:11434';
    base := base + '/v1';
    prov := ObjChild(root, 'provider'); if prov = nil then Exit;
    oll := ObjChild(prov, 'ollama'); if oll = nil then Exit;
    ObjSetString(oll, 'npm', '@ai-sdk/openai-compatible');
    v := oll.Find('name');
    if not Truthy(v) then ObjSetString(oll, 'name', 'Ollama (local)');
    opts := ObjChild(oll, 'options'); if opts = nil then Exit;
    ObjSetString(opts, 'baseURL', base);
    models := ObjChild(oll, 'models'); if models = nil then Exit;
    one := TJSONObject.Create; one.Add('name', Tag);
    models.Elements[Tag] := one;
    // written through a temporary file and renamed, readable only by the owner — as mktemp + mv left it
    tmp := cfg + '.tmp' + IntToStr(GetProcessID);
    WriteWhole(tmp, JqPretty(root, 0) + #10);
    fpChmod(tmp, &600);
    if not RenameFile(tmp, cfg) then begin DeleteFile(tmp); Exit; end;
    Result := True;
  finally
    doc.Free;
  end;
end;

{ ---- the local chat branch ----------------------------------------------------------------------------- }

{ jq replaces bytes that are not UTF-8 with U+FFFD before it ever builds a JSON string. }
function Utf8Scrub(const S: string): string;
var
  i, n, need, j: Integer;
  c: Byte;
  ok: Boolean;
begin
  Result := '';
  i := 1; n := Length(S);
  while i <= n do
  begin
    c := Ord(S[i]);
    if c < $80 then begin Result := Result + S[i]; Inc(i); Continue; end;
    if (c >= $C2) and (c <= $DF) then need := 1
    else if (c >= $E0) and (c <= $EF) then need := 2
    else if (c >= $F0) and (c <= $F4) then need := 3
    else need := -1;
    ok := (need > 0) and (i + need <= n);
    if ok then
      for j := 1 to need do if (Ord(S[i + j]) and $C0) <> $80 then ok := False;
    if ok and (c = $E0) and (Ord(S[i + 1]) < $A0) then ok := False;          // overlong
    if ok and (c = $ED) and (Ord(S[i + 1]) >= $A0) then ok := False;         // surrogate
    if ok and (c = $F0) and (Ord(S[i + 1]) < $90) then ok := False;
    if ok and (c = $F4) and (Ord(S[i + 1]) >= $90) then ok := False;
    if ok then begin Result := Result + Copy(S, i, need + 1); Inc(i, need + 1); end
    else begin Result := Result + #$EF#$BF#$BD; Inc(i); end
  end;
end;

type
  TLocalChat = class
    Out: TFileStream;
    Style: string;
    function IsCancelled: Boolean;
    procedure OnLine(const Line: string);
  end;

function TLocalChat.IsCancelled: Boolean;
begin
  Result := LegacyCancel;
end;

procedure TLocalChat.OnLine(const Line: string);
var
  d, m, c, e, ch, dl: TJSONData;
  s, piece: string;
begin
  piece := '';
  if Style = 'openai' then
  begin
    // case "$_line" in data:\ *) ... [DONE] ... jq -j '.choices[0].delta.content // empty'
    if Copy(Line, 1, 6) <> 'data: ' then Exit;
    s := Copy(Line, 7, MaxInt);
    if s = '[DONE]' then Exit;
  end
  else s := Line;
  try
    d := GetJSON(s);
  except
    Exit;                                                       // jq on a line that is not JSON: nothing
  end;
  try
    if d.JSONType <> jtObject then Exit;
    if Style = 'openai' then
    begin
      ch := TJSONObject(d).Find('choices');
      if (ch = nil) or (ch.JSONType = jtNull) then Exit;
      if ch.JSONType <> jtArray then Exit;                       // indexing a non-array: jq error, nothing
      if TJSONArray(ch).Count = 0 then Exit;
      ch := TJSONArray(ch)[0];
      if ch.JSONType = jtNull then Exit;
      if ch.JSONType <> jtObject then Exit;
      dl := TJSONObject(ch).Find('delta');
      if (dl = nil) or (dl.JSONType = jtNull) then Exit;
      if dl.JSONType <> jtObject then Exit;
      c := TJSONObject(dl).Find('content');
      if Truthy(c) then piece := Rendered(c);
    end
    else
    begin
      // jq -j '.message.content // (if .error then "[ollama: " + .error + "]" else empty end)'
      m := TJSONObject(d).Find('message');
      c := nil;
      if (m <> nil) and (m.JSONType <> jtNull) then
      begin
        if m.JSONType <> jtObject then Exit;                     // .content on a non-object: jq error, nothing
        c := TJSONObject(m).Find('content');
      end;
      if Truthy(c) then piece := Rendered(c)
      else
      begin
        e := TJSONObject(d).Find('error');
        if Truthy(e) then
        begin
          if e.JSONType <> jtString then Exit;                   // "..." + non-string: jq error, nothing
          piece := '[ollama: ' + e.AsString + ']';
        end;
      end;
    end;
  finally
    d.Free;
  end;
  if piece <> '' then Out.WriteBuffer(piece[1], Length(piece));    // written at once: the page polls this file
end;

function RunLocalChat(const O: TLocalChatOptions; out Msg: string): Integer;
var
  sysTxt, userTxt, histTxt, payloadPretty, payloadJson, url, tagsBody: string;
  root, sysMsg, userMsg: TJSONObject;
  msgs: TJSONArray;
  hist, tags, models: TJSONData;
  i: Integer;
  found: Boolean;
  nm: string;
  lc: TLocalChat;
  rr: TProcResult;
  args: TStringList;
  pr: THttpResult;
begin
  Msg := ''; Result := 0;
  if not FileExists(O.SystemFile) then begin Msg := 'system prompt file not found'; Exit(2); end;
  if not FileExists(O.UserFile) then begin Msg := 'user prompt file not found'; Exit(2); end;
  sysTxt := Utf8Scrub(ReadWhole(O.SystemFile));                    // --rawfile: the text as it is, trailing newline kept
  userTxt := Utf8Scrub(ReadWhole(O.UserFile));
  if O.HistoryFile <> '' then histTxt := ReadWhole(O.HistoryFile) else histTxt := '[]';
  try
    hist := GetJSON(histTxt);                                      // --argjson: must be valid JSON ...
  except
    Msg := 'history is not valid JSON'; Exit(2);
  end;
  if hist.JSONType <> jtArray then begin hist.Free; Msg := 'history is not a JSON array'; Exit(2); end;   // ... and an array ([...] + $hist)
  root := TJSONObject.Create;
  try
    root.Add('model', Utf8Scrub(O.Model));
    root.Add('stream', True);
    msgs := TJSONArray.Create;
    sysMsg := TJSONObject.Create; sysMsg.Add('role', 'system'); sysMsg.Add('content', sysTxt); msgs.Add(sysMsg);
    for i := 0 to TJSONArray(hist).Count - 1 do msgs.Add(TJSONArray(hist)[i].Clone);
    userMsg := TJSONObject.Create; userMsg.Add('role', 'user'); userMsg.Add('content', userTxt); msgs.Add(userMsg);
    root.Add('messages', msgs);
    payloadPretty := JqPretty(root, 0);
    payloadJson := root.AsJSON;
  finally
    root.Free; hist.Free;
  end;
  WriteWhole(O.OutFile + '.payload', payloadPretty);               // printf '%s' "$OLLAMA_PAYLOAD" > "$OUT_FILE.payload"
  WriteWhole(O.OutFile + '.err', '');                              // 2>>"$OUT_FILE.err" creates it
  // an Ollama model that was never pulled answers {"error":"model not found"}: pull it first (the tags list is the truth)
  if O.Style <> 'openai' then
  begin
    found := False;
    if HttpGetStatus(O.Base + '/api/tags', 5000, tagsBody) = 200 then
    begin
      try
        tags := GetJSON(tagsBody);
        try
          if tags.JSONType = jtObject then
          begin
            models := TJSONObject(tags).Find('models');
            if (models <> nil) and (models.JSONType = jtArray) then
              for i := 0 to TJSONArray(models).Count - 1 do
                if TJSONArray(models)[i].JSONType = jtObject then
                begin
                  nm := '';
                  if (TJSONObject(TJSONArray(models)[i]).Find('name') <> nil) and (TJSONObject(TJSONArray(models)[i]).Find('name').JSONType = jtString) then
                    nm := TJSONObject(TJSONArray(models)[i]).Find('name').AsString;
                  if (nm = O.Model) or (nm = O.Model + ':latest') then found := True;
                end;
          end;
        finally
          tags.Free;
        end;
      except
        found := False;
      end;
    end;
    if not found then
    begin
      WriteLn('[', O.AgentUc, '] pulling ', O.Model, ' (first use) …');
      Flush(Output);
      args := TStringList.Create;
      try
        args.Add('pull'); args.Add(O.Model);
        rr := RunProcess('ollama', args, '', nil, '', 0, 0, nil, nil);   // output discarded; a failure is not an error here
      finally
        args.Free;
      end;
    end;
  end;
  if O.Style = 'openai' then url := O.Base + '/v1/chat/completions' else url := O.Base + '/api/chat';
  lc := TLocalChat.Create;
  try
    lc.Style := O.Style;
    lc.Out := TFileStream.Create(O.OutFile, fmCreate);              // `done > "$OUT_FILE"` truncates when the pipeline starts
    try
      pr := HttpStreamPost(url, payloadJson, O.TimeoutS, @lc.OnLine, @lc.IsCancelled, nil, True);
    finally
      lc.Out.Free;
    end;
  finally
    lc.Free;
  end;
  if pr.Cancelled then Result := 130;
end;

{ ---- the run ------------------------------------------------------------------------------------- }

type
  TLegacyRun = class
    Out: TFileStream;
    Captured, ErrCap: string;      // claude_json mode: stdout is held to be parsed, stderr kept apart
    JsonMode: Boolean;
    function IsCancelled: Boolean;
    procedure OnChunk(const Data: string; IsStderr: Boolean);
  end;

function TLegacyRun.IsCancelled: Boolean;
begin
  Result := LegacyCancel;
end;

procedure TLegacyRun.OnChunk(const Data: string; IsStderr: Boolean);
begin
  if JsonMode then
  begin
    if IsStderr then ErrCap := ErrCap + Data else Captured := Captured + Data;
  end
  else if Data <> '' then Out.WriteBuffer(Data[1], Length(Data));       // straight into the file: the poller sees it grow
end;

function RunLegacy(const O: TLegacyOptions; out Msg: string): Integer;
var
  exe, parseMode, errLabel, reason, res, cur: string;
  args, env: TStringList;
  rr: TProcResult;
  run: TLegacyRun;
  json: Boolean;
begin
  Msg := '';
  args := TStringList.Create; env := TStringList.Create;
  try
    reason := LegacyBuildCommand(O, exe, args, env, parseMode, errLabel);
    if reason <> '' then begin Msg := reason; Exit(2); end;
    json := parseMode = 'claude_json';
    if (O.Supplier = 'opencode') and (O.ClaudeModel = '') then EnsureOpencodeProvider(GetEnvironmentVariable('HOME'), O.RawModel, O.LocalBase);
    run := TLegacyRun.Create;
    try
      run.JsonMode := json;
      // OUT_FILE is pre-created empty by the loop; opening it for append keeps whatever is there
      if FileExists(O.OutFile) then run.Out := TFileStream.Create(O.OutFile, fmOpenReadWrite or fmShareDenyNone)
      else run.Out := TFileStream.Create(O.OutFile, fmCreate);
      run.Out.Seek(0, soEnd);
      try
        rr := RunProcess(exe, args, O.Cwd, env, '', O.TimeoutS, 0, nil, @run.IsCancelled, @run.OnChunk, not json);
        if not rr.Started then
        begin
          Msg := rr.StartError;
          if not json then
          begin
            cur := '[' + errLabel + ' ERROR] CLI failed or not installed — check ~/scripts/cockpit_data/cli_catalog.json.' + #10;
            run.Out.WriteBuffer(cur[1], Length(cur));
          end;
          Exit(127);
        end;
        if json then
        begin
          res := LegacyClaudeResult(run.Captured);
          if res <> '' then run.Out.WriteBuffer(res[1], Length(res))
          else if run.ErrCap <> '' then
          begin
            cur := Copy(run.ErrCap, 1, 2000);                    // "head -c 2000": the response is never silently empty
            run.Out.WriteBuffer(cur[1], Length(cur));
          end;
        end
        else if (rr.ExitCode <> 0) or rr.Cancelled or rr.TimedOut then
        begin
          cur := '[' + errLabel + ' ERROR] CLI failed or not installed — check ~/scripts/cockpit_data/cli_catalog.json.' + #10;
          run.Out.WriteBuffer(cur[1], Length(cur));
        end;
      finally
        run.Out.Free;
      end;
      if (not json) and (O.Supplier = 'opencode') then
        WriteWhole(O.OutFile, LegacyOpencodeStrip(ReadWhole(O.OutFile)));
      if rr.Cancelled then Result := 130
      else if rr.TimedOut then Result := 124
      else Result := rr.ExitCode;
    finally
      run.Free;
    end;
  finally
    args.Free; env.Free;
  end;
end;

{ ---- the Gemini REST branch ---------------------------------------------------------------------------- }

{ what `jq -r` prints for a value: a string raw, null/false... as the caller decides, everything else as compact JSON }
function JqRawText(D: TJSONData): string;
begin
  if D = nil then Exit('');
  if D.JSONType = jtString then Result := D.AsString else Result := D.AsJSON;
end;

function JqTruthy(D: TJSONData): Boolean;
begin
  Result := (D <> nil) and (D.JSONType <> jtNull) and not ((D.JSONType = jtBoolean) and not D.AsBoolean);
end;

procedure AppendWhole(const F, Data: string);
var
  fs: TFileStream;
begin
  if Data = '' then Exit;
  if FileExists(F) then begin fs := TFileStream.Create(F, fmOpenWrite or fmShareDenyNone); fs.Seek(0, soEnd); end
  else fs := TFileStream.Create(F, fmCreate);
  try
    fs.WriteBuffer(Data[1], Length(Data));
  finally
    fs.Free;
  end;
end;

{ the file's size: the Bash tests  [ ! -s "$OUT_FILE" ]  on the whole file, not on what this call wrote }
function FileSizeOf(const F: string): Int64;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(F, faAnyFile, sr) = 0 then begin Result := sr.Size; FindClose(sr); end;
end;

function RunGemini(const O: TGeminiOptions; out Msg: string): Integer;
var
  key, prompt, payload, url, outTxt, reason: string;
  root, contents, parts, part, txt: TJSONObject;
  arr: TJSONArray;
  hdrs: TStringList;
  res: THttpsResult;
  d: TJSONData;
  cands, c0, content, prs, el, tx: TJSONData;
  i: Integer;
  jqFail: Boolean;
begin
  Msg := ''; Result := 0;
  key := GetEnvironmentVariable('GEMINI_API_KEY');
  if key = '' then begin Msg := 'no API key (GEMINI_API_KEY)'; Exit(2); end;
  if not FileExists(O.PromptFile) then begin Msg := 'prompt file not found'; Exit(2); end;
  if O.OutFile = '' then begin Msg := 'no output file'; Exit(2); end;
  prompt := Utf8Scrub(ReadWhole(O.PromptFile));                    // jq --rawfile: the text as it is
  txt := TJSONObject.Create; txt.Add('text', prompt);
  parts := TJSONObject.Create;
  arr := TJSONArray.Create; arr.Add(txt);
  parts.Add('parts', arr);
  contents := TJSONObject.Create;
  arr := TJSONArray.Create; arr.Add(parts);
  contents.Add('contents', arr);
  payload := contents.AsJSON;
  contents.Free;
  url := O.Base + '/v1beta/models/' + O.Model + ':generateContent';
  hdrs := TStringList.Create;
  try
    hdrs.Add('Content-Type: application/json');
    hdrs.Add('x-goog-api-key: ' + key);                            // a header, not ?key=: the key stays out of every log and out of ps
    res := HttpsRequest('POST', url, payload, hdrs, O.TimeoutS, O.CaFile, O.ResolveIp);
  finally
    hdrs.Free;
  end;
  if not res.Ok then
  begin
    // Bash: curl prints nothing, jq prints nothing, and the file gets "[GEMINI ERROR] " with no reason. Here the reason is said.
    AppendWhole(O.OutFile, '[GEMINI ERROR] ' + res.Err + #10);
    Exit(0);
  end;
  // ---- the parsing, step for step what the jq program does ----
  outTxt := ''; root := nil; d := nil;
  try
    try d := GetJSON(res.Body); except d := nil; end;
    if d = nil then begin outTxt := ''; end                         // not JSON (or empty): jq prints nothing
    else if d.JSONType = jtNull then outTxt := '[GEMINI ERROR] no response' + #10
    else if d.JSONType <> jtObject then outTxt := ''               // an array / string / number: ".candidates" is a jq error
    else
    begin
      root := TJSONObject(d);
      cands := root.Find('candidates');
      if JqTruthy(cands) then
      begin
        // .candidates[0].content.parts[]?.text // ""
        jqFail := False;
        if cands.JSONType = jtArray then
        begin
          if TJSONArray(cands).Count > 0 then c0 := TJSONArray(cands)[0] else c0 := nil;
          if (c0 <> nil) and (c0.JSONType = jtObject) then
          begin
            content := TJSONObject(c0).Find('content');
            if (content <> nil) and (content.JSONType = jtObject) then
            begin
              prs := TJSONObject(content).Find('parts');
              if (prs <> nil) and (prs.JSONType = jtArray) then
                for i := 0 to TJSONArray(prs).Count - 1 do
                begin
                  el := TJSONArray(prs)[i];
                  if el.JSONType <> jtObject then begin jqFail := True; Break; end;       // ".text" of a non-object: jq stops
                  tx := TJSONObject(el).Find('text');
                  if JqTruthy(tx) then outTxt := outTxt + JqRawText(tx) + #10;       // '// empty': a part without text prints nothing
                end;
            end;
          end;
        end;
      end
      else
      begin
        // "[GEMINI ERROR] " + (.error.message // "no response")
        d := root.Find('error');
        if (d <> nil) and (d.JSONType = jtObject) then d := TJSONObject(d).Find('message') else d := nil;
        if not JqTruthy(d) then outTxt := '[GEMINI ERROR] no response' + #10
        else if d.JSONType = jtString then outTxt := '[GEMINI ERROR] ' + d.AsString + #10
        else outTxt := '';                                          // string + number: a jq error, nothing printed
      end;
    end;
    AppendWhole(O.OutFile, outTxt);
    if FileSizeOf(O.OutFile) = 0 then
    begin
      // empty (a safety block, no parts ...): say why. .candidates[0].finishReason // "empty response"; a jq error there gives "" 
      reason := '';
      if (root <> nil) then
      begin
        cands := root.Find('candidates');
        if (cands <> nil) and (cands.JSONType = jtArray) then
        begin
          if TJSONArray(cands).Count = 0 then reason := 'empty response'
          else if TJSONArray(cands)[0].JSONType = jtNull then reason := 'empty response'
          else if TJSONArray(cands)[0].JSONType = jtObject then
          begin
            tx := TJSONObject(TJSONArray(cands)[0]).Find('finishReason');
            if JqTruthy(tx) then reason := JqRawText(tx) else reason := 'empty response';
          end;
        end
        else if not JqTruthy(cands) then reason := 'empty response';
      end
      else if (d <> nil) and (d.JSONType = jtNull) then reason := 'empty response';
      AppendWhole(O.OutFile, '[GEMINI ERROR] ' + reason + #10);
    end;
  finally
    if root <> nil then root.Free else if d <> nil then d.Free;
  end;
end;

{ ---- prompt assembly ------------------------------------------------------------------------------------ }

{ `head -c N`: the first N BYTES (a multi-byte character may be cut, as it is in the Bash) }
function HeadBytes(const S: string; N: Integer): string;
begin
  if Length(S) <= N then Result := S else Result := Copy(S, 1, N);
end;

function FileLen(const F: string): Int64;
begin
  Result := FileSizeOf(F);
end;

function NonEmptyFile(const F: string): Boolean;
begin
  Result := (F <> '') and FileExists(F) and (FileSizeOf(F) > 0);
end;

{ a JSON file's top-level object, or nil (missing / not valid JSON / not an object): what jq would fail on prints nothing }
function LoadObj(const F: string): TJSONObject;
var
  d: TJSONData;
begin
  Result := nil;
  if not FileExists(F) then Exit;
  try d := GetJSON(ReadWhole(F)); except Exit; end;
  if (d <> nil) and (d.JSONType = jtObject) then Result := TJSONObject(d) else d.Free;
end;

{ `jq -r 'KEY // empty'` followed by `head -c N` and `$(...)`: the value as text (strings raw, other values as jq prints them), cut to
  N bytes counting the newline jq adds, trailing newlines gone. '' when the key is missing, null or false. }
function JqKeyHead(O: TJSONObject; const Key: string; N: Integer): string;
var
  v: TJSONData;
begin
  Result := '';
  if O = nil then Exit;
  v := O.Find(Key);
  if not JqTruthy(v) then Exit;
  if v.JSONType = jtString then Result := Utf8Scrub(v.AsString) else Result := JqPretty(v, 0);
  Result := CommandSubstitution(HeadBytes(Result + #10, N));
end;

function JoinBlock(const Cur, Block: string): string;
begin
  if Cur = '' then Result := Block else Result := Cur + #10 + Block;
end;

function AsciiSlug(const S: string): string;      // tr 'A-Z ' 'a-z_'
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then Result[i] := Chr(Ord(Result[i]) + 32)
    else if Result[i] = ' ' then Result[i] := '_';
end;

function GlobMatch(const Pat, S: string): Boolean;   // only the shapes the case table uses: exact, *infix*
begin
  if (Length(Pat) > 2) and (Pat[1] = '*') and (Pat[Length(Pat)] = '*') then Result := Pos(Copy(Pat, 2, Length(Pat) - 2), S) > 0
  else Result := Pat = S;
end;

function RunPrompt(const O: TPromptOptions; out Msg: string): Integer;
var
  userTxt, histTxt, ragTxt, workersTxt, toolsTxt, capsTxt, crudTxt, styleTxt: string;
  goalBlock, mdBlock, profileBlock, dirBlock, identity, provider, imodel: string;
  goal, note, nm, d, content, src, cfgEnabled, compactList, w: string;
  chatF, projF, kindF, f: string;
  chatO, kindO, projO, cfgO: TJSONObject;
  v: TJSONData;
  i: Integer;
  enabled, useCompact: Boolean;
  parts: TStringList;
  sysBuf, outBuf: string;
  open_, close_: string;

  procedure Blk(var Buf: string; const B: string);          // echo ""; echo "$BLOCK"
  begin
    if B <> '' then Buf := Buf + #10 + B + #10;
  end;
  function Tag(const Name: string; Closing: Boolean): string;
  begin
    if O.PromptStyle <> 'xml' then Exit('');
    if Closing then Result := '</' + Name + '>' + #10 else Result := '<' + Name + '>' + #10;
  end;
begin
  Msg := ''; Result := 0;
  if not FileExists(O.UserFile) then begin Msg := 'user prompt file not found'; Exit(2); end;
  if (O.OutFile = '') then begin Msg := 'no output file'; Exit(2); end;
  userTxt := ReadWhole(O.UserFile);
  if NonEmptyFile(O.HistoryFile) then histTxt := ReadWhole(O.HistoryFile) else histTxt := '';
  if NonEmptyFile(O.RagFile) then ragTxt := ReadWhole(O.RagFile) else ragTxt := '';
  if NonEmptyFile(O.WorkersFile) then workersTxt := ReadWhole(O.WorkersFile) else workersTxt := '';
  if NonEmptyFile(O.ToolsFile) then toolsTxt := ReadWhole(O.ToolsFile) else toolsTxt := '';
  if NonEmptyFile(O.CapsFile) then capsTxt := ReadWhole(O.CapsFile) else capsTxt := '';
  if NonEmptyFile(O.CrudFile) then crudTxt := ReadWhole(O.CrudFile) else crudTxt := '';
  if NonEmptyFile(O.StyleFile) then styleTxt := ReadWhole(O.StyleFile) else styleTxt := '';
  if (O.Agent = 'claude') and (styleTxt = '') then begin Msg := 'style guide file missing'; Exit(2); end;
  if (O.Agent <> 'claude') and (crudTxt = '') then begin Msg := 'CRUD system prompt file missing'; Exit(2); end;
  if (O.Agent <> 'claude') and (O.SysOutFile = '') then begin Msg := 'no system output file'; Exit(2); end;

  // ---- goal, kind, descriptions ------------------------------------------------------------------------------------------
  goalBlock := '';
  chatF := IncludeTrailingPathDelimiter(O.ProjectDir) + '.chat_meta/' + AsciiSlug(O.ChatName) + '.json';
  projF := IncludeTrailingPathDelimiter(O.ProjectDir) + '.cockpit_project.json';
  chatO := LoadObj(chatF);
  projO := nil; kindO := nil;
  try
    goal := '';
    if FileExists(chatF) then goal := JqKeyHead(chatO, 'goal', 600);
    if O.Project = '_standalone' then begin kindF := chatF; kindO := chatO; end
    else
    begin
      kindF := projF; projO := LoadObj(projF); kindO := projO;
      if (goal = '') and FileExists(projF) then goal := JqKeyHead(projO, 'goal', 600);
    end;
    if goal <> '' then goalBlock := '[Project goal] ' + goal;
    note := ''; nm := '';
    if FileExists(kindF) then
    begin
      note := JqKeyHead(kindO, 'kind_note', 900);
      nm := '';
      if kindO <> nil then
      begin
        v := kindO.Find('kind_name');
        if not JqTruthy(v) then v := kindO.Find('kind');
        if JqTruthy(v) then
        begin
          if v.JSONType = jtString then nm := Utf8Scrub(v.AsString) else nm := JqPretty(v, 0);
          nm := CommandSubstitution(HeadBytes(nm + #10, 60));
        end;
      end;
    end;
    if note <> '' then goalBlock := JoinBlock(goalBlock, '[Project kind: ' + nm + '] ' + note);
    // descriptions: only where the person switched "also send to the agent" on (desc_send must be the boolean true)
    if FileExists(chatF) and (chatO <> nil) then
    begin
      v := chatO.Find('desc_send');
      if (v <> nil) and (v.JSONType = jtBoolean) and v.AsBoolean then
      begin
        d := JqKeyHead(chatO, 'description', 300);
        if d <> '' then goalBlock := JoinBlock(goalBlock, '[Chat description] ' + d);
      end;
    end;
    if (O.Project <> '_standalone') and FileExists(projF) and (projO <> nil) then
    begin
      v := projO.Find('desc_send');
      if (v <> nil) and (v.JSONType = jtBoolean) and v.AsBoolean then
      begin
        d := JqKeyHead(projO, 'description', 300);
        if d <> '' then goalBlock := JoinBlock(goalBlock, '[Project description] ' + d);
      end;
    end;
  finally
    if chatO <> nil then chatO.Free;
    if projO <> nil then projO.Free;
  end;

  // ---- COCKPIT.md ------------------------------------------------------------------------------------------------------------
  mdBlock := '';
  f := IncludeTrailingPathDelimiter(O.ProjectDir) + 'COCKPIT.md';
  if FileExists(f) then
  begin
    content := CommandSubstitution(HeadBytes(ReadWhole(f), 8192));
    if FileLen(f) > 8192 then content := content + #10 + '[... COCKPIT.md truncated at 8 KB]';
    mdBlock := '[Project context — from COCKPIT.md]' + #10 + content + #10 + '[End project context]';
  end;

  // ---- profile ---------------------------------------------------------------------------------------------------------------
  profileBlock := '';
  f := IncludeTrailingPathDelimiter(O.DataDir) + 'profile.md';
  if NonEmptyFile(f) and not FileExists(IncludeTrailingPathDelimiter(O.DataDir) + 'profile_enabled') then
  begin
    content := CommandSubstitution(HeadBytes(ReadWhole(f), 4096));
    if content <> '' then profileBlock := '[About the person you are working with]' + #10 + content + #10 + '[End profile]';
  end;

  // ---- global directives -----------------------------------------------------------------------------------------------------
  dirBlock := '';
  enabled := True; compactList := '';
  f := IncludeTrailingPathDelimiter(O.DataDir) + 'directives_config.json';
  if FileExists(f) then
  begin
    cfgO := nil; v := nil;
    try v := GetJSON(ReadWhole(f)); except v := nil; end;
    // jq: invalid JSON or a non-object (other than null) prints nothing, and "" is not "true": directives are off in that case
    if v = nil then enabled := False
    else if v.JSONType = jtNull then begin enabled := True; end
    else if v.JSONType <> jtObject then enabled := False
    else
    begin
      cfgO := TJSONObject(v);
      d := '';
      enabled := True;
      w := '';
      if (cfgO.Find('enabled') <> nil) and (cfgO.Find('enabled').JSONType = jtBoolean) and not cfgO.Find('enabled').AsBoolean then enabled := False;
      // (.compact_suppliers // []) | join(" "): strings, numbers and booleans are joined, null is empty; anything else is a jq error = ''
      v := cfgO.Find('compact_suppliers');
      if JqTruthy(v) then
      begin
        if v.JSONType = jtArray then
        begin
          for i := 0 to TJSONArray(v).Count - 1 do
          begin
            case TJSONArray(v)[i].JSONType of
              jtString: w := w + TJSONArray(v)[i].AsString;
              jtNumber, jtBoolean: w := w + TJSONArray(v)[i].AsJSON;
              jtNull: ;
            else begin w := ''; compactList := ''; Break; end;
            end;
            if i < TJSONArray(v).Count - 1 then w := w + ' ';
          end;
          compactList := w;
        end;
      end;
    end;
    if cfgO <> nil then cfgO.Free else if v <> nil then v.Free;
  end;
  if enabled then
  begin
    useCompact := False;
    parts := LegacySplitWords(compactList);
    try
      for i := 0 to parts.Count - 1 do if parts[i] = O.Agent then useCompact := True;
    finally
      parts.Free;
    end;
    src := IncludeTrailingPathDelimiter(O.DataDir) + 'directives_global.md';
    f := IncludeTrailingPathDelimiter(O.DataDir) + 'directives_' + O.Agent + '.md';
    if NonEmptyFile(f) then src := f
    else if useCompact and NonEmptyFile(IncludeTrailingPathDelimiter(O.DataDir) + 'directives_global_compact.md') then
      src := IncludeTrailingPathDelimiter(O.DataDir) + 'directives_global_compact.md';
    if NonEmptyFile(src) then
    begin
      content := CommandSubstitution(HeadBytes(ReadWhole(src), 8192));
      dirBlock := '[Global directives — always apply]' + #10 + content + #10 + '[End global directives]';
    end;
  end;

  // ---- identity line -----------------------------------------------------------------------------------------------------------
  if O.Agent = 'claude' then begin provider := 'Anthropic Claude'; imodel := O.ClaudeModel; end
  else if O.Agent = 'gemini' then
  begin
    imodel := O.GeminiModel;
    if (O.CliSupplier = '') or (O.CliSupplier = 'gemini') then provider := 'Google Gemini'
    else if (O.CliSupplier = 'groq_build') or (O.CliSupplier = 'groq') then provider := 'Groq'
    else if GlobMatch('*huggingface*', O.CliSupplier) or (O.CliSupplier = 'hf') then provider := 'HuggingFace'
    else if GlobMatch('*cloudflare*', O.CliSupplier) then provider := 'Cloudflare'
    else provider := O.CliSupplier;
  end
  else if O.Agent = 'ollama' then begin provider := 'a local Ollama model'; imodel := O.Model; end
  else begin provider := O.Agent; imodel := ''; end;
  if (imodel = 'auto') then imodel := '';
  identity := '[Identity] You are running inside AI Cockpit on ' + provider;
  if imodel <> '' then identity := identity + ' (model: ' + imodel + ')';
  identity := identity + '. If asked which model or company you are, answer truthfully with this; do not claim to be a different model or company.';

  // ---- the layout ---------------------------------------------------------------------------------------------------------------
  if O.Agent = 'claude' then
  begin
    outBuf := styleTxt + #10 + #10 + identity + #10;
    Blk(outBuf, dirBlock); Blk(outBuf, profileBlock); Blk(outBuf, goalBlock); Blk(outBuf, mdBlock);
    Blk(outBuf, workersTxt); Blk(outBuf, toolsTxt);
    outBuf := outBuf + #10;
    if histTxt <> '' then outBuf := outBuf + histTxt + #10 + #10;
    if ragTxt <> '' then outBuf := outBuf + Tag('context', False) + ragTxt + #10 + Tag('context', True) + #10;
    outBuf := outBuf + Tag('task', False) + userTxt + #10 + Tag('task', True);
    WriteWhole(O.OutFile, outBuf);
  end
  else
  begin
    sysBuf := crudTxt + #10 + #10 + identity + #10;
    Blk(sysBuf, dirBlock); Blk(sysBuf, profileBlock); Blk(sysBuf, goalBlock); Blk(sysBuf, mdBlock);
    if O.Agent = 'ollama' then Blk(sysBuf, capsTxt);
    Blk(sysBuf, workersTxt); Blk(sysBuf, toolsTxt);
    WriteWhole(O.SysOutFile, sysBuf);
    outBuf := sysBuf + #10;
    if histTxt <> '' then outBuf := outBuf + histTxt + #10 + #10;
    if ragTxt <> '' then outBuf := outBuf + Tag('context', False) + ragTxt + #10 + Tag('context', True) + #10;
    outBuf := outBuf + Tag('task', False) + 'User: ' + userTxt + #10 + Tag('task', True);
    WriteWhole(O.OutFile, outBuf);
  end;
end;

end.
