(* =============================================================================
  aic_parse — output parsers: one tool's native output -> the common events.

  A parser is fed ONE LINE at a time (Feed) and told when the stream ended (Finish).  It never touches
  the process or the network, so the same parser serves a live run, a recorded run (replay) and a test.

    plain               every line is answer text
    claude_stream_json  Claude Code  `-p --output-format stream-json`: system / assistant / user / result
                        (and stream_event deltas when partial messages are on)
    ollama_ndjson       Ollama /api/generate and /api/chat streams: {"response":"tok","done":false}
    jsonl_generic       any JSON-lines tool: adapter says which key holds the text

  A line that is not valid JSON in a JSON parser is NOT dropped: it becomes a `log` event at level "raw",
  because vendors print banners, warnings and update notices on the same stream, and losing them hides
  why a run misbehaved.
  ============================================================================= *)
unit aic_parse;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, aic_events;

type
  TParser = class
  protected
    FEm: TEventEmitter;
  public
    SessionId: string;           // learned from the stream (used for resume)
    InputTokens, OutputTokens: Int64;
    CostUsd: Double;
    GotResult: Boolean;          // the tool said it finished
    IsError: Boolean;            // the tool said it failed
    ErrorText: string;
    constructor Create(AEm: TEventEmitter); virtual;
    procedure Feed(const Line: string); virtual; abstract;
    procedure Finish; virtual;
  end;

  TPlainParser = class(TParser)
    procedure Feed(const Line: string); override;
  end;

  TClaudeStreamParser = class(TParser)
  private
    FSawDelta: Boolean;          // streamed deltas already delivered the text; do not repeat it from the final message
    procedure HandleContent(Arr: TJSONArray);
  public
    procedure Feed(const Line: string); override;
  end;

  TOllamaParser = class(TParser)
  public
    procedure Feed(const Line: string); override;
  end;

  { OpenAI-compatible streaming (LocalAI, LM Studio, vLLM, llama.cpp server, Groq, OpenRouter ...):
      data: {"choices":[{"delta":{"content":"tok"}}]}      one per token
      data: {"choices":[],"usage":{"prompt_tokens":N,"completion_tokens":M}}   (when the server reports usage)
      data: [DONE]
    Blank lines and ":" comment lines (keep-alives) are ignored.  An {"error":{...}} object is a failure. }
  TOpenAiSseParser = class(TParser)
  public
    procedure Feed(const Line: string); override;
  end;

  TJsonlGenericParser = class(TParser)
  private
    FTextKey: string;
  public
    constructor Create(AEm: TEventEmitter; const ATextKey: string);
    procedure Feed(const Line: string); override;
  end;

function MakeParser(const Name: string; AEm: TEventEmitter; AdapterDoc: TJSONObject): TParser;

implementation

constructor TParser.Create(AEm: TEventEmitter);
begin
  inherited Create;
  FEm := AEm;
end;

procedure TParser.Finish;
begin
end;

{ Parse a line as a JSON object; nil (and a raw log) when it is not one. }
function ParseObj(const Line: string; Em: TEventEmitter): TJSONObject;
var
  d: TJSONData;
begin
  Result := nil;
  if Trim(Line) = '' then Exit;
  try
    d := GetJSON(Line);
  except
    d := nil;
  end;
  if (d <> nil) and (d.JSONType = jtObject) then Result := TJSONObject(d)
  else
  begin
    d.Free;
    Em.Log('raw', Line);
  end;
end;

{ ---- plain ------------------------------------------------------------------------------------- }

procedure TPlainParser.Feed(const Line: string);
begin
  FEm.Text(Line + #10);
end;

{ ---- Claude Code stream-json ------------------------------------------------------------------- }

procedure TClaudeStreamParser.HandleContent(Arr: TJSONArray);
var
  i: Integer;
  b: TJSONObject;
  ty: string;
  s: string;
begin
  for i := 0 to Arr.Count - 1 do
  begin
    if Arr[i].JSONType <> jtObject then Continue;
    b := TJSONObject(Arr[i]);
    ty := b.Get('type', '');
    if ty = 'text' then
    begin
      if not FSawDelta then FEm.Text(b.Get('text', ''));
    end
    else if ty = 'tool_use' then
      FEm.ToolCall(b.Get('name', ''), b.Find('input'))
    else if ty = 'tool_result' then
    begin
      s := '';
      if b.Find('content') <> nil then
      begin
        if b.Find('content').JSONType = jtString then s := b.Find('content').AsString
        else s := b.Find('content').AsJSON;
      end;
      FEm.ToolResult(b.Get('tool_use_id', ''), not b.Get('is_error', False), Copy(s, 1, 400));
    end;
  end;
end;

procedure TClaudeStreamParser.Feed(const Line: string);
var
  o, msg, ev, delta, u: TJSONObject;
  ty, sub: string;
  c: TJSONData;
begin
  o := ParseObj(Line, FEm);
  if o = nil then Exit;
  try
    ty := o.Get('type', '');
    if o.Find('session_id') <> nil then SessionId := o.Get('session_id', SessionId);

    if ty = 'system' then
    begin
      sub := o.Get('subtype', '');
      if sub = 'init' then begin end
      else if Copy(sub, 1, 5) = 'hook_' then FEm.Log('debug', 'system:' + sub)     // user hooks (plugins) chatter here
      else FEm.Log('info', 'system:' + sub);
    end
    else if ty = 'stream_event' then
    begin
      ev := o.Get('event', TJSONObject(nil));
      if (ev <> nil) and (ev.Get('type', '') = 'content_block_delta') then
      begin
        delta := ev.Get('delta', TJSONObject(nil));
        if (delta <> nil) and (delta.Get('type', '') = 'text_delta') then
        begin
          FSawDelta := True;
          FEm.Text(delta.Get('text', ''));
        end;
      end;
    end
    else if ty = 'assistant' then
    begin
      msg := o.Get('message', TJSONObject(nil));
      if msg <> nil then
      begin
        c := msg.Find('content');
        if (c <> nil) and (c.JSONType = jtArray) then HandleContent(TJSONArray(c));
      end;
      FSawDelta := False;            // next message starts fresh
    end
    else if ty = 'user' then
    begin
      msg := o.Get('message', TJSONObject(nil));
      if msg <> nil then
      begin
        c := msg.Find('content');
        if (c <> nil) and (c.JSONType = jtArray) then HandleContent(TJSONArray(c));
      end;
    end
    else if ty = 'result' then
    begin
      GotResult := True;
      IsError := o.Get('is_error', False) or (o.Get('subtype', 'success') <> 'success');
      if IsError then ErrorText := o.Get('result', o.Get('subtype', 'error'));
      CostUsd := o.Get('total_cost_usd', 0.0);
      u := o.Get('usage', TJSONObject(nil));
      if u <> nil then
      begin
        InputTokens := u.Get('input_tokens', Int64(0));
        OutputTokens := u.Get('output_tokens', Int64(0));
      end;
    end
    else
      FEm.Log('info', 'unhandled event type: ' + ty);
  finally
    o.Free;
  end;
end;

{ ---- Ollama NDJSON ----------------------------------------------------------------------------- }

procedure TOllamaParser.Feed(const Line: string);
var
  o, m: TJSONObject;
  s: string;
begin
  o := ParseObj(Line, FEm);
  if o = nil then Exit;
  try
    if o.Find('error') <> nil then
    begin
      IsError := True; ErrorText := o.Get('error', '');
      Exit;
    end;
    s := o.Get('response', '');                        // /api/generate
    if (s = '') then
    begin
      m := o.Get('message', TJSONObject(nil));         // /api/chat
      if m <> nil then s := m.Get('content', '');
    end;
    if s <> '' then FEm.Text(s);
    if o.Get('done', False) then
    begin
      GotResult := True;
      InputTokens := o.Get('prompt_eval_count', Int64(0));
      OutputTokens := o.Get('eval_count', Int64(0));
    end;
  finally
    o.Free;
  end;
end;

{ ---- OpenAI-style SSE ---------------------------------------------------------------------------- }

procedure TOpenAiSseParser.Feed(const Line: string);
var
  o, ch, delta, u, er: TJSONObject;
  payload, s: string;
  arr: TJSONData;
begin
  if (Line = '') or (Line[1] = ':') then Exit;                 // blank / keep-alive
  if Copy(Line, 1, 5) <> 'data:' then begin FEm.Log('raw', Line); Exit; end;
  payload := Trim(Copy(Line, 6, MaxInt));
  if payload = '[DONE]' then begin GotResult := True; Exit; end;
  o := ParseObj(payload, FEm);
  if o = nil then Exit;
  try
    er := o.Get('error', TJSONObject(nil));
    if er <> nil then begin IsError := True; ErrorText := er.Get('message', 'error'); Exit; end;
    arr := o.Find('choices');
    if (arr <> nil) and (arr.JSONType = jtArray) and (TJSONArray(arr).Count > 0) and (TJSONArray(arr)[0].JSONType = jtObject) then
    begin
      ch := TJSONObject(TJSONArray(arr)[0]);
      delta := ch.Get('delta', TJSONObject(nil));
      if delta <> nil then
      begin
        s := delta.Get('content', '');
        if s <> '' then FEm.Text(s);
      end;
    end;
    u := o.Get('usage', TJSONObject(nil));
    if u <> nil then
    begin
      InputTokens := u.Get('prompt_tokens', Int64(0));
      OutputTokens := u.Get('completion_tokens', Int64(0));
    end;
  finally
    o.Free;
  end;
end;

{ ---- generic JSON lines ------------------------------------------------------------------------ }

constructor TJsonlGenericParser.Create(AEm: TEventEmitter; const ATextKey: string);
begin
  inherited Create(AEm);
  FTextKey := ATextKey;
end;

procedure TJsonlGenericParser.Feed(const Line: string);
var
  o: TJSONObject;
  s: string;
begin
  o := ParseObj(Line, FEm);
  if o = nil then Exit;
  try
    s := o.Get(FTextKey, '');
    if s <> '' then FEm.Text(s) else FEm.Log('info', Copy(Line, 1, 200));
  finally
    o.Free;
  end;
end;

function MakeParser(const Name: string; AEm: TEventEmitter; AdapterDoc: TJSONObject): TParser;
begin
  if Name = 'claude_stream_json' then Result := TClaudeStreamParser.Create(AEm)
  else if Name = 'ollama_ndjson' then Result := TOllamaParser.Create(AEm)
  else if Name = 'openai_sse' then Result := TOpenAiSseParser.Create(AEm)
  else if Name = 'jsonl_generic' then
    Result := TJsonlGenericParser.Create(AEm, AdapterDoc.Get('text_key', 'text'))
  else Result := TPlainParser.Create(AEm);
end;

end.
