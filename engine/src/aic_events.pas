(* =============================================================================
  aic_events — the ONE event format every run produces.

  A run is a stream of JSON objects, one per line ("JSON lines"):

    start        run_id adapter model session_id
    text         delta                        streamed answer text
    tool_call    name args                    the agent used a tool
    tool_result  name ok summary
    file_change  path diff                    a PROPOSED edit (routed to Margin, never applied here)
    progress     stage percent
    usage        input_tokens output_tokens cost seconds
    log          level message                secrets are stripped before this is written
    error        code message retryable
    done         exit_code session_id

  Every event also carries  seq  (1,2,3 ... per run)  and  t  (milliseconds since the run started),
  so a consumer can detect a gap and a test can check ordering.

  Why one format: Cockpit today talks to each agent differently (a bash loop per agent, files in
  queue/ and responses/, polling).  With one format the PHP side, the replay tests and the
  permission checks are written once.
  ============================================================================= *)
unit aic_events;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, fpjson;

type
  { Where finished event lines go: stdout for the CLI, a socket for the service, a list for tests. }
  TEventSink = procedure(const Line: string) of object;

  TEventEmitter = class
  private
    FRunId: string;
    FSink: TEventSink;
    FSeq: Integer;
    FStartTick: QWord;
    FSecrets: TStringList;           // exact secret strings to mask in log/error text
  public
    constructor Create(const ARunId: string; ASink: TEventSink);
    destructor Destroy; override;

    { Declare a secret value (an API key from the environment, say) so it can never appear in an event. }
    procedure AddSecret(const S: string);
    function Scrub(const S: string): string;

    { Generic: Fields is owned (freed) here.  seq / t / run_id are added. }
    procedure Emit(const AType: string; Fields: TJSONObject);

    procedure Start(const Adapter, Model, SessionId: string);
    procedure Text(const Delta: string);
    procedure ToolCall(const Name: string; Args: TJSONData);     // Args is cloned, caller keeps ownership
    procedure ToolResult(const Name: string; Ok: Boolean; const Summary: string);
    procedure FileChange(const Path, Diff: string);
    procedure Progress(const Stage: string; Percent: Double);
    procedure Usage(InTok, OutTok: Int64; Cost, Seconds: Double);
    procedure Log(const Level, Msg: string);
    procedure Error(const Code, Msg: string; Retryable: Boolean);
    procedure Done(ExitCode: Integer; const SessionId: string);

    property RunId: string read FRunId;
    property Seq: Integer read FSeq;
  end;

{ Make any byte string valid UTF-8 (invalid bytes become U+FFFD) so a JSON consumer never chokes. }
function SanitizeUtf8(const S: string): string;

{ A short unique run id: yyyymmdd-hhnnss-xxxx }
function NewRunId: string;

implementation

function SanitizeUtf8(const S: string): string;
var
  i, n, need, j: Integer;
  c: Byte;
  ok: Boolean;
begin
  Result := '';
  SetLength(Result, 0);
  i := 1; n := Length(S);
  while i <= n do
  begin
    c := Ord(S[i]);
    if c < $80 then begin Result := Result + Chr(c); Inc(i); Continue; end;
    if (c >= $C2) and (c <= $DF) then need := 1
    else if (c >= $E0) and (c <= $EF) then need := 2
    else if (c >= $F0) and (c <= $F4) then need := 3
    else begin Result := Result + #$EF#$BF#$BD; Inc(i); Continue; end;   // stray continuation / invalid lead
    ok := (i + need <= n);
    if ok then
      for j := 1 to need do
        if (Ord(S[i + j]) and $C0) <> $80 then begin ok := False; Break; end;
    if ok then
    begin
      Result := Result + Copy(S, i, need + 1);
      Inc(i, need + 1);
    end
    else begin Result := Result + #$EF#$BF#$BD; Inc(i); end;
  end;
end;

function NewRunId: string;
begin
  // the process id makes ids unique across runs started in the same millisecond (Randomize alone repeats there)
  Result := FormatDateTime('yyyymmdd"-"hhnnss', Now) + '-' + IntToHex(GetProcessID and $FFFF, 4) + IntToHex(Random($100), 2);
end;

constructor TEventEmitter.Create(const ARunId: string; ASink: TEventSink);
begin
  inherited Create;
  FRunId := ARunId;
  FSink := ASink;
  FSeq := 0;
  FStartTick := GetTickCount64;
  FSecrets := TStringList.Create;
end;

destructor TEventEmitter.Destroy;
begin
  FSecrets.Free;
  inherited Destroy;
end;

procedure TEventEmitter.AddSecret(const S: string);
begin
  if Length(S) >= 6 then FSecrets.Add(S);       // shorter strings would mask ordinary words
end;

function TEventEmitter.Scrub(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  for i := 0 to FSecrets.Count - 1 do
    Result := StringReplace(Result, FSecrets[i], '[secret]', [rfReplaceAll]);
end;

procedure TEventEmitter.Emit(const AType: string; Fields: TJSONObject);
var
  o: TJSONObject;
  i: Integer;
begin
  Inc(FSeq);
  o := TJSONObject.Create;
  try
    o.Add('type', AType);
    o.Add('run_id', FRunId);
    o.Add('seq', FSeq);
    o.Add('t', Int64(GetTickCount64 - FStartTick));
    if Assigned(Fields) then
      for i := 0 to Fields.Count - 1 do
        o.Add(Fields.Names[i], Fields.Items[i].Clone);
    if Assigned(FSink) then FSink(o.FormatJSON([foSingleLineArray, foSingleLineObject, foSkipWhiteSpace], 0));
  finally
    o.Free;
    Fields.Free;
  end;
end;

procedure TEventEmitter.Start(const Adapter, Model, SessionId: string);
begin
  Emit('start', TJSONObject.Create(['adapter', Adapter, 'model', Model, 'session_id', SessionId]));
end;

procedure TEventEmitter.Text(const Delta: string);
begin
  Emit('text', TJSONObject.Create(['delta', SanitizeUtf8(Scrub(Delta))]));
end;

procedure TEventEmitter.ToolCall(const Name: string; Args: TJSONData);
var
  o: TJSONObject;
begin
  o := TJSONObject.Create(['name', Name]);
  if Assigned(Args) then o.Add('args', Args.Clone) else o.Add('args', TJSONObject.Create);
  Emit('tool_call', o);
end;

procedure TEventEmitter.ToolResult(const Name: string; Ok: Boolean; const Summary: string);
begin
  Emit('tool_result', TJSONObject.Create(['name', Name, 'ok', Ok, 'summary', SanitizeUtf8(Scrub(Summary))]));
end;

procedure TEventEmitter.FileChange(const Path, Diff: string);
begin
  Emit('file_change', TJSONObject.Create(['path', Path, 'diff', SanitizeUtf8(Diff)]));
end;

procedure TEventEmitter.Progress(const Stage: string; Percent: Double);
begin
  Emit('progress', TJSONObject.Create(['stage', Stage, 'percent', RoundTo(Percent, -2)]));
end;

procedure TEventEmitter.Usage(InTok, OutTok: Int64; Cost, Seconds: Double);
begin
  if Abs(Cost) < 1e-9 then Cost := 0;          // avoid printing float noise such as 0E-16
  if Abs(Seconds) < 1e-9 then Seconds := 0;
  Emit('usage', TJSONObject.Create(['input_tokens', InTok, 'output_tokens', OutTok, 'cost', RoundTo(Cost, -6), 'seconds', RoundTo(Seconds, -3)]));
end;

procedure TEventEmitter.Log(const Level, Msg: string);
begin
  Emit('log', TJSONObject.Create(['level', Level, 'message', SanitizeUtf8(Scrub(Msg))]));
end;

procedure TEventEmitter.Error(const Code, Msg: string; Retryable: Boolean);
begin
  Emit('error', TJSONObject.Create(['code', Code, 'message', SanitizeUtf8(Scrub(Msg)), 'retryable', Retryable]));
end;

procedure TEventEmitter.Done(ExitCode: Integer; const SessionId: string);
begin
  Emit('done', TJSONObject.Create(['exit_code', ExitCode, 'session_id', SessionId]));
end;

end.
