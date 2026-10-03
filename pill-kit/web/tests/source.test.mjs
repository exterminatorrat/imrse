import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
const root=new URL("../../",import.meta.url);
const read=p=>readFileSync(new URL(p,root),"utf8");
const blob=s=>createHash("sha1").update(`blob ${Buffer.byteLength(s)}\0`).update(s).digest("hex");
test("SpiralLoader source is exactly the upstream blob",()=>assert.equal(blob(read("web/src/components/agent-elements/spiral-loader.tsx")),"6578cdad7bf91f6525ad08e563cc1fda677e264a"));
test("spiral animation data is exactly the upstream blob",()=>assert.equal(blob(read("web/src/components/agent-elements/spiral-loader-data.ts")),"7e92e83871a3d7125e9b92d9f048608de6c5990f"));
for(const speed of ["Fast","Slow"]){
 test(`${speed} native resource is a lossless extract`,()=>{
  const source=read("upstream/spiral-loader-data.ts");
  const json=source.match(new RegExp(`export const spiral${speed}Data = (.+);`))[1];
  const native=read(`native/Sources/ImrsePillUI/Resources/spiral-${speed.toLowerCase()}.json`);
  assert.deepEqual(JSON.parse(native),JSON.parse(json));
 });
}
test("original timing and opacity are preserved",()=>{
 const fast=JSON.parse(read("native/Sources/ImrsePillUI/Resources/spiral-fast.json"));
 const slow=JSON.parse(read("native/Sources/ImrsePillUI/Resources/spiral-slow.json"));
 assert.equal(fast.op/fast.fr,.5);assert.equal(slow.op/slow.fr,1);
 assert.equal(fast.layers[0].ks.o.k,24);assert.equal(slow.layers[0].ks.o.k,24);
});
