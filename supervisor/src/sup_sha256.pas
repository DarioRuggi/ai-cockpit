(* =============================================================================
  sup_sha256 — SHA-256 (FIPS 180-4), streaming, for the integrity guard.
  FPC 3.2.2 ships only MD5 and SHA-1; Cockpit's integrity.json lists SHA-256, so the guard carries its own.
  Checked against `sha256sum` by tests/sha_test.sh (empty file, "abc", the 55/56/63/64/65-byte padding
  boundaries, a 5 MB file).
  ============================================================================= *)
unit sup_sha256;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, Classes;

function Sha256File(const Path: string; out Hex: string): Boolean;
function Sha256String(const S: string): string;

implementation

const
  K: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

type
  TSha = record
    H: array[0..7] of LongWord;
    Buf: array[0..63] of Byte;
    BufLen: Integer;
    Total: QWord;
  end;

function Ror(x: LongWord; n: Integer): LongWord; inline;
begin
  Result := (x shr n) or (x shl (32 - n));
end;

procedure Init(var C: TSha);
begin
  C.H[0] := $6a09e667; C.H[1] := $bb67ae85; C.H[2] := $3c6ef372; C.H[3] := $a54ff53a;
  C.H[4] := $510e527f; C.H[5] := $9b05688c; C.H[6] := $1f83d9ab; C.H[7] := $5be0cd19;
  C.BufLen := 0; C.Total := 0;
end;

procedure Block(var C: TSha; const B: array of Byte);
var
  w: array[0..63] of LongWord;
  a, bb, c2, d, e, f, g, h, t1, t2: LongWord;
  i: Integer;
begin
  for i := 0 to 15 do
    w[i] := (LongWord(B[i * 4]) shl 24) or (LongWord(B[i * 4 + 1]) shl 16) or (LongWord(B[i * 4 + 2]) shl 8) or LongWord(B[i * 4 + 3]);
  for i := 16 to 63 do
    w[i] := (Ror(w[i - 2], 17) xor Ror(w[i - 2], 19) xor (w[i - 2] shr 10)) + w[i - 7]
          + (Ror(w[i - 15], 7) xor Ror(w[i - 15], 18) xor (w[i - 15] shr 3)) + w[i - 16];
  a := C.H[0]; bb := C.H[1]; c2 := C.H[2]; d := C.H[3]; e := C.H[4]; f := C.H[5]; g := C.H[6]; h := C.H[7];
  for i := 0 to 63 do
  begin
    t1 := h + (Ror(e, 6) xor Ror(e, 11) xor Ror(e, 25)) + ((e and f) xor ((not e) and g)) + K[i] + w[i];
    t2 := (Ror(a, 2) xor Ror(a, 13) xor Ror(a, 22)) + ((a and bb) xor (a and c2) xor (bb and c2));
    h := g; g := f; f := e; e := d + t1; d := c2; c2 := bb; bb := a; a := t1 + t2;
  end;
  Inc(C.H[0], a); Inc(C.H[1], bb); Inc(C.H[2], c2); Inc(C.H[3], d);
  Inc(C.H[4], e); Inc(C.H[5], f); Inc(C.H[6], g); Inc(C.H[7], h);
end;

procedure Update(var C: TSha; const Data; Len: Integer);
var
  p: PByte;
  n: Integer;
begin
  p := @Data;
  Inc(C.Total, Len);
  while Len > 0 do
  begin
    n := 64 - C.BufLen;
    if n > Len then n := Len;
    Move(p^, C.Buf[C.BufLen], n);
    Inc(C.BufLen, n); Inc(p, n); Dec(Len, n);
    if C.BufLen = 64 then begin Block(C, C.Buf); C.BufLen := 0; end;
  end;
end;

function Final(var C: TSha): string;
var
  bits: QWord;
  pad: array[0..127] of Byte;
  padLen, i: Integer;
begin
  bits := C.Total * 8;
  FillChar(pad, SizeOf(pad), 0);
  pad[0] := $80;
  if C.BufLen < 56 then padLen := 56 - C.BufLen else padLen := 120 - C.BufLen;
  Update(C, pad, padLen);
  for i := 0 to 7 do pad[i] := Byte(bits shr (56 - 8 * i));
  Update(C, pad, 8);
  Result := '';
  for i := 0 to 7 do Result := Result + LowerCase(IntToHex(C.H[i], 8));
end;

function Sha256File(const Path: string; out Hex: string): Boolean;
var
  fs: TFileStream;
  c: TSha;
  buf: array[0..65535] of Byte;
  n: Integer;
begin
  Result := False;
  Hex := '';
  try
    fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  except
    Exit;
  end;
  try
    Init(c);
    repeat
      n := fs.Read(buf, SizeOf(buf));
      if n > 0 then Update(c, buf, n);
    until n <= 0;
    Hex := Final(c);
    Result := True;
  finally
    fs.Free;
  end;
end;

function Sha256String(const S: string): string;
var
  c: TSha;
begin
  Init(c);
  if S <> '' then Update(c, S[1], Length(S));
  Result := Final(c);
end;

end.
