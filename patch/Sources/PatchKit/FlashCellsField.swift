import Foundation
import CryptoKit

enum FlashCellsField {
    static let path: String = {
        let digest=SHA256.hash(data:Data(source.utf8)).prefix(6).map { String(format:"%02x",$0) }.joined()
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("PatchFlashCells-\(digest).metal")
        if !FileManager.default.fileExists(atPath:url.path) { try? source.write(to:url,atomically:true,encoding:.utf8) }
        return url.path
    }()
    static let source = """
// PATCH_FLASH_CELLS
float randomCell(uint x) { x^=x>>16;x*=0x7feb352du;x^=x>>15;x*=0x846ca68bu;x^=x>>16;return float(x&0x00ffffffu)/16777216.0; }
float3 flash(float2 uv,float time,constant float *data) {
 uint2 cell=uint2(floor(uv*float2(data[6],data[7])));
 uint index=cell.y*uint(data[6])+cell.x,seed=uint(data[5]);
 float phase=time*data[0]+randomCell(index+seed)*7;
 uint cycle=uint(max(0.0,floor(phase)));
 float f=fract(phase),duty=data[2],fade=max(0.001,min(duty,data[3]*duty));
 float level=step(randomCell(index*7919u+cycle*104729u+seed),data[1])*(1-smoothstep(duty-fade,duty,f))*smoothstep(0.0,0.015,f);
 uint count=uint(data[8]);if(count==0)return float3(0);
 uint mode=uint(data[4]);
 uint selected=mode==1 ? (cycle+index)%count : uint(randomCell(index*313u+seed+(mode==0 ? cycle*971u : 0u))*float(count));
 uint start=uint(data[9])+min(count-1,selected)*3;
 return float3(data[start],data[start+1],data[start+2])*level;
}
"""
}
