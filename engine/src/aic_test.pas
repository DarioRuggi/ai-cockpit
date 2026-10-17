(* =============================================================================
  aic_test — `aicengine test`: run each adapter's declared tests and print a pass/fail table.

  A test lives in the adapter file under "tests":

    { "name": "streams text",
      "request": {"prompt": "...", "model": "", "tier": "read_only", "timeout_s": 5, "env": {...}},
      "replay": "fixtures/claude_ok.jsonl",          (replay mode only; omit to run live)
      "live":   true,                                  (also run in --live mode; default true)
      "expect": { "exit": 0,
                  "text_contains": ["..."], "text_not_contains": ["..."],
                  "error_code": "timeout" | "none",
                  "events_include": ["tool_call"],
                  "events_order": ["start","text","done"],     (as a subsequence)
                  "max_ms": 3000,
                  "single_done": true } }

  Every test is judged ONLY from the event stream, never from the child's internals: if a test passes,
  a consumer reading that stream would have seen the right thing.
  ============================================================================= *)
unit aic_test;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, aic_events, aic_adapter, aic_run;

type
  TCollector = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Line: string);
  end;

{ Returns the number of failed tests.  Mode: 'replay' or 'live'. }
function RunAdapterTests(Ads: TAdapterList; const Which, Mode, BaseDir: string; Verbose: Boolean): Integer;

implementation

constructor TCollector.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TCollector.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

procedure TCollector.Add(const Line: string);
begin
  Lines.Add(Line);
end;

function JsonStrList(D: TJSONData): TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  if (D <> nil) and (D.JSONType = jtArray) then
    for i := 0 to TJSONArray(D).Count - 1 do Result.Add(TJSONArray(D)[i].AsString);
end;

{ Judge one test.  Returns '' on pass, else a short reason. }
function Judge(Col: TCollector; Expect: TJSONObject; ElapsedMs: Int64): string;
var
  i, p, doneCount, exitCode: Integer;
  o: TJSONObject;
  d: TJSONData;
  ty, text, errCode, doneSession: string;
  uIn, uOut: Int64;
  types, want: TStringList;
begin
  Result := '';
  text := ''; errCode := ''; doneSession := ''; doneCount := 0; exitCode := -999; uIn := -1; uOut := -1;
  types := TStringList.Create;
  try
    for i := 0 to Col.Lines.Count - 1 do
    begin
      d := nil;
      try d := GetJSON(Col.Lines[i]); except d := nil; end;
      if (d = nil) or (d.JSONType <> jtObject) then begin d.Free; Exit('an event line is not valid JSON: ' + Copy(Col.Lines[i], 1, 80)); end;
      o := TJSONObject(d);
      try
        ty := o.Get('type', '');
        types.Add(ty);
        if ty = 'text' then text := text + o.Get('delta', '');
        if ty = 'error' then errCode := o.Get('code', '');
        if ty = 'done' then begin Inc(doneCount); exitCode := o.Get('exit_code', -1); doneSession := o.Get('session_id', ''); end;
        if ty = 'usage' then begin uIn := o.Get('input_tokens', Int64(0)); uOut := o.Get('output_tokens', Int64(0)); end;
        if o.Get('seq', 0) <> i + 1 then begin Result := 'seq is not 1..n (event ' + IntToStr(i + 1) + ' has seq ' + IntToStr(o.Get('seq', 0)) + ')'; Exit; end;
      finally
        d.Free;
      end;
    end;

    if (types.Count = 0) or (types[0] <> 'start') then Exit('first event is not "start"');
    if doneCount <> 1 then Exit('expected exactly one "done", saw ' + IntToStr(doneCount));
    if types[types.Count - 1] <> 'done' then Exit('"done" is not the last event');

    if Expect = nil then Exit;
    if Expect.Find('exit') <> nil then
      if exitCode <> Expect.Get('exit', 0) then Exit('exit code ' + IntToStr(exitCode) + ', wanted ' + IntToStr(Expect.Get('exit', 0)));
    if (Expect.Find('done_session') <> nil) and (doneSession <> Expect.Get('done_session', '')) then Exit('done.session_id is "' + doneSession + '"');
    if (Expect.Find('usage_in') <> nil) and (uIn <> Expect.Get('usage_in', 0)) then Exit('usage.input_tokens is ' + IntToStr(uIn));
    if (Expect.Find('usage_out') <> nil) and (uOut <> Expect.Get('usage_out', 0)) then Exit('usage.output_tokens is ' + IntToStr(uOut));
    if Expect.Find('error_code') <> nil then
    begin
      if Expect.Get('error_code', '') = 'none' then begin if errCode <> '' then Exit('unexpected error event: ' + errCode); end
      else if errCode <> Expect.Get('error_code', '') then Exit('error code "' + errCode + '", wanted "' + Expect.Get('error_code', '') + '"');
    end;
    want := JsonStrList(Expect.Find('text_contains'));
    try
      for i := 0 to want.Count - 1 do
        if Pos(want[i], text) = 0 then Exit('text does not contain "' + Copy(want[i], 1, 40) + '"');
    finally want.Free; end;
    want := JsonStrList(Expect.Find('text_not_contains'));
    try
      for i := 0 to want.Count - 1 do
        if Pos(want[i], text) > 0 then Exit('text contains forbidden "' + Copy(want[i], 1, 40) + '"');
    finally want.Free; end;
    want := JsonStrList(Expect.Find('events_include'));
    try
      for i := 0 to want.Count - 1 do
        if types.IndexOf(want[i]) < 0 then Exit('no "' + want[i] + '" event');
    finally want.Free; end;
    want := JsonStrList(Expect.Find('events_order'));
    try
      p := -1;
      for i := 0 to want.Count - 1 do
      begin
        p := types.IndexOf(want[i]);       // first occurrence after the previous match
        if p < 0 then Exit('event order broken at "' + want[i] + '"');
        // consume up to and including p so the next search is a true subsequence
        types.Delete(p);
        while p > 0 do begin types.Delete(0); Dec(p); end;
      end;
    finally want.Free; end;
    if (Expect.Find('max_ms') <> nil) and (ElapsedMs > Expect.Get('max_ms', 0)) then
      Exit('took ' + IntToStr(ElapsedMs) + ' ms, limit ' + IntToStr(Expect.Get('max_ms', 0)));
  finally
    types.Free;
  end;
end;

function RunOne(Ad: TAdapter; T: TJSONObject; const Mode, BaseDir: string; out Reason: string): Boolean;
var
  Col: TCollector;
  Em: TEventEmitter;
  Rn: TRunner;
  Req: TRunRequest;
  rq: TJSONObject;
  t0: QWord;
  fx: string;
  e: TJSONObject;
  i: Integer;
begin
  Result := False;
  FillChar(Req, SizeOf(Req), 0);
  rq := T.Get('request', TJSONObject(nil));
  if rq <> nil then
  begin
    Req.Prompt := rq.Get('prompt', '');
    Req.Model := rq.Get('model', '');
    Req.System := rq.Get('system', '');
    Req.Messages := rq.Get('messages', '');
    Req.SessionId := rq.Get('session', '');
    Req.Tier := rq.Get('tier', '');
    Req.TimeoutS := rq.Get('timeout_s', 0);
    Req.MaxOutputKB := rq.Get('max_output_kb', 0);
    Req.Cwd := rq.Get('cwd', '');
  end;
  Col := TCollector.Create;
  Em := TEventEmitter.Create('test', @Col.Add);
  Rn := TRunner.Create(Em);
  try
    t0 := GetTickCount64;
    if Mode = 'replay' then
    begin
      fx := T.Get('replay', '');
      if fx = '' then begin Reason := 'skipped (no replay fixture)'; Exit(True); end;
      Rn.Replay(Ad, Req, IncludeTrailingPathDelimiter(BaseDir) + fx);
    end
    else
    begin
      if not T.Get('live', True) then begin Reason := 'skipped (not a live test)'; Exit(True); end;
      Rn.Run(Ad, Req);
    end;
    e := T.Get('expect', TJSONObject(nil));
    Reason := Judge(Col, e, GetTickCount64 - t0);
    Result := Reason = '';
    if not Result then
      for i := 0 to Col.Lines.Count - 1 do
        if i < 3 then Reason := Reason + #10 + '      | ' + Copy(Col.Lines[i], 1, 140);
  finally
    Rn.Free; Em.Free; Col.Free;
  end;
end;

function RunAdapterTests(Ads: TAdapterList; const Which, Mode, BaseDir: string; Verbose: Boolean): Integer;
var
  i, j, pass, fail, skip: Integer;
  Ad: TAdapter;
  tests: TJSONData;
  T: TJSONObject;
  reason: string;
  ok: Boolean;
begin
  pass := 0; fail := 0; skip := 0;
  for i := 0 to Ads.Count - 1 do
  begin
    Ad := Ads[i];
    if (Which <> 'all') and (Which <> Ad.Id) then Continue;
    tests := Ad.Doc.Find('tests');
    if (tests = nil) or (tests.JSONType <> jtArray) then Continue;
    for j := 0 to TJSONArray(tests).Count - 1 do
    begin
      T := TJSONObject(TJSONArray(tests)[j]);
      reason := '';
      ok := RunOne(Ad, T, Mode, BaseDir, reason);
      if ok and (Copy(reason, 1, 7) = 'skipped') then
      begin
        Inc(skip);
        if Verbose then WriteLn('  skip  ', Ad.Id, ' / ', T.Get('name', '?'), '  ', reason);
      end
      else if ok then begin Inc(pass); WriteLn('  PASS  ', Ad.Id, ' / ', T.Get('name', '?')); end
      else begin Inc(fail); WriteLn('  FAIL  ', Ad.Id, ' / ', T.Get('name', '?'), '  — ', reason); end;
    end;
  end;
  WriteLn;
  WriteLn(Mode, ': ', pass, ' passed, ', fail, ' failed, ', skip, ' skipped');
  Result := fail;
end;

end.
