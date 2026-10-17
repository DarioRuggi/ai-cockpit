(* =============================================================================
  aic_loopmain — the agent queue loop of agent_loop.sh as a native program:   aicengine loop <claude|gemini|ollama>

  The same loop, step for step: watch the queue folder for  <agent>_prompt_<token>.txt, read the request's meta file, work out the supplier
  from the user's slots and the CLI catalog, apply the project's capabilities, assemble the prompt, run the agent (the Claude and generic CLIs,
  the Gemini REST call, the free-REST relay, the local Ollama / OpenAI-style server), clean the answer, carry out the %%markers%%, save the
  exchange into the chat file and write the .done file.

  It is built from the pieces the engine already has (intake, route, prompt, legacy, gemini, localchat, clean, signin-hint) and calls the same
  helpers the Bash calls when the engine is on:  history_cli.php (the history gate and renderer, saving the turn), crud_cli.php (the markers)
  and worker_relay.php (free-REST suppliers).  Differences from the Bash are listed in the README: it needs no jq / sed / bc / python3 / curl /
  coreutils; without PHP there is no history and the turn is saved by this program itself.
  tests/loop_native_test.sh in the Cockpit repo runs the real agent_loop.sh and this loop side by side on the same requests.
  ============================================================================= *)
unit aic_loopmain;

{$mode objfpc}{$H+}

interface

{ runs until killed; returns an exit code only for a start-up failure (or when another loop for this agent is alive: 0) }
function RunLoop(const Agent_: string): Integer;

implementation

uses
  SysUtils, Classes, BaseUnix, Unix, fpjson, jsonparser, RegExpr, aic_proc, aic_legacy, aic_post, aic_intake, aic_route, aic_history, aic_crud, aic_workers;

{$I aic_looptexts.inc}

type
  TCapture = class
    Data: string;
    procedure OnChunk(const D: string; IsStderr: Boolean);
  end;

procedure TCapture.OnChunk(const D: string; IsStderr: Boolean);
begin
  if IsStderr then begin Write(StdErr, D); Flush(StdErr); end      // the helper's own log lines go where the Bash's go: our stderr
  else Data := Data + D;
end;

var
  Agent, AgentUc, QueueDir, ResponseDir, DataDir, Home, ScriptsDir, CockpitRoot: string;
  // supplier (card 1 / 2)
  CliSupplier, CliBinary, CliCatalogFile, CliPromptStyle, CliRelay, CliHasBin: string;
  // card 3
  LocalProvider, LocalBase, LocalStyle: string;
  // per request
  Token, OutFile, DoneFile, Project, ChatName, ClaudeModel, GeminiModel, ClaudeEffort, GeminiEffort: string;
  ReqRoot, ReqData, ReqWeb, RagB64, MaStyle, MaMode, ReqImages, Model, ExtraCliArgs, ProjectDir, ChatFile, UserPrompt, History: string;
  WorkersPrompt, ToolsPrompt, CapsPrompt, DisplayModel, Duration: string;
  PromptTmp, SysTmp: string;
  OllamaPromptChars: Int64;

{ ---- small helpers ---------------------------------------------------------------------------------------------------------------- }

procedure Say(const S: string);
begin
  WriteLn(S); Flush(Output);
end;

procedure SayErr(const S: string);
begin
  WriteLn(StdErr, S); Flush(StdErr);
end;

function ReadWhole(const F: string): string;
var
  fs: TFileStream;
begin
  Result := '';
  if not FileExists(F) then Exit;
  try
    fs := TFileStream.Create(F, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(Result[1], fs.Size);
    finally
      fs.Free;
    end;
  except
    Result := '';
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

procedure AppendWhole(const F, Data: string);
var
  fs: TFileStream;
begin
  if FileExists(F) then begin fs := TFileStream.Create(F, fmOpenWrite or fmShareDenyNone); fs.Seek(0, soEnd); end
  else fs := TFileStream.Create(F, fmCreate);
  try
    if Data <> '' then fs.WriteBuffer(Data[1], Length(Data));
  finally
    fs.Free;
  end;
end;

function FileLen(const F: string): Int64;
var
  st: Stat;
begin
  if fpStat(F, st) <> 0 then Exit(0);
  Result := st.st_size;
end;

{ what $( ... ) does to a text: NULs dropped, trailing newlines removed }
function CmdSubst(const S: string): string;
var
  i, n: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do if S[i] <> #0 then Result := Result + S[i];
  n := Length(Result);
  while (n > 0) and (Result[n] = #10) do Dec(n);
  SetLength(Result, n);
end;

function StripSpaces(const S: string): string;      // tr -d '[:space:]'
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do if not (S[i] in [' ', #9, #10, #11, #12, #13]) then Result := Result + S[i];
end;

{ The process environment. System.envp is what the children of aic_proc (and GetEnvironmentVariable) read; it is rebuilt from GEnv, a list that is the one
  source of truth, after every change. (A first version resized the array it was copying from, read freed memory and lost variables after a few changes.) }
var
  GEnv: TStringList;
  GEnvArr: array of PChar;

procedure EnvInit;
var
  ep: PPChar;
begin
  if GEnv <> nil then Exit;
  GEnv := TStringList.Create;
  GEnv.CaseSensitive := True;
  ep := envp;
  while (ep <> nil) and (ep^ <> nil) do begin GEnv.Add(StrPas(ep^)); Inc(ep); end;
end;

procedure EnvPublish;
var
  i: Integer;
begin
  SetLength(GEnvArr, GEnv.Count + 1);
  for i := 0 to GEnv.Count - 1 do GEnvArr[i] := PChar(GEnv[i]);
  GEnvArr[GEnv.Count] := nil;
  envp := PPChar(@GEnvArr[0]);
end;

function EnvIndex(const Name: string): Integer;
var
  i: Integer;
begin
  for i := 0 to GEnv.Count - 1 do
    if Copy(GEnv[i], 1, Length(Name) + 1) = Name + '=' then Exit(i);
  Result := -1;
end;

procedure SetEnv(const Name, Value: string);
var
  i: Integer;
begin
  EnvInit;
  i := EnvIndex(Name);
  if i >= 0 then GEnv[i] := Name + '=' + Value else GEnv.Add(Name + '=' + Value);
  EnvPublish;
end;

procedure UnsetEnv(const Name: string);
var
  i: Integer;
begin
  EnvInit;
  i := EnvIndex(Name);
  if i >= 0 then begin GEnv.Delete(i); EnvPublish; end;
end;

function Env(const Name: string; const Def: string = ''): string;
begin
  Result := GetEnvironmentVariable(Name);
  if Result = '' then Result := Def;
end;

{ run a program, collect what it prints (stdout; stderr too when Merge, else it is passed on to ours); returns the exit code, -1 = could not start }
function Exec(const Exe: string; const Args: array of string; const StdinData: string; Merge: Boolean; out Output: string; Extra: TStrings = nil): Integer;
var
  a: TStringList;
  cap: TCapture;
  r: TProcResult;
  i: Integer;
begin
  Output := '';
  a := TStringList.Create; cap := TCapture.Create;
  try
    for i := 0 to High(Args) do a.Add(Args[i]);
    r := RunProcess(Exe, a, '', Extra, StdinData, 0, 0, nil, nil, @cap.OnChunk, Merge);
    Output := cap.Data;
    if not r.Started then Exit(-1);
    Result := r.ExitCode;
  finally
    a.Free; cap.Free;
  end;
end;

{ base64 -d of a text: decoding stops at the first character that is not part of the alphabet }
function B64Plain(const S: string): string;
const
  Alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  i, v, bits, acc: Integer;
begin
  Result := ''; acc := 0; bits := 0;
  for i := 1 to Length(S) do
  begin
    if S[i] = '=' then Break;
    v := Pos(S[i], Alpha) - 1;
    if v < 0 then Break;
    acc := (acc shl 6) or v; bits := bits + 6;
    if bits >= 8 then begin bits := bits - 8; Result := Result + Chr((acc shr bits) and $FF); acc := acc and ((1 shl bits) - 1); end;
  end;
end;

function Which(const Exe: string): string;
begin
  Result := FindInPath(Exe, Env('PATH'));
end;

function NowNs: Int64;
var
  tv: TTimeVal;
begin
  fpGetTimeOfDay(@tv, nil);
  Result := Int64(tv.tv_sec) * 1000000000 + Int64(tv.tv_usec) * 1000;
end;

function NowZulu: string;
var
  tv: TTimeVal;
begin
  fpGetTimeOfDay(@tv, nil);
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', EncodeDate(1970, 1, 1) + tv.tv_sec / 86400.0);
end;

function TempName(const Prefix: string): string;
begin
  Result := GetTempFileName('/tmp', Prefix);
end;

{ ---- jq-like reads of a JSON file --------------------------------------------------------------------------------------------------- }

function ParseFile(const F: string): TJSONData;
begin
  Result := nil;
  if not FileExists(F) then Exit;
  try
    Result := GetJSON(ReadWhole(F));
  except
    Result := nil;
  end;
end;

{ jq -r  <value> // <default>  for a value found by a key path: null / false / missing -> Def; string as is; other scalars as jq prints them }
function JqText(D: TJSONData; const Def: string): string;
begin
  if (D = nil) or (D.JSONType = jtNull) or ((D.JSONType = jtBoolean) and not D.AsBoolean) then Exit(Def);
  case D.JSONType of
    jtString: Result := D.AsString;
    jtBoolean: Result := 'true';
    jtNumber: Result := D.AsJSON;
  else Result := D.AsJSON;
  end;
end;

function Sub(D: TJSONData; const Key: string): TJSONData;
begin
  Result := nil;
  if (D <> nil) and (D.JSONType = jtObject) then Result := TJSONObject(D).Find(Key);
end;

{ ---- supplier slots ----------------------------------------------------------------------------------------------------------------- }

procedure ResolveSupplier(const D: string);
var
  slots, cat, ent: TJSONData;
  slotKey, catFile, c: string;
  cands: array[0..3] of string;
  ci: Integer;
begin
  CliSupplier := ''; CliBinary := ''; CliCatalogFile := ''; CliPromptStyle := 'plain'; CliRelay := ''; CliHasBin := '';
  if (Agent <> 'claude') and (Agent <> 'gemini') then Exit;
  if Agent = 'gemini' then slotKey := 'fallback' else slotKey := 'primary';
  slots := ParseFile(D + '/supplier_slots.json');
  try
    if slots <> nil then CliSupplier := JqText(Sub(slots, slotKey), '');
  finally
    slots.Free;
  end;
  if CliSupplier = '' then CliSupplier := Agent;
  catFile := '';
  cands[0] := D + '/cli_catalog.json'; cands[1] := DataDir + '/cli_catalog.json'; cands[2] := D + '/cli_suppliers.json'; cands[3] := DataDir + '/cli_suppliers.json';
  for ci := 0 to 3 do
    if FileExists(cands[ci]) then begin catFile := cands[ci]; Break; end;
  CliCatalogFile := catFile;
  if catFile <> '' then
  begin
    cat := ParseFile(catFile);
    try
      ent := Sub(cat, CliSupplier);
      CliBinary := JqText(Sub(ent, 'binary'), '');
      CliPromptStyle := JqText(Sub(ent, 'prompt_style'), 'plain');
      CliRelay := JqText(Sub(ent, 'relay'), '');
      CliHasBin := JqText(Sub(ent, 'binary'), '');
    finally
      cat.Free;
    end;
  end;
  if CliBinary = '' then CliBinary := CliSupplier;
  c := '';
end;

procedure ResolveLocal(const D: string);
var
  slots, a: TJSONData;
  p, b: string;
begin
  LocalProvider := 'ollama'; LocalBase := 'http://127.0.0.1:11434'; LocalStyle := 'ollama';
  slots := ParseFile(D + '/supplier_slots.json');
  try
    if slots = nil then Exit;
    a := Sub(Sub(slots, 'local'), 'provider');
    if (a = nil) or (a.JSONType = jtNull) or ((a.JSONType = jtBoolean) and not a.AsBoolean) then a := Sub(Sub(Sub(slots, 'slots'), 'local'), 'provider');
    p := JqText(a, '');
    a := Sub(Sub(slots, 'local'), 'base_url');
    if (a = nil) or (a.JSONType = jtNull) or ((a.JSONType = jtBoolean) and not a.AsBoolean) then a := Sub(Sub(Sub(slots, 'slots'), 'local'), 'base_url');
    b := JqText(a, '');
    if p <> '' then LocalProvider := p;
    if b <> '' then begin LocalBase := b; if LocalBase[Length(LocalBase)] = '/' then SetLength(LocalBase, Length(LocalBase) - 1); end;
    if (LocalProvider = 'ollama') or (LocalProvider = 'dual') then LocalStyle := 'ollama' else LocalStyle := 'openai';
  finally
    slots.Free;
  end;
end;

{ ---- the Claude CLI's private config folder ------------------------------------------------------------------------------------------ }

procedure CliIsolate;
var
  caps, cj, dir, credsReal, credsIso, cjf: string;
  d: TJSONData;
  inherit: Boolean;
  dirs: array[0..1] of string;
  i: Integer;
  root, projs: TJSONData;
begin
  inherit := False;
  d := ParseFile(ReqData + '/capabilities/global_caps.json');
  try
    if (d <> nil) and (d.JSONType = jtObject) then
    begin
      caps := JqText(Sub(d, 'inherit_cli_config'), 'false');
      inherit := caps = 'true';
    end;
  finally
    d.Free;
  end;
  if inherit then begin UnsetEnv('CLAUDE_CONFIG_DIR'); Exit; end;
  if ReqData <> '' then dir := ReqData + '/cli_config/claude' else dir := Home + '/.cockpit/cli_config/claude';
  if not ForceDirectories(dir) then begin UnsetEnv('CLAUDE_CONFIG_DIR'); Exit; end;
  credsReal := Home + '/.claude/.credentials.json'; credsIso := dir + '/.credentials.json';
  if FileExists(credsReal) and (not FileExists(credsIso)) then begin fpUnlink(credsIso); fpSymlink(PChar(credsReal), PChar(credsIso)); end;
  if FileExists(credsIso) and (fpReadLink(credsIso) = '') then fpChmod(credsIso, &600);
  if not FileExists(dir + '/settings.json') then WriteWhole(dir + '/settings.json', '{}' + #10);
  cjf := dir + '/.claude.json';
  if not FileExists(cjf) then WriteWhole(cjf, '{"projects":{}}' + #10);
  dirs[0] := ProjectDir; dirs[1] := CockpitRoot;
  for i := 0 to 1 do
  begin
    if dirs[i] = '' then Continue;
    cj := ReadWhole(cjf);
    if Pos('"' + dirs[i] + '"', cj) > 0 then Continue;
    root := ParseFile(cjf);
    try
      if (root <> nil) and (root.JSONType = jtObject) then
      begin
        projs := TJSONObject(root).Find('projects');
        if (projs = nil) or (projs.JSONType <> jtObject) then
        begin
          if projs <> nil then TJSONObject(root).Delete('projects');
          TJSONObject(root).Add('projects', TJSONObject.Create);
          projs := TJSONObject(root).Find('projects');
        end;
        if TJSONObject(projs).Find(dirs[i]) = nil then TJSONObject(projs).Add(dirs[i], TJSONObject.Create);
        if TJSONObject(projs).Objects[dirs[i]].Find('hasTrustDialogAccepted') <> nil then TJSONObject(projs).Objects[dirs[i]].Delete('hasTrustDialogAccepted');
        TJSONObject(projs).Objects[dirs[i]].Add('hasTrustDialogAccepted', True);
        WriteWhole(cjf, root.FormatJSON([], 2) + #10);
      end;
    finally
      root.Free;
    end;
  end;
  SetEnv('CLAUDE_CONFIG_DIR', dir);
end;

{ ---- the internal key for the marker calls (cockpit_app/internal_auth.php) ------------------------------------------------------------- }

procedure InternalSetup;
var
  kf, key, login, p: string;
  i: Integer;
  fs: TFileStream;
  buf: array[0..31] of Byte;
begin
  UnsetEnv('COCKPIT_INTERNAL_KEY'); UnsetEnv('COCKPIT_INTERNAL_USER');
  p := QueueDir;
  if (Length(p) >= 6) and (Copy(p, Length(p) - 5, 6) = '/queue') then SetLength(p, Length(p) - 6);
  SetEnv('COCKPIT_BASE_URL', 'http://localhost/' + ExtractFileName(p));
  if (DataDir = '') or not DirectoryExists(DataDir) then Exit;
  kf := DataDir + '/internal_key';
  if FileLen(kf) = 0 then
  begin
    try
      fs := TFileStream.Create('/dev/urandom', fmOpenRead);
      try fs.ReadBuffer(buf, SizeOf(buf)); finally fs.Free; end;
      key := '';
      for i := 0 to 31 do key := key + LowerCase(IntToHex(buf[i], 2));
      WriteWhole(kf + '.new', key);
      fpChmod(kf + '.new', &640);
      fpRename(PChar(kf + '.new'), PChar(kf));
    except
    end;
  end;
  if FileLen(kf) = 0 then Exit;
  i := Pos('/users/', ReqData);
  login := '';
  if i > 0 then
  begin
    login := Copy(ReqData, i + 7, MaxInt);
    if Pos('/', login) > 0 then login := Copy(login, 1, Pos('/', login) - 1);
  end;
  if login = '' then Exit;
  for i := 1 to Length(login) do if not (login[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then Exit;
  SetEnv('COCKPIT_INTERNAL_KEY', StripSpaces(ReadWhole(kf)));
  SetEnv('COCKPIT_INTERNAL_USER', login);
end;

{ ---- history, through the PHP helper --------------------------------------------------------------------------------------------------- }

function HistoryHelper: string;
begin
  Result := ScriptsDir + '/history_cli.php';
  if (not FileExists(Result)) or (Which('php') = '') then Result := '';
end;

function HistoryMode: string;
var
  m: string;
begin
  m := Env('COCKPIT_HISTORY_MODE', 'auto');
  if (m = 'inline') or (m = 'pointer') then Exit(m);
  if (Agent = 'claude') and ((CliSupplier = 'claude') or (CliSupplier = '')) then Result := 'pointer' else Result := 'inline';
end;

{ The history is done IN this process by aic_history (the same SQLite index and the same results as history_cli.php, proven on 1,700 cases). When it refuses
  (exit 9: invalid UTF-8, a character it does not know, a chat file that is not strict JSON) the PHP helper does it, if there is one. }
function PhpHistory(const Sub: string; const Args: array of string; const StdinData: string; out OutS, ErrS: string): Integer;
var
  h: string;
  i: Integer;
  cap: TCapture;
  p: TStringList;
  r: TProcResult;
begin
  OutS := ''; ErrS := ''; Result := 127;
  h := HistoryHelper;
  if h = '' then Exit;
  p := TStringList.Create; cap := TCapture.Create;
  try
    p.Add(h); p.Add(Sub);
    for i := 0 to High(Args) do p.Add(Args[i]);
    r := RunProcess(Which('php'), p, '', nil, StdinData, 0, 0, nil, nil, @cap.OnChunk, False);   // stderr goes to ours inside TCapture
    OutS := cap.Data;
    if r.Started then Result := r.ExitCode;
  finally
    p.Free; cap.Free;
  end;
end;

function RunHistory(const Sub: string; const Args: array of string; const StdinData: string; out OutS: string): Integer;
var
  e: string;
begin
  Result := HistoryRun(Sub, Args, StdinData, OutS, e);
  if Result = HISTORY_REFUSED then
  begin
    Result := PhpHistory(Sub, Args, StdinData, OutS, e);       // PHP's stderr already went to ours
    if Result = 127 then          // no PHP helper either: needs = include the history; build = none; append = wrote nothing, the caller saves the turn itself
    begin
      OutS := '';
      if Sub = 'append' then Result := 3 else Result := 0;
    end;
    Exit;
  end;
  if e <> '' then begin Write(StdErr, e); Flush(StdErr); end;
end;

function NeedsHistory(const P: string): Boolean;
var
  o: string;
  rc: Integer;
begin
  rc := RunHistory('needs', ['--agent', AgentUc], P, o);
  if o <> '' then begin Write(o); Flush(Output); end;
  Result := rc = 0;
end;

function BuildHistory(const P, Fmt: string): string;
var
  o: string;
begin
  RunHistory('build', ['--chat', ChatFile, '--format', Fmt, '--mode', HistoryMode, '--agent', AgentUc], P, o);
  Result := CmdSubst(o);
end;

{ ---- saving the turn --------------------------------------------------------------------------------------------------------------------- }

function JsonStrEsc(const S: string): string;
begin
  Result := S;
end;

procedure NativeAppend(const UserText, AgentText: string);
var
  root, ex, o: TJSONData;
  arr: TJSONArray;
  obj: TJSONObject;
  nextId, i: Integer;
  now_, sup: string;
  durNum: Double;
  lockFd: cint;
  lockPath: string;
begin
  lockPath := ChatFile + '.lock';
  lockFd := fpOpen(PChar(lockPath), O_WRONLY or O_CREAT, &664);
  if lockFd >= 0 then fpFlock(lockFd, LOCK_EX);
  try
    now_ := NowZulu;
    root := ParseFile(ChatFile);
    if (root = nil) or (root.JSONType <> jtObject) then
    begin
      FreeAndNil(root);
      root := TJSONObject.Create;
      TJSONObject(root).Add('schema_version', 1);
      TJSONObject(root).Add('project', Project);
      TJSONObject(root).Add('chat', ChatName);
      TJSONObject(root).Add('created', now_);
      TJSONObject(root).Add('updated', now_);
      TJSONObject(root).Add('exchanges', TJSONArray.Create);
    end;
    try
      ex := TJSONObject(root).Find('exchanges');
      if (ex = nil) or (ex.JSONType <> jtArray) then
      begin
        if ex <> nil then TJSONObject(root).Delete('exchanges');
        TJSONObject(root).Add('exchanges', TJSONArray.Create);
        ex := TJSONObject(root).Find('exchanges');
      end;
      arr := TJSONArray(ex);
      nextId := arr.Count + 1;
      obj := TJSONObject.Create;
      obj.Add('id', nextId); obj.Add('timestamp', now_); obj.Add('role', 'user'); obj.Add('text', UserText);
      arr.Add(obj);
      obj := TJSONObject.Create;
      obj.Add('id', nextId + 1); obj.Add('timestamp', now_); obj.Add('role', 'agent'); obj.Add('agent', Agent);
      if CliSupplier <> '' then sup := CliSupplier else if LocalProvider <> '' then sup := LocalProvider else sup := Agent;
      obj.Add('supplier', sup);
      if DisplayModel <> '' then obj.Add('model', DisplayModel) else obj.Add('model', TJSONNull.Create);
      durNum := StrToFloatDef(StringReplace(Duration, '.', DefaultFormatSettings.DecimalSeparator, []), 0);
      if durNum > 0 then obj.Add('duration_s', durNum) else obj.Add('duration_s', TJSONNull.Create);
      obj.Add('style', MaStyle); obj.Add('mode', MaMode); obj.Add('text', AgentText);
      arr.Add(obj);
      if TJSONObject(root).Find('updated') <> nil then TJSONObject(root).Delete('updated');
      TJSONObject(root).Add('updated', now_);
      ForceDirectories(ExtractFileDir(ChatFile));
      WriteWhole(ChatFile, root.FormatJSON([], 2) + #10);
      fpChmod(ChatFile, &664);
    finally
      root.Free;
    end;
  finally
    if lockFd >= 0 then begin fpFlock(lockFd, LOCK_UN); fpClose(lockFd); end;
  end;
  i := 0; o := nil;
end;

procedure SaveTurn(const UserFile: string);
var
  o, sup: string;
  rc: Integer;
begin
  if CliSupplier <> '' then sup := CliSupplier else if LocalProvider <> '' then sup := LocalProvider else sup := Agent;
  rc := RunHistory('append', ['--chat', ChatFile, '--project', Project, '--chat-name', ChatName, '--user-file', UserFile,
    '--agent-file', OutFile, '--model', DisplayModel, '--duration', Duration, '--style', MaStyle, '--mode', MaMode, '--agent', Agent,
    '--supplier', sup, '--agent-uc', AgentUc], '', o);
  if o <> '' then begin Write(o); Flush(Output); end;
  if rc = 0 then Exit;
  if rc <> 3 then begin Say('[' + AgentUc + '] append_to_chat: the history helper exited ' + IntToStr(rc) + ' after it may have written; NOT retrying'); Exit; end;
  NativeAppend(CmdSubst(ReadWhole(UserFile)), CmdSubst(ReadWhole(OutFile)));      // wrote nothing: this program saves the turn itself
end;

{ ---- the agent branches ------------------------------------------------------------------------------------------------------------------ }

function LegacyOpts(const Supplier, Raw: string): TLegacyOptions;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.CatalogFile := CliCatalogFile; Result.Supplier := Supplier; Result.RawModel := Raw; Result.PromptFile := PromptTmp; Result.OutFile := OutFile;
  Result.Images := ReqImages; Result.ExtraCliArgs := ExtraCliArgs; Result.LocalBase := LocalBase;
end;

procedure RunGenericCli(const Raw: string);
var
  O: TLegacyOptions;
  msg: string;
begin
  if CliCatalogFile = '' then
  begin
    AppendWhole(OutFile, '[' + UpperCase(CliSupplier) + ' ERROR] CLI failed or not installed — check ~/scripts/cockpit_data/cli_catalog.json.' + #10);
    Exit;
  end;
  O := LegacyOpts(CliSupplier, Raw);
  RunLegacy(O, msg);
  if msg <> '' then SayErr('aicengine legacy: ' + msg);
end;

procedure RunClaudeBranch;
var
  cf, msg: string;
  O: TLegacyOptions;
begin
  CliIsolate;
  if (CliSupplier = 'claude') or (CliSupplier = '') then
  begin
    if Copy(ClaudeModel, 1, 7) = 'claude-' then cf := ClaudeModel
    else if ClaudeModel = 'opus' then cf := 'claude-opus-4-8'
    else if ClaudeModel = 'haiku' then cf := 'claude-haiku-4-5-20251001'
    else if ClaudeModel = 'opusplan' then cf := 'claude-opus-4-8'
    else cf := 'claude-sonnet-4-6';
    FillChar(O, SizeOf(O), 0);
    O.ClaudeModel := cf; O.PromptFile := PromptTmp; O.OutFile := OutFile; O.ExtraCliArgs := ExtraCliArgs;
    RunLegacy(O, msg);
    if msg <> '' then SayErr('aicengine legacy: ' + msg);
  end
  else RunGenericCli(ClaudeModel);
end;

procedure RunGeminiBranch;
var
  relayProv, relayModel, gmodel, php, relayPhp, o, msg: string;
  ex: TStringList;
  G: TGeminiOptions;
  base: string;
begin
  if (CliSupplier <> '') and (CliSupplier <> 'gemini') and (CliRelay = '') and (CliHasBin <> '') then
  begin
    RunGenericCli(GeminiModel);
    Exit;
  end;
  if (CliSupplier <> '') and (CliSupplier <> 'gemini') then
  begin
    relayModel := '';
    if (CliSupplier = 'groq_build') or (CliSupplier = 'groq') then begin relayProv := 'groq'; relayModel := 'openai/gpt-oss-120b'; end
    else if (Pos('huggingface', CliSupplier) > 0) or (CliSupplier = 'hf') then begin relayProv := 'huggingface'; relayModel := 'meta-llama/Llama-3.1-8B-Instruct'; end
    else if Pos('cloudflare', CliSupplier) > 0 then begin relayProv := 'cloudflare'; relayModel := '@cf/meta/llama-3.1-8b-instruct'; end
    else relayProv := '';
    if (GeminiModel = '') or (GeminiModel = 'auto') or (Copy(GeminiModel, 1, 7) = 'gemini-') or (Pos('Flash', GeminiModel) > 0) or (Pos('flash', GeminiModel) > 0) then
    else relayModel := GeminiModel;
    if relayProv = '' then
    begin
      AppendWhole(OutFile, '[FALLBACK ERROR] unsupported free-REST provider: ' + CliSupplier + #10);
      Exit;
    end;
    // the relay in this process (aic_workers, proven identical to worker_relay.php); when it refuses (exit 9) the PHP relay does it
    if WorkersRelay(relayProv, relayModel, PromptTmp, ReqData, Env('COCKPIT_WORKER_BASE'), o) = 0 then
    begin
      AppendWhole(OutFile, o);
      Exit;
    end;
    relayPhp := '';
    if ReqWeb <> '' then relayPhp := ReqWeb + '/worker_relay.php' else relayPhp := '/var/www/html/cockpit/worker_relay.php';
    if not FileExists(relayPhp) then
    begin
      relayPhp := QueueDir;
      if (Length(relayPhp) >= 6) and (Copy(relayPhp, Length(relayPhp) - 5, 6) = '/queue') then SetLength(relayPhp, Length(relayPhp) - 6);
      relayPhp := relayPhp + '/worker_relay.php';
    end;
    php := Which('php');
    ex := TStringList.Create;
    try
      ex.Add('COCKPIT_DATA_OVERRIDE=' + ReqData);
      if php <> '' then Exec(php, [relayPhp, relayProv, relayModel, PromptTmp], '', False, o, ex);   // stderr is dropped, stdout appended
    finally
      ex.Free;
    end;
    // 2>/dev/null: the helper's stderr is discarded; Exec passes it to ours, which the supervisor logs - the answer is only stdout
    AppendWhole(OutFile, o);
    Exit;
  end;
  if (GeminiModel = 'gemini-2.0-flash-lite') then gmodel := 'gemini-2.0-flash-lite' else gmodel := 'gemini-2.5-flash';
  if Env('GEMINI_API_KEY') = '' then
  begin
    AppendWhole(OutFile, '[GEMINI ERROR] No API key. Put a free AI Studio key in cockpit_data/gemini_api_key.txt and restart agents.' + #10);
    Exit;
  end;
  FillChar(G, SizeOf(G), 0);
  base := Env('GEMINI_API_BASE', 'https://generativelanguage.googleapis.com');
  while (base <> '') and (base[Length(base)] = '/') do SetLength(base, Length(base) - 1);
  G.Base := base; G.Model := gmodel; G.PromptFile := PromptTmp; G.OutFile := OutFile; G.CaFile := Env('GEMINI_CA_FILE'); G.TimeoutS := 180;
  RunGemini(G, msg);
  if msg <> '' then SayErr('aicengine gemini: ' + msg);
end;

procedure RunOllamaBranch;
var
  histJson, lh, lu, msg, resp, trimmed, o: string;
  L: TLocalChatOptions;
  rc, i: Integer;
  re: TRegExpr;
  lowModel: string;
  tags: array[0..4] of string;
  hit: Boolean;
begin
  if (Model = '') and (LocalStyle = 'ollama') then Model := 'llama3.2:3b';
  OllamaPromptChars := FileLen(PromptTmp);
  if NeedsHistory(UserPrompt) then histJson := BuildHistory(UserPrompt, 'json') else histJson := '[]';
  lh := TempName('cockpit_lh_'); lu := TempName('cockpit_lu_');
  WriteWhole(lh, histJson); WriteWhole(lu, UserPrompt);
  FillChar(L, SizeOf(L), 0);
  L.Base := LocalBase; L.Style := LocalStyle; L.Model := Model; L.SystemFile := SysTmp; L.HistoryFile := lh; L.UserFile := lu;
  L.OutFile := OutFile; L.AgentUc := AgentUc; L.TimeoutS := 300;
  rc := RunLocalChat(L, msg);
  DeleteFile(lh); DeleteFile(lu);
  if rc = 2 then
  begin
    // the request could not be built (history JSON invalid ...): the Bash falls back to the CLI
    Exec(Which('ollama'), ['run', '--nowordwrap', Model, ReadWhole(PromptTmp)], '', True, o);
    WriteWhole(OutFile, o);
  end;
  resp := ReadWhole(OutFile);
  trimmed := StripSpaces(resp);
  if trimmed = '' then
    WriteWhole(OutFile, '[' + Model + ' returned nothing — try another local model (Card 3), or a smaller prompt]')
  else
  begin
    lowModel := LowerCase(Model);
    if Pos('coder', lowModel) > 0 then
    begin
      re := TRegExpr.Create;
      try
        re.ModifierI := True;
        re.Expression := 'can''?t assist|cannot assist|can not assist|i''?m sorry, but|unable to (help|assist)|i (can''?t|cannot) (help|do that)';
        hit := re.Exec(resp);
      finally
        re.Free;
      end;
      if hit then
      begin
        tags[0] := '[CHAT MODE]'; tags[1] := '[ANALYZE MODE]'; tags[2] := '[REPORT MODE]'; tags[3] := '[RESEARCH MODE]'; tags[4] := '[OUTLINE MODE]';
        for i := 0 to 4 do
          if Pos(tags[i], ' ' + UserPrompt + ' ') > 0 then
          begin
            WriteWhole(OutFile, '[Coder model "' + Model + '" — not suited for chat. Switch Card 3 to a chat model (e.g. llama3.2:3b), or use the Build/Debug style.]');
            Break;
          end;
      end;
    end;
  end;
end;

{ ---- one request ------------------------------------------------------------------------------------------------------------------------- }

procedure ServeRequest(const PromptFile: string);
var
  ioA: TIntakeOptions;
  ir: TIntakeResult;
  ro: TRouteOptions;
  po: TPromptOptions;
  msg, userTmp, tmpd, ragText, crudOut, crudStd, crudErr, crud, php, o, histText, startMs: string;
  rc: Integer;
  startNs: Int64;
  cl: TCleanOptions;
  ex: TStringList;
  pf: string;
  capsOut, wOut, tOut: string;
  CurDirOk: Boolean;
begin
  FillChar(ioA, SizeOf(ioA), 0);
  ioA.Agent := Agent; ioA.QueueDir := QueueDir; ioA.ResponseDir := ResponseDir; ioA.PromptFile := PromptFile; ioA.Root := CockpitRoot;
  ioA.PromptOut := TempName('cockpit_po_');
  rc := RunIntakeEx(ioA, True, ir, msg);
  if rc <> 0 then begin DeleteFile(ioA.PromptOut); SayErr('[' + AgentUc + '] intake failed: ' + msg); Exit; end;
  UserPrompt := CmdSubst(ReadWhole(ioA.PromptOut)); DeleteFile(ioA.PromptOut);
  Token := ir.Token; OutFile := ir.OutFile; DoneFile := ir.DoneFile; Project := ir.Project; ChatName := ir.ChatName;
  ClaudeModel := ir.ClaudeModel; GeminiModel := ir.GeminiModel; ReqRoot := ir.ReqRoot; ReqData := ir.ReqData; ReqWeb := ir.ReqWeb; RagB64 := ir.RagB64;
  Model := ir.Model; ExtraCliArgs := ir.ExtraCliArgs; ProjectDir := ir.ProjectDir; ChatFile := ir.ChatFile;
  if ir.HasMeta then begin MaStyle := ir.Style; MaMode := ir.Mode; ReqImages := ir.Images; end;
  if not ir.HasMeta then
    Say('[' + AgentUc + '] WARNING: no metadata for ' + Token + ' — falling back to the shared root and default project/models; this turn may be saved to the wrong chat');
  if ir.HasMeta then
  begin
    InternalSetup;
    if (ReqData <> '') and FileExists(ReqData + '/supplier_slots.json') then begin ResolveSupplier(ReqData); ResolveLocal(ReqData); end;
  end;
  ForceDirectories(ProjectDir);
  CurDirOk := SetCurrentDir(ProjectDir) or SetCurrentDir(CockpitRoot);
  if CurDirOk then;

  // capabilities and the auto-route prompts
  FillChar(ro, SizeOf(ro), 0);
  ro.Agent := Agent; ro.Project := Project; ro.ProjectDir := ProjectDir; ro.DataDir := DataDir; ro.BaseUrl := Env('COCKPIT_BASE_URL', 'http://localhost/cockpit'); ro.Home := Home;
  RunRouteEx(ro, True, capsOut, wOut, tOut, msg);
  CapsPrompt := capsOut; WorkersPrompt := wOut; ToolsPrompt := tOut;

  // supplier controls: the effort text goes in front of the prompt (intake did it) - nothing more to do here
  Say('[' + AgentUc + '] Processing: ' + Token + ' | Project: ' + Project + ' | Chat: ' + ChatName);

  if NeedsHistory(UserPrompt) then History := BuildHistory(UserPrompt, 'text') else History := '';

  // assemble the prompt
  PromptTmp := TempName('cockpit_prompt_'); SysTmp := TempName('cockpit_sys_');
  tmpd := TempName('cockpit_pa_'); ForceDirectories(tmpd);
  ragText := B64Plain(RagB64);
  WriteWhole(tmpd + '/user', UserPrompt); WriteWhole(tmpd + '/hist', History);
  WriteWhole(tmpd + '/rag', ragText);
  WriteWhole(tmpd + '/workers', WorkersPrompt); WriteWhole(tmpd + '/tools', ToolsPrompt); WriteWhole(tmpd + '/caps', CapsPrompt);
  WriteWhole(tmpd + '/crud', LOOPTEXT_CRUD_SYSTEM_PROMPT); WriteWhole(tmpd + '/style', LOOPTEXT_CLAUDE_STYLE);
  FillChar(po, SizeOf(po), 0);
  po.Agent := Agent; po.Project := Project; po.ProjectDir := ProjectDir; po.ChatName := ChatName;
  if ReqData <> '' then po.DataDir := ReqData else po.DataDir := DataDir;
  po.CliSupplier := CliSupplier; po.ClaudeModel := ClaudeModel; po.GeminiModel := GeminiModel; po.Model := Model; po.PromptStyle := CliPromptStyle;
  po.UserFile := tmpd + '/user'; po.HistoryFile := tmpd + '/hist'; po.RagFile := tmpd + '/rag'; po.WorkersFile := tmpd + '/workers'; po.ToolsFile := tmpd + '/tools';
  po.CapsFile := tmpd + '/caps'; po.CrudFile := tmpd + '/crud'; po.StyleFile := tmpd + '/style'; po.OutFile := PromptTmp; po.SysOutFile := SysTmp;
  rc := RunPrompt(po, msg);
  DeleteFile(tmpd + '/user'); DeleteFile(tmpd + '/hist'); DeleteFile(tmpd + '/rag'); DeleteFile(tmpd + '/workers'); DeleteFile(tmpd + '/tools');
  DeleteFile(tmpd + '/caps'); DeleteFile(tmpd + '/crud'); DeleteFile(tmpd + '/style'); RemoveDir(tmpd);
  if rc <> 0 then SayErr('[' + AgentUc + '] prompt assembly failed: ' + msg);

  // run the agent
  WriteWhole(OutFile, ''); fpChmod(OutFile, &664);
  startNs := NowNs;
  LegacyCancel := False;
  if Agent = 'claude' then RunClaudeBranch
  else if Agent = 'gemini' then RunGeminiBranch
  else if Agent = 'ollama' then RunOllamaBranch;

  // clean-up
  FillChar(cl, SizeOf(cl), 0);
  cl.Agent := Agent; cl.OutFile := OutFile; cl.StartNs := startNs; cl.Model := Model; cl.Project := Project; cl.Chat := ChatName; cl.PromptChars := OllamaPromptChars;
  pf := QueueDir;
  if (Length(pf) >= 6) and (Copy(pf, Length(pf) - 5, 6) = '/queue') then SetLength(pf, Length(pf) - 6);
  cl.UsageLog := pf + '/ollama_usage.jsonl';
  if RunClean(cl, Duration, msg) <> 0 then Duration := '0';
  DeleteFile(PromptTmp); DeleteFile(SysTmp);

  // the %%markers%%: in this process (aic_crud, proven identical to crud_cli.php); when it refuses (exit 9) the PHP helper, then the Bash executor
  SetEnv('COCKPIT_DATA_USER', ReqData);
  rc := CrudRun(ProjectDir, OutFile, Agent, Project, crudStd, crudErr, crudOut);
  if rc = CRUD_REFUSED then
  begin
    crudOut := '';
    php := Which('php'); crud := ScriptsDir + '/crud_cli.php';
    ex := TStringList.Create;
    try
      ex.Add('COCKPIT_DATA_USER=' + ReqData);
      if (php <> '') and FileExists(crud) then Exec(php, [crud, ProjectDir, OutFile, Agent, Project], '', True, crudOut, ex)
      else if FileExists(ScriptsDir + '/crud_executor.sh') then Exec('/bin/bash', [ScriptsDir + '/crud_executor.sh', ProjectDir, OutFile, Agent, Project], '', True, crudOut, ex);
    finally
      ex.Free;
    end;
  end;
  crudOut := CmdSubst(crudOut);
  if crudOut <> '' then
  begin
    Say('[' + AgentUc + '] CRUD operations executed');
    AppendWhole(OutFile, #10#10 + '---' + #10 + '[File Operations]' + #10 + crudOut + #10);
  end;

  // save the turn
  userTmp := TempName('cockpit_user_'); WriteWhole(userTmp, UserPrompt);
  RunSigninHint(Agent, AgentUc, OutFile, msg);
  DisplayModel := Model;
  if Agent = 'claude' then DisplayModel := ClaudeModel;
  if Agent = 'gemini' then DisplayModel := GeminiModel;
  SaveTurn(userTmp);
  DeleteFile(userTmp);
  WriteWhole(DoneFile, Token + #10);
  Say('[' + AgentUc + '] Done: ' + Token + ' (' + Duration + 's)');
  startMs := '';
end;

{ ---- the loop --------------------------------------------------------------------------------------------------------------------------- }

var
  Interrupted: Boolean = False;

procedure OnInt(Sig: cint); cdecl;
begin
  LegacyCancel := True;
  Interrupted := True;
end;

function FirstPrompt: string;
var
  sr: TSearchRec;
  best, prefix: string;
begin
  Result := '';
  best := '';
  prefix := Agent + '_prompt_';
  if FindFirst(QueueDir + '/' + prefix + '*.txt', faAnyFile, sr) = 0 then
  begin
    repeat
      if (best = '') or (CompareStr(sr.Name, best) < 0) then best := sr.Name;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  if best <> '' then Result := QueueDir + '/' + best;
end;

{ /proc files report a size of 0: read until the end }
function ReadProc(const F: string): string;
var
  fs: TFileStream;
  buf: array[0..4095] of Char;
  n: Integer;
begin
  Result := '';
  try
    fs := TFileStream.Create(F, fmOpenRead or fmShareDenyNone);
    try
      repeat
        n := fs.Read(buf, SizeOf(buf));
        if n > 0 then begin SetLength(Result, Length(Result) + n); Move(buf[0], Result[Length(Result) - n + 1], n); end;
      until n <= 0;
    finally
      fs.Free;
    end;
  except
    Result := '';
  end;
end;

function OtherLoopAlive(const PidFile: string; out OtherPid: Integer): Boolean;
var
  other, cmd: string;
  pid: Integer;
begin
  Result := False; OtherPid := 0;
  if not FileExists(PidFile) then Exit;
  other := Trim(CmdSubst(ReadWhole(PidFile)));
  pid := StrToIntDef(other, 0);
  if (pid <= 0) or (pid = fpGetPid) then Exit;
  cmd := StringReplace(ReadProc('/proc/' + IntToStr(pid) + '/cmdline'), #0, ' ', [rfReplaceAll]);
  OtherPid := pid;
  Result := (Pos('agent_loop.sh ' + Agent, cmd) > 0) or (Pos('aicengine loop ' + Agent, cmd) > 0) or (Pos('loop ' + Agent, cmd) > 0);
end;

procedure LoadKeyEnv(const FileName, VarName: string);
var
  k: string;
begin
  if FileExists(FileName) then
  begin
    k := StripSpaces(ReadWhole(FileName));
    if k <> '' then SetEnv(VarName, k);
  end;
end;

function RunLoop(const Agent_: string): Integer;
var
  cfg: TJSONData;
  pj: TJSONData;
  pjFile, pidf, pf, v: string;
  opid: Integer;
begin
  Result := 0;
  Agent := Agent_;
  if (Agent <> 'claude') and (Agent <> 'gemini') and (Agent <> 'ollama') then
  begin
    SayErr('aicengine loop: the agent must be claude, gemini or ollama'); Exit(2);
  end;
  AgentUc := UpperCase(Agent);
  Home := Env('HOME'); ScriptsDir := Home + '/scripts';
  QueueDir := Env('COCKPIT_QUEUE_DIR', '/var/www/html/cockpit/queue');
  ResponseDir := Env('COCKPIT_RESPONSE_DIR', '/var/www/html/cockpit/responses');
  DataDir := Env('COCKPIT_DATA_DIR');
  pf := QueueDir;
  if (Length(pf) >= 6) and (Copy(pf, Length(pf) - 5, 6) = '/queue') then SetLength(pf, Length(pf) - 6);
  CockpitRoot := '';
  pjFile := ExtractFileDir(QueueDir) + '/paths.json';
  pj := ParseFile(pjFile);
  try
    if pj <> nil then CockpitRoot := JqText(Sub(pj, 'projects_root'), '');
  finally
    pj.Free;
  end;
  if CockpitRoot = '' then CockpitRoot := Home + '/Software/Programing/LocalAIProjs';
  SetEnv('COCKPIT_ROOT', CockpitRoot);

  SetEnv('PATH', Home + '/.npm-global/bin:' + Home + '/.local/bin:' + Home + '/.opencode/bin:/usr/local/bin:/usr/bin:/bin');
  SetEnv('OLLAMA_MODELS', Home + '/ollama/models');
  cfg := ParseFile(DataDir + '/ollama_config.json');
  try
    if FileExists(DataDir + '/ollama_config.json') then
    begin
      v := JqText(Sub(cfg, 'keep_alive'), '5m'); if v <> '' then SetEnv('OLLAMA_KEEP_ALIVE', v);
      v := JqText(Sub(cfg, 'num_parallel'), '1'); if v <> '' then SetEnv('OLLAMA_NUM_PARALLEL', v);
      v := JqText(Sub(cfg, 'max_loaded'), '1'); if v <> '' then SetEnv('OLLAMA_MAX_LOADED_MODELS', v);
    end;
  finally
    cfg.Free;
  end;
  SetEnv('GEMINI_CLI_TRUST_WORKSPACE', 'true'); SetEnv('NO_COLOR', '1'); SetEnv('TERM', 'dumb');
  LoadKeyEnv(DataDir + '/gemini_api_key.txt', 'GEMINI_API_KEY');
  LoadKeyEnv(DataDir + '/groq_api_key.txt', 'GROQ_API_KEY');

  // Stop (Ctrl-C into the pane): stop the running agent, but keep serving
  fpSignal(SIGINT, @OnInt);

  ResolveSupplier(DataDir); ResolveLocal(DataDir);
  if not SetCurrentDir(CockpitRoot) then
    if not SetCurrentDir(Home) then begin SayErr('[' + AgentUc + '] FATAL: cannot cd to ' + CockpitRoot + ' or ' + Home); Exit(1); end;

  if CliSupplier <> '' then v := CliSupplier else v := Agent;
  Say('[' + AgentUc + '] Agent loop v3 started (supplier: ' + v + '; re-read per request from the user''s slots). CRUD enabled. No Python.');
  Say('[' + AgentUc + '] Watching: ' + QueueDir);

  pidf := QueueDir + '/.loop_' + Agent + '.pid';
  if OtherLoopAlive(pidf, opid) then
  begin
    Say('[' + AgentUc + '] Another agent loop (pid ' + IntToStr(opid) + ') already serves ' + QueueDir + '; this one is not needed and exits.');
    Exit(0);
  end;
  try WriteWhole(pidf, IntToStr(fpGetPid) + #10); except end;

  while True do
  begin
    v := FirstPrompt;
    if v <> '' then
    begin
      Interrupted := False;
      try
        ServeRequest(v);
      except
        on E: Exception do SayErr('[' + AgentUc + '] request failed: ' + E.Message);
      end;
      if Interrupted then Say('[agent] interrupted (Stop pressed) -- still serving');
    end;
    Sleep(500);
  end;
end;

end.
