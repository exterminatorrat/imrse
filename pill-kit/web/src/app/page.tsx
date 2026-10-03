"use client";
import {useEffect,useReducer,useRef,useState} from "react";
import {useTheme} from "next-themes";
import {ImrsePill} from "@/components/imrse/imrse-pill";
import {hidden,transition} from "@/core/lifecycle.mjs";
export default function Preview(){
 const [state,dispatch]=useReducer(transition,hidden);
 const [instruction,setInstruction]=useState("");
 const [outcome,setOutcome]=useState("success");
 const [lastInstruction,setLastInstruction]=useState<string|null>(null);
 const active=useRef<string|null>(null);
 const {resolvedTheme,setTheme}=useTheme();
 const invoke=()=>{if(["hidden","success","error"].includes(state.phase)){active.current=null;setInstruction("");dispatch({type:"invoke"});}};
 const dismiss=()=>{active.current=null;dispatch({type:"dismiss"});};
 // Deliberately only a browser-local demonstration. The native host owns the global shortcut.
 useEffect(()=>{
   let lastUp=0;let downAt=0;let clean=false;
   const down=(e:globalThis.KeyboardEvent)=>{
     if(e.key !== "Control"){clean=false;lastUp=0;return;}
     if(e.repeat||e.altKey||e.metaKey||e.shiftKey){clean=false;lastUp=0;return;}
     clean=true;downAt=performance.now();
   };
   const up=(e:globalThis.KeyboardEvent)=>{
     if(e.key !== "Control") return;
     const now=performance.now();
     if(!clean||now-downAt>220){lastUp=0;return;}
     if(lastUp && now-lastUp<=400){lastUp=0;invoke();}else lastUp=now;
     clean=false;
   };
   const blur=()=>{clean=false;lastUp=0;};
   window.addEventListener("keydown",down);window.addEventListener("keyup",up);window.addEventListener("blur",blur);
   return()=>{window.removeEventListener("keydown",down);window.removeEventListener("keyup",up);window.removeEventListener("blur",blur);};
 },[state.phase]);
 useEffect(()=>{
   if(state.phase !== "processing")return;
   const id=state.id;
   // This timer simulates host events ONLY; it never sends text or pretends to call a model.
   const timer=setTimeout(()=>{
     if(active.current !== id)return;
     dispatch(outcome === "error" ? {type:"failed",id,message:"Couldn't update the selection"} : {type:"generated",id});
   },12500);
   return()=>clearTimeout(timer);
 },[state,outcome]);
 useEffect(()=>{
   if(state.phase !== "applying")return;
   const id=state.id;const timer=setTimeout(()=>{if(active.current===id)dispatch({type:"applied",id});},450);
   return()=>clearTimeout(timer);
 },[state]);
 useEffect(()=>{
   if(state.phase !== "success")return;
   const timer=setTimeout(()=>{active.current=null;dispatch({type:"dismiss"});},1800);
   return()=>clearTimeout(timer);
 },[state]);
 return <main className="preview">
   <header><a href="/" className="wordmark">imrse</a><span>Component preview</span></header>
   <div className="preview-copy"><p className="eyebrow">ONLY WHEN YOU NEED IT</p><h1>A little less friction.</h1>
   <p>Double-tap Control in this page, or open the pill below.</p>
   <div className="preview-controls"><button onClick={invoke}>Invoke pill</button><button onClick={()=>setTheme(resolvedTheme === "dark" ? "light" : "dark")}>Switch appearance</button>
   <label>Demo outcome <select value={outcome} onChange={e=>setOutcome(e.target.value)}><option value="success">Success</option><option value="error">Failure</option></select></label></div>
   <p className="preview-note">UI-only demonstration. No model requests, clipboard access, or global shortcuts.<br/>Blank instruction is passed as null so the host can apply default.md.</p>
   <output data-testid="last-instruction">{lastInstruction === null ? "" : lastInstruction}</output></div>
   <div className="preview-anchor"><ImrsePill state={state} instruction={instruction} onInstructionChange={setInstruction}
     onSubmit={()=>{const id=crypto.randomUUID();active.current=id;setLastInstruction(instruction.trim() || "Uses default.md");dispatch({type:"submit",id});}}
     onDismiss={dismiss} onUndo={dismiss}
     presets={[{id:"expand",name:"Expand",instruction:"Expand this while preserving my intent."},{id:"concise",name:"Concise",instruction:"Make this more concise without losing meaning."}]}/></div>
   <footer>Original Agent Elements animation · No decorative AI icon</footer>
 </main>;
}
