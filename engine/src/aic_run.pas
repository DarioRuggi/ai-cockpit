(* =============================================================================
  aic_run — one RUN: pick the transport, feed the parser, apply limits, always end with `done`.

  Contract (tested):
    * every run begins with `start` and ends with exactly one `done` — even when it could not start,
      timed out, was cancelled or was refused.  A consumer never has to guess whether a run ended.
    * `error` events carry a stable CODE the PHP side can switch on:
        tier_unsupported   the permission tier asked for has no mapping in the adapter  (never run)
        start_failed       the program was not found / could not be started               (exit 127)
        timeout            wall-clock limit                                                (exit 124, retryable)
        cancelled          the caller cancelled                                            (exit 130)
        output_limit       the raw output cap was hit                                      (exit 125)
        tool_error         the tool itself reported failure (parsed from its output)
        exit_code          the process ended non-zero without saying why
        http_error         the model server answered with an error status / could not be reached
    * RECORD writes every raw line to a fixture file; REPLAY feeds a fixture through the same parser
      without starting anything.  A vendor that changes its output format shows up as a failing replay.
  ============================================================================= *)
unit aic_run;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, aic_events, aic_adapter, aic_parse, aic_proc, aic_http;

type
  TRunner = class
  private
    FEm: TEventEmitter;
    FParser: TParser;
    FRecord: TStringList;           // raw lines being recorded (written at the end)
    FCancel: Boolean;
    FStarted: QWord;
    procedure OnProcLine(const Line: string; IsStderr: Boolean);
    procedure OnHttpLine(const Line: string);
    function CancelNow: Boolean;
    function ExpandJson(D: TJSONData; const Req: TRunRequest): TJSONData;
    function Finish(Ad: TAdapter; const Req: TRunRequest; ExitCode: Integer; TimedOut, Cancelled, Capped: Boolean;
      const StartErr, HttpErr: string; HttpStatus: Integer): Integer;
  public
    RecordFile: string;              // when set, the raw output is saved here
    LastSessionId: string;           // the session id the agent reported at the end of the last run (for resume)
    ClientGone: TCancelCheck;        // optional probe: the one who asked has disconnected -> cancel (service mode)
    ExtraEnv: TStringList;           // KEY=VALUE additions for THIS run (e.g. CLAUDE_CONFIG_DIR=...), owned by the caller
    constructor Create(AEm: TEventEmitter);
    destructor Destroy; override;
    { The whole run.  Returns the exit code the CLI should use. }
    function Run(Ad: TAdapter; const Req: TRunRequest): Integer;
    { Same events, but the raw output comes from a recorded fixture instead of a process. }
    function Replay(Ad: TAdapter; const Req: TRunRequest; const FixtureFile: string): Integer;
    procedure Cancel;
  end;

implementation

constructor TRunner.Create(AEm: TEventEmitter);
begin
  inherited Create;
  FEm := AEm;
  FRecord := TStringList.Create;
end;

destructor TRunner.Destroy;
begin
  FRecord.Free;
  FParser.Free;
  inherited Destroy;
end;

procedure TRunner.Cancel;
begin
  FCancel := True;
end;

function TRunner.CancelNow: Boolean;
begin
  // polled every ~50 ms by the process loop and on every chunk of an HTTP stream
  if (not FCancel) and Assigned(ClientGone) and ClientGone() then FCancel := True;
  Result := FCancel;
end;

procedure TRunner.OnProcLine(const Line: string; IsStderr: Boolean);
var
  r: TJSONObject;
begin
  if RecordFile <> '' then
  begin
    r := TJSONObject.Create(['s', Ord(IsStderr), 'l', SanitizeUtf8(Line)]);
    FRecord.Add(r.AsJSON);
    r.Free;
  end;
  if IsStderr then FEm.Log('stderr', Line)
  else FParser.Feed(Line);
end;

procedure TRunner.OnHttpLine(const Line: string);
begin
  OnProcLine(Line, False);
end;

{ The chat conversation for a request: [system] + history (Req.Messages, a JSON array) + the prompt as the last user turn. }
function BuildMessages(const Req: TRunRequest): TJSONArray;
var
  hist: TJSONData;
  i: Integer;
begin
  Result := TJSONArray.Create;
  if Req.System <> '' then Result.Add(TJSONObject.Create(['role', 'system', 'content', Req.System]));
  if Req.Messages <> '' then
  begin
    try
      hist := GetJSON(Req.Messages);
    except
      hist := nil;
    end;
    if (hist <> nil) and (hist.JSONType = jtArray) then
      for i := 0 to TJSONArray(hist).Count - 1 do Result.Add(TJSONArray(hist)[i].Clone);
    hist.Free;
  end;
  if Req.Prompt <> '' then Result.Add(TJSONObject.Create(['role', 'user', 'content', Req.Prompt]));
end;

{ Clone a JSON template, replacing {prompt} {model} ... inside every string value. }
function TRunner.ExpandJson(D: TJSONData; const Req: TRunRequest): TJSONData;
var
  i: Integer;
  a: TJSONArray;
  o: TJSONObject;
begin
  case D.JSONType of
    jtString:
      if D.AsString = '{messages}' then Result := BuildMessages(Req)       // a whole JSON array, not a string
      else Result := TJSONString.Create(ExpandPlaceholders(D.AsString, Req));
    jtObject:
      begin
        o := TJSONObject.Create;
        for i := 0 to TJSONObject(D).Count - 1 do
          o.Add(TJSONObject(D).Names[i], ExpandJson(TJSONObject(D).Items[i], Req));
        Result := o;
      end;
    jtArray:
      begin
        a := TJSONArray.Create;
        for i := 0 to TJSONArray(D).Count - 1 do a.Add(ExpandJson(TJSONArray(D)[i], Req));
        Result := a;
      end;
  else
    Result := D.Clone;
  end;
end;

function TRunner.Finish(Ad: TAdapter; const Req: TRunRequest; ExitCode: Integer; TimedOut, Cancelled, Capped: Boolean;
  const StartErr, HttpErr: string; HttpStatus: Integer): Integer;
var
  code: Integer;
  secs: Double;
  sid: string;
begin
  FParser.Finish;
  secs := (GetTickCount64 - FStarted) / 1000.0;
  code := ExitCode;
  if StartErr <> '' then begin FEm.Error('start_failed', StartErr, False); code := 127; end
  else if TimedOut then begin FEm.Error('timeout', 'the run exceeded its time limit', True); code := 124; end
  else if Cancelled then begin FEm.Error('cancelled', 'the run was cancelled', False); code := 130; end
  else if Capped then begin FEm.Error('output_limit', 'the run produced more output than the limit allows', False); code := 125; end
  else if HttpErr <> '' then begin FEm.Error('http_error', HttpErr, True); if code = 0 then code := 1; end
  else if (HttpStatus <> 0) and ((HttpStatus < 200) or (HttpStatus >= 300)) then
  begin
    FEm.Error('http_error', 'the server answered HTTP ' + IntToStr(HttpStatus), HttpStatus >= 500); if code = 0 then code := 1;
  end
  else if FParser.IsError then begin FEm.Error('tool_error', FParser.ErrorText, False); if code = 0 then code := 1; end
  else if code <> 0 then FEm.Error('exit_code', 'the process exited with status ' + IntToStr(code), False);

  FEm.Usage(FParser.InputTokens, FParser.OutputTokens, FParser.CostUsd, secs);
  sid := FParser.SessionId;
  if sid = '' then sid := Req.SessionId;
  LastSessionId := sid;
  FEm.Done(code, sid);
  Result := code;

  if (RecordFile <> '') and (FRecord.Count > 0) then
  begin
    FRecord.Add(TJSONObject.Create(['exit', code]).AsJSON);
    FRecord.SaveToFile(RecordFile);
  end;
end;

function TRunner.Run(Ad: TAdapter; const Req: TRunRequest): Integer;
var
  args: TStringList;
  err: string;
  env: TStringList;
  i: Integer;
  envObj: TJSONObject;
  res: TProcResult;
  stdinData: string;
  hres: THttpResult;
  body: TJSONData;
  secrets: TStringList;
  tmo, capkb: Integer;
begin
  FStarted := GetTickCount64;
  FCancel := False;
  FParser.Free;
  FParser := MakeParser(Ad.Parser, FEm, Ad.Doc);

  secrets := TStringList.Create;
  try
    Ad.SecretValues(secrets);
    for i := 0 to secrets.Count - 1 do FEm.AddSecret(secrets[i]);
  finally
    secrets.Free;
  end;

  FEm.Start(Ad.Id, Req.Model, Req.SessionId);
  tmo := Ad.LimitTimeout(Req);
  capkb := Ad.LimitOutputKB(Req);

  if Ad.Transport = 'http' then
  begin
    // permission tiers do not apply to a model API (it has no tools); the request body is the whole story
    body := ExpandJson(Ad.Doc.Find('body'), Req);
    try
      hres := HttpStreamPost(ExpandPlaceholders(Ad.Url, Req), body.AsJSON, tmo, @OnHttpLine, @CancelNow);
    finally
      body.Free;
    end;
    Result := Finish(Ad, Req, 0, hres.TimedOut, hres.Cancelled, False, '', hres.Error, hres.Status);
  end
  else
  begin
    args := nil;
    if not Ad.BuildArgs(Req, args, err) then
    begin
      FEm.Error('tier_unsupported', err, False);
      FEm.Usage(0, 0, 0, 0);
      FEm.Done(2, Req.SessionId);
      args.Free;
      Exit(2);
    end;
    env := TStringList.Create;
    try
      envObj := Ad.Doc.Get('env', TJSONObject(nil));
      if envObj <> nil then
        for i := 0 to envObj.Count - 1 do env.Add(envObj.Names[i] + '=' + ExpandPlaceholders(envObj.Items[i].AsString, Req));
      if Assigned(ExtraEnv) then env.AddStrings(ExtraEnv);          // per-run additions win over the adapter's own
      stdinData := '';
      if Ad.PromptVia = 'stdin' then stdinData := Req.Prompt;
      res := RunProcess(Ad.Command, args, Req.Cwd, env, stdinData, tmo, capkb, @OnProcLine, @CancelNow);
      Result := Finish(Ad, Req, res.ExitCode, res.TimedOut, res.Cancelled, res.OutputCapped, res.StartError, '', 0);
    finally
      env.Free;
      args.Free;
    end;
  end;
end;

function TRunner.Replay(Ad: TAdapter; const Req: TRunRequest; const FixtureFile: string): Integer;
var
  sl: TStringList;
  i: Integer;
  d: TJSONData;
  o: TJSONObject;
  code: Integer;
begin
  FStarted := GetTickCount64;
  FParser.Free;
  FParser := MakeParser(Ad.Parser, FEm, Ad.Doc);
  FEm.Start(Ad.Id, Req.Model, Req.SessionId);
  code := 0;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(FixtureFile);
    for i := 0 to sl.Count - 1 do
    begin
      d := GetJSON(sl[i]);
      try
        o := TJSONObject(d);
        if o.Find('exit') <> nil then code := o.Get('exit', 0)
        else OnProcLine(o.Get('l', ''), o.Get('s', 0) = 1);
      finally
        d.Free;
      end;
    end;
  finally
    sl.Free;
  end;
  Result := Finish(Ad, Req, code, False, False, False, '', '', 0);
end;

end.
