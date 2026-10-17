(* =============================================================================
  aic_intake — the first half of one turn of agent_loop.sh, from "a prompt file is waiting" to "the prompt text is known":

    * the token from the prompt file's name, the three paths (.out, .done, meta) and the Ollama model file;
    * the request's meta file (project, chat, models, per-user folders, controls ...) read the way json_get reads it
      (the first  "key": "string"  on any line; no escapes but \/), with the same defaults, then the meta and model files removed;
    * the project folder and chat file the turn works in;
    * the prompt itself, with the effort text of the supplier control put in front, and the whitelisted extra CLI arguments.

  Output: shell assignments on standard output (every value single-quoted) for the loop to `eval`, and the prompt text in --prompt-out.
  Exit 2 = refused before touching anything (the Bash does it): a control that is not clean base64 (GNU base64 -d would have printed a
  partial result), a NUL byte in a decoded text, or a prompt file that cannot be read. tests/intake_parity.sh in the Cockpit repo proves the
  same values come out as the Bash it replaces.
  ============================================================================= *)
unit aic_intake;

{$mode objfpc}{$H+}

interface

type
  TIntakeOptions = record
    Agent, QueueDir, ResponseDir, PromptFile, Root, PromptOut: string;
  end;

{ json_get of the loop: the string value of the first "key": "value" found on any line, '' when absent; \/ becomes / }
function JsonGet(const Content, Key: string): string;
type
  TIntakeResult = record
    Token, OutFile, DoneFile, MetaFile: string;
    HasMeta: Boolean;
    Project, ChatName, ClaudeModel, GeminiModel, ClaudeEffort, GeminiEffort, ClaudeArgsB64, GeminiArgsB64: string;
    ReqRoot, ReqData, ReqWeb, RagB64, Style, Mode, Images, Model, ExtraCliArgs, ProjectDir, ChatFile: string;
  end;

{ the same, as values; Lenient = a control that is not clean base64 (or has a NUL) counts as absent instead of refusing }
function RunIntakeEx(const O: TIntakeOptions; Lenient: Boolean; out R: TIntakeResult; out Msg: string): Integer;
function RunIntake(const O: TIntakeOptions; out Shell, Msg: string): Integer;

implementation

uses
  SysUtils, Classes, BaseUnix, RegExpr;

function ReadWhole(const F: string; out Ok: Boolean): string;
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

{ what $( ... ) does to a text: NULs are dropped, trailing newlines are removed }
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

function JsonGet(const Content, Key: string): string;
var
  re: TRegExpr;
  p, q: Integer;
  line, m: string;
begin
  Result := '';
  re := TRegExpr.Create;
  try
    // grep -o per line: "key" [[:space:]]* : [[:space:]]* "no-quote*"   ([[:space:]] = space \t \n \v \f \r; a line has no \n)
    re.Expression := '"' + QuoteRegExprMetaChars(Key) + '"[ \t\v\f\r]*:[ \t\v\f\r]*"[^"]*"';
    p := 1;
    while p <= Length(Content) + 1 do
    begin
      q := p;
      while (q <= Length(Content)) and (Content[q] <> #10) do Inc(q);
      line := Copy(Content, p, q - p);
      if re.Exec(line) then
      begin
        m := re.Match[0];
        m := Copy(m, 1, Length(m) - 1);                       // drop the closing quote
        Result := Copy(m, LastDelimiter('"', m) + 1, MaxInt);  // the text after the opening quote of the value
        Result := StringReplace(Result, '\/', '/', [rfReplaceAll]);
        Exit;
      end;
      p := q + 1;
    end;
  finally
    re.Free;
  end;
end;

function Q(const S: string): string;      // single-quoted for sh / bash
begin
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
end;

procedure Put(var Sh: string; const Name, Value: string);
begin
  Sh := Sh + Name + '=' + Q(Value) + #10;
end;

{ GNU base64 -d of a clean text (alphabet, '=' only as the padding, length a multiple of 4); False = the Bash would behave in ways not copied here }
function B64Decode(const S: string; out R: string): Boolean;
const
  Alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  i, v, bits, acc, pad: Integer;
begin
  R := ''; Result := False;
  if (Length(S) mod 4) <> 0 then Exit;
  acc := 0; bits := 0; pad := 0;
  for i := 1 to Length(S) do
  begin
    if S[i] = '=' then begin Inc(pad); if pad > 2 then Exit; Continue; end;
    if pad > 0 then Exit;                                     // data after padding
    v := Pos(S[i], Alpha) - 1;
    if v < 0 then Exit;
    acc := (acc shl 6) or v; bits := bits + 6;
    if bits >= 8 then begin bits := bits - 8; R := R + Chr((acc shr bits) and $FF); acc := acc and ((1 shl bits) - 1); end;
  end;
  Result := True;
end;

{ grep -qE '^[-A-Za-z0-9 _.:=/]*$' : true when ANY line is made only of those characters (an empty line counts; no line at all does not) }
function AnyLineClean(const S: string): Boolean;
var
  p, q, i: Integer;
  ok: Boolean;
begin
  Result := False;
  if S = '' then Exit;
  p := 1;
  while p <= Length(S) + 1 do
  begin
    q := p;
    while (q <= Length(S)) and (S[q] <> #10) do Inc(q);
    ok := True;
    for i := p to q - 1 do if not (S[i] in ['-', 'A'..'Z', 'a'..'z', '0'..'9', ' ', '_', '.', ':', '=', '/']) then begin ok := False; Break; end;
    if ok then Exit(True);
    p := q + 1;
    if p > Length(S) then Break;                              // a final newline does not make one more (empty) line
  end;
end;

function RunIntakeEx(const O: TIntakeOptions; Lenient: Boolean; out R: TIntakeResult; out Msg: string): Integer;
var
  tok, meta, metaPath, modelPath, text, prompt, effortB64, argsB64, effTxt, argsTxt, extra: string;
  project, chat, claudeModel, geminiModel, claudeEffort, geminiEffort, claudeArgs, geminiArgs, rag, style, mode, root, data, web, images, model: string;
  hasMeta, rd: Boolean;
  base, prefix: string;
begin
  Msg := ''; Result := 0; R := Default(TIntakeResult);
  if (O.PromptFile = '') or (O.Agent = '') or (O.QueueDir = '') or (O.ResponseDir = '') or (O.PromptOut = '') then begin Msg := 'missing option'; Exit(2); end;
  prefix := O.Agent + '_prompt_';
  base := ExtractFileName(O.PromptFile);
  if (Copy(base, 1, Length(prefix)) <> prefix) or (Copy(base, Length(base) - 3, 4) <> '.txt') then begin Msg := 'not a prompt file name'; Exit(2); end;
  tok := Copy(base, Length(prefix) + 1, Length(base) - Length(prefix) - 4);
  metaPath := O.QueueDir + '/' + tok + '_meta.json';
  modelPath := O.QueueDir + '/' + tok + '_model.txt';

  // the prompt first: nothing is removed unless everything that can refuse has run
  text := ReadWhole(O.PromptFile, rd);
  if not rd then begin Msg := 'cannot read the prompt file'; Exit(2); end;
  prompt := CmdSubst(text);

  project := 'default'; chat := 'default'; claudeModel := 'sonnet'; geminiModel := 'auto';
  claudeEffort := ''; geminiEffort := ''; claudeArgs := ''; geminiArgs := '';
  rag := ''; style := ''; mode := ''; root := ''; data := ''; web := ''; images := '';
  hasMeta := FileExists(metaPath);
  if hasMeta then
  begin
    meta := ReadWhole(metaPath, rd);
    project := JsonGet(meta, 'project'); chat := JsonGet(meta, 'chat'); style := JsonGet(meta, 'style'); mode := JsonGet(meta, 'mode');
    root := JsonGet(meta, 'projects_root'); data := JsonGet(meta, 'cockpit_data'); web := JsonGet(meta, 'web_root');
    claudeModel := JsonGet(meta, 'claude_model'); geminiModel := JsonGet(meta, 'gemini_model');
    claudeEffort := JsonGet(meta, 'claude_effort'); geminiEffort := JsonGet(meta, 'gemini_effort');
    claudeArgs := JsonGet(meta, 'claude_args'); geminiArgs := JsonGet(meta, 'gemini_args');
    rag := JsonGet(meta, 'rag'); images := JsonGet(meta, 'images');
    if project = '' then project := 'default';
    if chat = '' then chat := 'default';
    if claudeModel = '' then claudeModel := 'sonnet';
    if geminiModel = '' then geminiModel := 'auto';
  end;
  if root = '' then root := O.Root;

  effortB64 := ''; argsB64 := '';
  if O.Agent = 'claude' then begin effortB64 := claudeEffort; argsB64 := claudeArgs; end
  else if O.Agent = 'gemini' then begin effortB64 := geminiEffort; argsB64 := geminiArgs; end;
  effTxt := '';
  if effortB64 <> '' then
  begin
    if (not B64Decode(effortB64, effTxt)) or (Pos(#0, effTxt) > 0) then
    begin
      if not Lenient then begin Msg := 'effort control is not clean base64'; Exit(2); end;
      effTxt := '';
    end;
    effTxt := CmdSubst(effTxt);
  end;
  extra := '';
  if argsB64 <> '' then
  begin
    if (not B64Decode(argsB64, argsTxt)) or (Pos(#0, argsTxt) > 0) then
    begin
      if not Lenient then begin Msg := 'args control is not clean base64'; Exit(2); end;
      argsTxt := '';
    end;
    if AnyLineClean(argsTxt) then extra := CmdSubst(argsTxt);
  end;
  if effTxt <> '' then prompt := effTxt + prompt;

  model := '';
  if FileExists(modelPath) then begin model := CmdSubst(ReadWhole(modelPath, rd)); end;

  // point of no return: the files the Bash removes
  WriteWhole(O.PromptOut, prompt);
  DeleteFile(O.PromptFile);
  if hasMeta then DeleteFile(metaPath);
  if FileExists(modelPath) then DeleteFile(modelPath);

  R.Token := tok; R.OutFile := O.ResponseDir + '/' + tok + '.out'; R.DoneFile := O.ResponseDir + '/' + tok + '.done'; R.MetaFile := metaPath;
  R.HasMeta := hasMeta; R.Project := project; R.ChatName := chat; R.ClaudeModel := claudeModel; R.GeminiModel := geminiModel;
  R.ClaudeEffort := claudeEffort; R.GeminiEffort := geminiEffort; R.ClaudeArgsB64 := claudeArgs; R.GeminiArgsB64 := geminiArgs;
  R.ReqRoot := root; R.ReqData := data; R.ReqWeb := web; R.RagB64 := rag; R.Style := style; R.Mode := mode; R.Images := images;
  R.Model := model; R.ExtraCliArgs := extra; R.ProjectDir := root + '/' + project;        // _standalone is just a project name here
  R.ChatFile := root + '/' + project + '/chat_' + chat + '.json';
end;

function RunIntake(const O: TIntakeOptions; out Shell, Msg: string): Integer;
var
  R: TIntakeResult;
begin
  Shell := '';
  Result := RunIntakeEx(O, False, R, Msg);
  if Result <> 0 then Exit;
  Put(Shell, 'TOKEN', R.Token); Put(Shell, 'OUT_FILE', R.OutFile); Put(Shell, 'DONE_FILE', R.DoneFile); Put(Shell, 'META_FILE', R.MetaFile);
  Put(Shell, 'META_FOUND', IntToStr(Ord(R.HasMeta)));
  Put(Shell, 'PROJECT', R.Project); Put(Shell, 'CHAT_NAME', R.ChatName);
  Put(Shell, 'CLAUDE_MODEL', R.ClaudeModel); Put(Shell, 'GEMINI_MODEL', R.GeminiModel);
  Put(Shell, 'CLAUDE_EFFORT', R.ClaudeEffort); Put(Shell, 'GEMINI_EFFORT', R.GeminiEffort);
  Put(Shell, 'CLAUDE_ARGS_B64', R.ClaudeArgsB64); Put(Shell, 'GEMINI_ARGS_B64', R.GeminiArgsB64);
  Put(Shell, 'REQ_ROOT', R.ReqRoot); Put(Shell, 'REQ_DATA', R.ReqData); Put(Shell, 'REQ_WEB', R.ReqWeb); Put(Shell, 'RAG_B64', R.RagB64);
  if R.HasMeta then begin Put(Shell, 'MA_STYLE', R.Style); Put(Shell, 'MA_MODE', R.Mode); Put(Shell, 'REQ_IMAGES', R.Images); end;
  Put(Shell, 'MODEL', R.Model); Put(Shell, 'EXTRA_CLI_ARGS', R.ExtraCliArgs);
  Put(Shell, 'PROJECT_DIR', R.ProjectDir); Put(Shell, 'CHAT_FILE', R.ChatFile);
end;

end.
