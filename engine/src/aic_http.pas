(* =============================================================================
  aic_http — the HTTP transport: a streaming POST to a LOCAL model server (Ollama, LocalAI).

  Plain http:// only, on purpose.  FPC 3.2.2's TLS support cannot load OpenSSL 3 (the same fault that
  broke cockpit_auth), so https:// is refused here with a clear error; cloud APIs go through the
  PROCESS transport using `curl` as the child (adapter "command": "curl"), which every supported OS has.

  The response body is handed to the caller line by line AS IT ARRIVES (NDJSON from Ollama,
  `data:` lines from an SSE server), so text appears while the model is still generating.
  ============================================================================= *)
unit aic_http;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fphttpclient;

type
  THttpLineEvent = procedure(const Line: string) of object;
  THttpCancel = function: Boolean of object;

  THttpResult = record
    Status: Integer;          // 0 = could not connect / no response
    Error: string;
    TimedOut, Cancelled: Boolean;
    BytesRead: Int64;
  end;

function HttpStreamPost(const Url, Body: string; TimeoutS: Integer; OnLine: THttpLineEvent;
  Cancel: THttpCancel; const ExtraHeaders: TStrings = nil; DropPartial: Boolean = False): THttpResult;

{ A short GET used by detect (is the server up?).  Returns the status, 0 when nothing answered. }
function HttpGetStatus(const Url: string; TimeoutMs: Integer; out Body: string): Integer;

implementation

type
  EStreamStop = class(Exception);

  { Receives the response body and slices it into lines for the caller. }
  TLineSink = class(TStream)
  private
    FBuf: string;
    FOnLine: THttpLineEvent;
    FCancel: THttpCancel;
    FDeadline: QWord;
  public
    DropPartial: Boolean;               // a last line with no newline is NOT delivered (what `while read` does)
    Total: Int64;
    StopReason: string;                  // '' | timeout | cancel
    constructor Create(AOnLine: THttpLineEvent; ACancel: THttpCancel; ADeadline: QWord);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
    procedure Flush;
  end;

{ For detect: a probe needs the STATUS, not the body.  Stop as soon as the first body bytes arrive, so a
  streaming endpoint (which never ends) cannot hold the probe up. }
type
  TFirstChunkStop = class(TStream)
  public
    First: string;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
  end;

function TFirstChunkStop.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TFirstChunkStop.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := 0;
end;

function TFirstChunkStop.Write(const Buffer; Count: Longint): Longint;
begin
  SetString(First, PChar(@Buffer), Count);
  raise EStreamStop.Create('first chunk');
end;

constructor TLineSink.Create(AOnLine: THttpLineEvent; ACancel: THttpCancel; ADeadline: QWord);
begin
  inherited Create;
  FOnLine := AOnLine; FCancel := ACancel; FDeadline := ADeadline;
end;

function TLineSink.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TLineSink.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := 0;
end;

function TLineSink.Write(const Buffer; Count: Longint): Longint;
var
  s: string;
  p: Integer;
  ln: string;
begin
  if Assigned(FCancel) and FCancel() then begin StopReason := 'cancel'; raise EStreamStop.Create('cancel'); end;
  if (FDeadline > 0) and (GetTickCount64 > FDeadline) then begin StopReason := 'timeout'; raise EStreamStop.Create('timeout'); end;
  SetString(s, PChar(@Buffer), Count);
  Inc(Total, Count);
  FBuf := FBuf + s;
  repeat
    p := Pos(#10, FBuf);
    if p = 0 then Break;
    ln := Copy(FBuf, 1, p - 1);
    Delete(FBuf, 1, p);
    if (Length(ln) > 0) and (ln[Length(ln)] = #13) then SetLength(ln, Length(ln) - 1);
    if Assigned(FOnLine) then FOnLine(ln);
  until False;
  Result := Count;
end;

procedure TLineSink.Flush;
begin
  if (FBuf <> '') and Assigned(FOnLine) and not DropPartial then FOnLine(FBuf);
  FBuf := '';
end;

function HttpStreamPost(const Url, Body: string; TimeoutS: Integer; OnLine: THttpLineEvent;
  Cancel: THttpCancel; const ExtraHeaders: TStrings; DropPartial: Boolean): THttpResult;
var
  C: TFPHTTPClient;
  Sink: TLineSink;
  Req: TStringStream;
  dl: QWord;
  i: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  if LowerCase(Copy(Url, 1, 8)) = 'https://' then
  begin
    Result.Error := 'https is not supported by the built-in client (FPC 3.2.2 cannot load OpenSSL 3); use the curl process transport';
    Exit;
  end;
  if TimeoutS > 0 then dl := GetTickCount64 + QWord(TimeoutS) * 1000 else dl := 0;
  C := TFPHTTPClient.Create(nil);
  Sink := TLineSink.Create(OnLine, Cancel, dl);
  Sink.DropPartial := DropPartial;
  Req := TStringStream.Create(Body);
  try
    C.AddHeader('Content-Type', 'application/json');
    if Assigned(ExtraHeaders) then
      for i := 0 to ExtraHeaders.Count - 1 do C.AddHeader(ExtraHeaders.Names[i], ExtraHeaders.ValueFromIndex[i]);
    C.RequestBody := Req;
    // inactivity timeout; the overall deadline is checked as data arrives
    if TimeoutS > 0 then C.IOTimeout := TimeoutS * 1000 else C.IOTimeout := 600000;
    C.ConnectTimeout := 5000;
    try
      C.HTTPMethod('POST', Url, Sink, []);
      Result.Status := C.ResponseStatusCode;
      Sink.Flush;
    except
      on E: EStreamStop do
      begin
        Result.TimedOut := Sink.StopReason = 'timeout';
        Result.Cancelled := Sink.StopReason = 'cancel';
        Result.Status := C.ResponseStatusCode;
      end;
      on E: Exception do
      begin
        Result.Status := C.ResponseStatusCode;
        Result.Error := E.Message;
        Sink.Flush;
        if (Pos('timed out', LowerCase(E.Message)) > 0) or (Pos('timeout', LowerCase(E.Message)) > 0) then Result.TimedOut := True;
        // the socket library words a read timeout as "Error reading data from socket": judge by the clock instead
        if (dl > 0) and (GetTickCount64 + 150 >= dl) then Result.TimedOut := True;
      end;
    end;
    Result.BytesRead := Sink.Total;
  finally
    Req.Free; Sink.Free; C.Free;
  end;
end;

function HttpGetStatus(const Url: string; TimeoutMs: Integer; out Body: string): Integer;
var
  C: TFPHTTPClient;
  S: TFirstChunkStop;
begin
  Result := 0;
  Body := '';
  if LowerCase(Copy(Url, 1, 8)) = 'https://' then Exit;
  C := TFPHTTPClient.Create(nil);
  S := TFirstChunkStop.Create;
  try
    C.ConnectTimeout := TimeoutMs;
    C.IOTimeout := TimeoutMs;
    try
      C.HTTPMethod('GET', Url, S, []);
      Result := C.ResponseStatusCode;
    except
      // stopping at the first byte of the body is the point: the status line has been read by then
      on E: EStreamStop do Result := C.ResponseStatusCode;
      on E: Exception do Result := C.ResponseStatusCode;
    end;
    Body := S.First;
  finally
    S.Free; C.Free;
  end;
end;

end.
