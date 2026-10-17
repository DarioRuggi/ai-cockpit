(* =============================================================================
  srv_gzip — a gzip stream (RFC 1952) built on paszlib's raw deflate.

  The bundled zlib is the old 1.1 line: no gzip wrapper, so the 10-byte header, the crc32 and the length trailer are
  written here.  Kept in its own unit because zbase exports short names (COPY, LEN...) that collide with ours.
    Push(data, flush) -> the compressed bytes to send now (header first, trailer on Finish)
  ============================================================================= *)
unit srv_gzip;

{$mode objfpc}{$H+}

interface

type
  TGzip = class
  private
    FZ: Pointer;                  // z_stream, hidden so users of this unit never see zbase
    FCrc: Cardinal;
    FIn: Cardinal;
    FHead, FDone: Boolean;
    FLevel: Integer;
    procedure AppendBytes(var S: string; P: PByte; N: Integer);
  public
    constructor Create(ALevel: Integer);
    destructor Destroy; override;
    { Compress Len bytes.  Sync = flush so the reader can decode everything so far (live streams). }
    function Push(const Buf; Len: Integer; Sync: Boolean): string;
    { End of data: the last blocks and the trailer. }
    function Finish: string;
  end;

implementation

uses
  SysUtils, zbase, zdeflate;

type
  PZStream = ^z_stream;

var
  CrcTable: array[0..255] of Cardinal;
  CrcReady: Boolean = False;

function Crc32Update(Crc: Cardinal; P: PByte; Len: Integer): Cardinal;
var
  i, j: Integer;
  c: Cardinal;
begin
  if not CrcReady then
  begin
    for i := 0 to 255 do
    begin
      c := i;
      for j := 0 to 7 do if (c and 1) <> 0 then c := $EDB88320 xor (c shr 1) else c := c shr 1;
      CrcTable[i] := c;
    end;
    CrcReady := True;
  end;
  Result := not Crc;
  while Len > 0 do begin Result := CrcTable[(Result xor P^) and $FF] xor (Result shr 8); Inc(P); Dec(Len); end;
  Result := not Result;
end;

constructor TGzip.Create(ALevel: Integer);
begin
  inherited Create;
  FLevel := ALevel;
  GetMem(FZ, SizeOf(z_stream));
  FillChar(FZ^, SizeOf(z_stream), 0);
  if deflateInit2(PZStream(FZ)^, ALevel, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) <> Z_OK then
  begin
    FreeMem(FZ); FZ := nil;
    raise Exception.Create('deflateInit2 failed');
  end;
end;

destructor TGzip.Destroy;
begin
  if FZ <> nil then
  begin
    if not FDone then deflateEnd(PZStream(FZ)^);
    FreeMem(FZ);
  end;
  inherited Destroy;
end;

procedure TGzip.AppendBytes(var S: string; P: PByte; N: Integer);
var
  l: Integer;
begin
  if N <= 0 then Exit;
  l := Length(S);
  SetLength(S, l + N);
  Move(P^, S[l + 1], N);
end;

function TGzip.Push(const Buf; Len: Integer; Sync: Boolean): string;
var
  z: PZStream;
  out_: array[0..65535] of Byte;
  rc, n, flush: Integer;
  hdr: array[0..9] of Byte;
begin
  Result := '';
  z := PZStream(FZ);
  if not FHead then
  begin
    hdr[0] := $1F; hdr[1] := $8B; hdr[2] := 8; hdr[3] := 0; hdr[4] := 0; hdr[5] := 0; hdr[6] := 0; hdr[7] := 0; hdr[8] := 0; hdr[9] := 3;
    AppendBytes(Result, @hdr[0], 10);
    FHead := True;
  end;
  if Len > 0 then begin FCrc := Crc32Update(FCrc, @Buf, Len); Inc(FIn, Cardinal(Len)); end;
  if Sync then flush := Z_SYNC_FLUSH else flush := Z_NO_FLUSH;
  z^.next_in := @Buf; z^.avail_in := Len;
  repeat
    z^.next_out := @out_[0]; z^.avail_out := SizeOf(out_);
    rc := deflate(z^, flush);
    if (rc <> Z_OK) and (rc <> Z_BUF_ERROR) then raise Exception.Create('deflate failed: ' + IntToStr(rc));
    n := SizeOf(out_) - Integer(z^.avail_out);
    AppendBytes(Result, @out_[0], n);
  until (z^.avail_out <> 0) and (z^.avail_in = 0);
end;

function TGzip.Finish: string;
var
  z: PZStream;
  out_: array[0..65535] of Byte;
  rc, n: Integer;
  tr: array[0..7] of Byte;
  dummy: Byte;
  hdr: string;
begin
  Result := '';
  if FDone then Exit;
  z := PZStream(FZ);
  if not FHead then begin Result := Push(dummy, 0, False); FHead := True; end;
  z^.next_in := @dummy; z^.avail_in := 0;
  repeat
    z^.next_out := @out_[0]; z^.avail_out := SizeOf(out_);
    rc := deflate(z^, Z_FINISH);
    if (rc <> Z_OK) and (rc <> Z_STREAM_END) and (rc <> Z_BUF_ERROR) then raise Exception.Create('deflate finish failed: ' + IntToStr(rc));
    n := SizeOf(out_) - Integer(z^.avail_out);
    AppendBytes(Result, @out_[0], n);
  until rc = Z_STREAM_END;
  deflateEnd(z^); FDone := True;
  tr[0] := Byte(FCrc); tr[1] := Byte(FCrc shr 8); tr[2] := Byte(FCrc shr 16); tr[3] := Byte(FCrc shr 24);
  tr[4] := Byte(FIn); tr[5] := Byte(FIn shr 8); tr[6] := Byte(FIn shr 16); tr[7] := Byte(FIn shr 24);
  AppendBytes(Result, @tr[0], 8);
  hdr := '';
end;

end.
