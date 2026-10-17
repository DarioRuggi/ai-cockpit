program Dario10S;
{ Dario-10S XOR stream cipher — Free Pascal reference, used by the cockpit's
  cross-language tester (encryptester.php) to verify FPC == PHP byte-for-byte.
  Formula: enc = ((data XOR key) + keyNum) mod 256 ; dec is the inverse.
  Args: <enc|dec> <keyNum> <base64(key)> <data>
    enc: data = base64(plaintext)      → prints base64(cipher)
    dec: data = base64(cipher) string  → prints base64(plaintext)            }
{$mode objfpc}{$H+}
uses SysUtils, base64;

function EncWithKey(const data, key: ansistring; keyNum: integer): ansistring;
var i, d, k: integer; outb: ansistring;
begin
  outb := '';
  for i := 1 to Length(data) do
  begin
    d := Ord(data[i]);
    k := Ord(key[((i - 1) mod Length(key)) + 1]);
    outb := outb + Chr(((d xor k) + keyNum) mod 256);
  end;
  Result := EncodeStringBase64(outb);
end;

function DecWithKey(const b64cipher, key: ansistring; keyNum: integer): ansistring;
var i, d, k: integer; dec, outb: ansistring;
begin
  dec := DecodeStringBase64(b64cipher);
  outb := '';
  for i := 1 to Length(dec) do
  begin
    d := Ord(dec[i]);
    k := Ord(key[((i - 1) mod Length(key)) + 1]);
    outb := outb + Chr(((d - keyNum + 256) mod 256) xor k);
  end;
  Result := outb;
end;

var mode, key: ansistring; keyNum: integer;
begin
  if ParamCount < 4 then begin WriteLn('ERR:args'); Halt(1); end;
  mode   := ParamStr(1);
  keyNum := StrToInt(ParamStr(2));
  key    := DecodeStringBase64(ParamStr(3));
  if Length(key) = 0 then begin WriteLn('ERR:key'); Halt(1); end;
  if mode = 'enc' then
    WriteLn(EncWithKey(DecodeStringBase64(ParamStr(4)), key, keyNum))
  else
    WriteLn(EncodeStringBase64(DecWithKey(ParamStr(4), key, keyNum)));
end.
