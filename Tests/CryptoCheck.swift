import Foundation
import CryptoKit
@main struct CryptoCheck {
 static func main() throws {
  precondition(ProtocolCrypto.sm3(Data("abc".utf8)).hex == "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0")
  let query="aid=8662&device_id=1000000000000001&version_name=7.3.9.32&video_id=1000000000000002"
  let expected=["403dfe7b4e5413af904539ea11684673ebf4de221beb77f22acda7299bce6182","98e6201c6adc86ac8eb09b9660f9d8bc74b899feba0c782ed02674b05269d65d"]
  for (i,body) in [nil,Data("{\"synthetic\":true}".utf8)].enumerated() {
   let h=try PlayerSignature.headers(query:query,body:body,ts:1700000000,randField:-12345,ladonRandom:Data(hex:"01020304")!)
   let keys=["x-ss-req-ticket","x-khronos","x-ladon","x-argus"] + (body == nil ? [] : ["x-ss-stub"])
   let json="{" + (try keys.map { key in let d=try JSONSerialization.data(withJSONObject:[h[key]!],options:[.fragmentsAllowed,.withoutEscapingSlashes]);return "\"\(key)\":"+String(data:d,encoding:.utf8)!.dropFirst().dropLast() }).joined(separator:",") + "}"
   precondition(Data(SHA256.hash(data:Data(json.utf8))).hex == expected[i],"551 protocol oracle mismatch")
  }
  print("PASS: SM3 standard vector; 551 GET/body upstream signature oracles")
 }
}
