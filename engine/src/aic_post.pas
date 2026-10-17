(* =============================================================================
  aic_post — what agent_loop.sh does with an agent's raw answer before it is saved:

    clean        strip the terminal artifacts from an Ollama / Gemini answer, measure how long the turn took, and write the Ollama
                 usage line (one JSON object per call)                                          -> aicengine clean ...
    signin-hint  a short answer that says the CLI is not signed in gets a line telling where to sign in -> aicengine signin-hint ...

  Each is the Bash it replaces (sed, bc, date arithmetic, printf, grep) step for step; tests/post_parity.sh in the Cockpit repo proves
  the same bytes come out. Differences, all deliberate and listed in the README: it needs none of sed / bc / GNU date (so it also runs
  on macOS, where `date +%s%N` prints a literal N), and the usage line is real JSON for any name (the Bash escaped only the double quote).
  ============================================================================= *)
unit aic_post;

{$mode objfpc}{$H+}

interface

type
  TCleanOptions = record
    Agent, OutFile, UsageLog, Model, Project, Chat: string;
    StartNs: Int64;            // date +%s%N taken before the agent ran
    EndNs: Int64;              // 0 = now (tests pass a fixed value)
    PromptChars: Int64;
    Ts: string;                // '' = now, UTC (tests pass a fixed value)
  end;

{ the answer with the terminal artifacts of that agent removed (sed -i of the Bash), exposed for the tests }
function StripPty(const Agent, Content: string): string;
{ bc's  scale=1  output: ".3", "0", "2.3", "5.0" }
function FormatDuration(ElapsedNs: Int64): string;
{ clean: writes OutFile in place, appends the usage line for Ollama, returns the duration text. Exit 2 = refused before touching anything. }
function RunClean(const O: TCleanOptions; out Duration, Msg: string): Integer;
{ signin-hint: appends the hint to OutFile when the answer is short and says the CLI is not signed in }
function RunSigninHint(const Agent, AgentUc, OutFile: string; out Msg: string): Integer;

implementation

uses
  SysUtils, Classes, BaseUnix, Unix, RegExpr;

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
  fs := TFileStream.Create(F, fmOpenWrite or fmShareDenyNone);     // rewrite in place: the file keeps its owner and mode (sed -i makes a new one)
  try
    fs.Size := 0;
    if Data <> '' then fs.WriteBuffer(Data[1], Length(Data));
  finally
    fs.Free;
  end;
end;

procedure AppendTo(const F, Data: string);
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

{ s/\x1b\[[0-9;]*[mGKHFJA-Z]//g  — left to right, non-overlapping }
function StripEscapes(const L: string): string;
var
  i, j: Integer;
  c: Char;
begin
  Result := '';
  i := 1;
  while i <= Length(L) do
  begin
    if (L[i] = #27) and (i < Length(L)) and (L[i + 1] = '[') then
    begin
      j := i + 2;
      while (j <= Length(L)) and (L[j] in ['0'..'9', ';']) do Inc(j);
      if j <= Length(L) then
      begin
        c := L[j];
        if (c = 'm') or (c in ['A'..'Z']) then begin i := j + 1; Continue; end;     // G K H F J are inside A-Z
      end;
    end;
    Result := Result + L[i];
    Inc(i);
  end;
end;

function RemoveCr(const L: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(L) do if L[i] <> #13 then Result := Result + L[i];
end;

{ ^[0-9]\\+[hs]  followed by a space }
function IsSpinnerLine(const L: string): Boolean;
var
  i: Integer;
begin
  i := 1;
  while (i <= Length(L)) and (L[i] in ['0'..'9']) do Inc(i);
  Result := (i > 1) and (i < Length(L)) and (L[i] in ['h', 's']) and (L[i + 1] = ' ');
end;

{ the Gemini CLI's cosmetic lines, matched case-insensitively anywhere in the line:
    Warning:.*color | true color | Ripgrep is not available | Falling back to GrepTool | Basic terminal detected | Using a terminal with true color }
function IsGeminiNoise(const L: string): Boolean;
var
  u: string;
  p: Integer;
begin
  u := LowerCase(L);
  Result := (Pos('true color', u) > 0) or (Pos('ripgrep is not available', u) > 0) or (Pos('falling back to greptool', u) > 0)
    or (Pos('basic terminal detected', u) > 0) or (Pos('using a terminal with true color', u) > 0);
  if Result then Exit;
  p := Pos('warning:', u);
  if p > 0 then Result := Pos('color', Copy(u, p + 8, MaxInt)) > 0;
end;

{ the lines of a text, split on LF only; the empty piece after a final LF is not a line (what sed sees) }
procedure SplitLf(const S: string; Lines: TStringList);
var
  p, q: Integer;
begin
  Lines.Clear;
  p := 1;
  while p <= Length(S) do
  begin
    q := p;
    while (q <= Length(S)) and (S[q] <> #10) do Inc(q);
    Lines.Add(Copy(S, p, q - p));
    p := q + 1;
  end;
end;

function StripPty(const Agent, Content: string): string;
var
  lines: TStringList;
  i, last: Integer;
  l: string;
  noFinalNl: Boolean;
begin
  Result := Content;
  if (Agent <> 'ollama') and (Agent <> 'gemini') then Exit;
  if Content = '' then Exit;
  lines := TStringList.Create;
  try
    SplitLf(Content, lines);
    noFinalNl := Content[Length(Content)] <> #10;
    last := lines.Count - 1;
    Result := '';
    for i := 0 to lines.Count - 1 do
    begin
      l := StripEscapes(RemoveCr(lines[i]));
      if Agent = 'ollama' then begin if (i = last) and IsSpinnerLine(l) then Continue; end
      else if IsGeminiNoise(l) then Continue;
      Result := Result + l;
      if not ((i = last) and noFinalNl) then Result := Result + #10;       // GNU sed keeps a missing final newline missing
    end;
  finally
    lines.Free;
  end;
end;

function FormatDuration(ElapsedNs: Int64): string;
var
  t, whole, frac: Int64;
  neg: Boolean;
begin
  t := ElapsedNs div 100000000;               // bc truncates toward zero at scale=1
  neg := t < 0;
  if neg then t := -t;
  whole := t div 10; frac := t mod 10;
  if (whole = 0) and (frac = 0) then Exit('0');
  if whole = 0 then Result := '.' + IntToStr(frac) else Result := IntToStr(whole) + '.' + IntToStr(frac);
  if neg then Result := '-' + Result;
end;

function NowNs: Int64;
var
  tv: TTimeVal;
begin
  fpGetTimeOfDay(@tv, nil);
  Result := Int64(tv.tv_sec) * 1000000000 + Int64(tv.tv_usec) * 1000;
end;

function JsonEsc(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      #0..#7, #11, #14..#31: Result := Result + '\u' + LowerCase(IntToHex(Ord(S[i]), 4));
    else Result := Result + S[i];
    end;
end;

function UtcStamp: string;
var
  tv: TTimeVal;
  t: TDateTime;
begin
  fpGetTimeOfDay(@tv, nil);
  t := EncodeDate(1970, 1, 1) + tv.tv_sec / 86400.0;
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss', t);
end;

function RunClean(const O: TCleanOptions; out Duration, Msg: string): Integer;
var
  content, cleaned, ts, line: string;
  endNs: Int64;
  elapsed, tenths, respChars: Int64;
begin
  Msg := ''; Duration := '0'; Result := 0;
  if (O.OutFile = '') or not FileExists(O.OutFile) then begin Msg := 'output file not found'; Exit(2); end;
  if O.StartNs <= 0 then begin Msg := 'no start time'; Exit(2); end;
  content := ReadWhole(O.OutFile);
  cleaned := StripPty(O.Agent, content);
  if cleaned <> content then WriteWhole(O.OutFile, cleaned);
  if O.EndNs > 0 then endNs := O.EndNs else endNs := NowNs;
  elapsed := endNs - O.StartNs;
  Duration := FormatDuration(elapsed);
  if O.Agent = 'ollama' then
  begin
    respChars := Length(cleaned);
    tenths := elapsed div 100000000;
    if O.Ts <> '' then ts := O.Ts else ts := UtcStamp;
    line := '{"ts":"' + ts + '","model":"' + JsonEsc(O.Model) + '","project":"' + JsonEsc(O.Project) + '","chat":"' + JsonEsc(O.Chat) +
      '","prompt_tokens":' + IntToStr(O.PromptChars div 4) + ',"output_tokens":' + IntToStr(respChars div 4) + ',"total_ms":' + IntToStr(tenths * 100) + '}' + #10;
    if O.UsageLog <> '' then
    begin
      try
        AppendTo(O.UsageLog, line);
        fpChmod(O.UsageLog, &664);
      except
        // the Bash ignored a failing append too (the answer matters more than the usage log)
      end;
    end;
  end;
end;

function RunSigninHint(const Agent, AgentUc, OutFile: string; out Msg: string): Integer;
var
  content, ln: string;
  lines: TStringList;
  re: TRegExpr;
  i: Integer;
  hit: Boolean;
begin
  Msg := ''; Result := 0;
  if (OutFile = '') or not FileExists(OutFile) then Exit(0);
  content := ReadWhole(OutFile);
  if Length(content) >= 800 then Exit(0);                              // a long answer that merely mentions it is not this
  re := TRegExpr.Create;
  lines := TStringList.Create;
  try
    re.ModifierI := True;
    re.Expression := 'not logged in|please run /login|run .?(claude|gemini|codex|qwen)?.?(auth|login)|not authenticated|authentication required|GEMINI_API_KEY|OPENAI_API_KEY';
    SplitLf(content, lines);
    hit := False;
    for i := 0 to lines.Count - 1 do
    begin
      ln := lines[i];
      if re.Exec(ln) then begin hit := True; Break; end;               // grep matches line by line: a dot never crosses a line break
    end;
  finally
    lines.Free; re.Free;
  end;
  if hit then
    AppendTo(OutFile, #10#10 + '[COCKPIT] ' + Agent + ' is installed but not signed in. Sign in once: on the ' + AgentUc + ' card click "Open ' + Agent +
      ' CLI in a new terminal" and sign in when it asks (/login or /auth opens the browser). Ollama needs no sign-in.' + #10);
end;

end.
