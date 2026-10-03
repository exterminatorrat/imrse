"use client";
import {useEffect,useRef} from "react";
import type {KeyboardEvent} from "react";
import type {PillState} from "@/core/lifecycle.mjs";
import {ProcessingIndicator} from "./processing-indicator";
import "./pill.css";
export type PillPreset={id:string;name:string;instruction:string};
export type ImrsePillProps={
  state:PillState;instruction:string;onInstructionChange:(value:string)=>void;
  onSubmit:()=>void;onDismiss:()=>void;onUndo?:()=>void;onCopyResult?:()=>void;
  presets?:readonly PillPreset[];motion?:"instant"|"quick"|"smooth";
};
/** Controlled UI only. No clipboard access, provider requests, or global keyboard hooks. */
export function ImrsePill({state,instruction,onInstructionChange,onSubmit,onDismiss,onUndo,onCopyResult,presets=[],motion="quick"}:ImrsePillProps){
  const input=useRef<HTMLInputElement>(null);
  const submitting=useRef(false);
  const previousPhase=useRef<string|null>(null);
  useEffect(()=>{
    if(state.phase === "input"){
      submitting.current=false;
      if(previousPhase.current !== "input") input.current?.focus();
    }
    previousPhase.current=state.phase;
  },[state.phase]);
  useEffect(()=>{
    if(state.phase === "hidden") return;
    const escape=(event:globalThis.KeyboardEvent)=>{
      if(event.key === "Escape" && !event.isComposing){event.preventDefault();onDismiss();}
    };
    window.addEventListener("keydown",escape);
    return ()=>window.removeEventListener("keydown",escape);
  },[state.phase,onDismiss]);
  const submit=()=>{if(state.phase === "input" && !submitting.current){submitting.current=true;onSubmit();}};
  const keys=(event:KeyboardEvent)=>{
    // Enter must confirm IME composition, not accidentally send Chinese/Japanese input.
    if(event.nativeEvent.isComposing || event.keyCode===229) return;
    if(state.phase === "input" && event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey && /^[1-9]$/.test(event.key)){
      const preset=presets[Number(event.key)-1];
      if(preset){event.preventDefault();onInstructionChange(preset.instruction);input.current?.focus();}
    }
  };
  if(state.phase === "hidden") return null;
  return <section className="imrse-pill" data-phase={state.phase} data-motion={motion}
    aria-label="imrse text transformation" onKeyDown={keys}>
    {state.phase === "input" ? <form className="imrse-input-row" onSubmit={event=>{event.preventDefault();submit();}}>
      <input ref={input} aria-label="What should I change?" placeholder="What should I change?"
        value={instruction} maxLength={8000} autoComplete="off" spellCheck={false}
        onChange={e=>onInstructionChange(e.target.value)}
        onKeyDown={event=>{if(event.key === "Enter" && (event.nativeEvent.isComposing || event.keyCode===229))event.preventDefault();}}/>
      <button type="submit" className="imrse-action imrse-return" aria-label="Apply transformation" title="Blank uses default.md">↵</button>
    </form> : state.phase === "processing" ? <>
      <ProcessingIndicator/><button className="imrse-action" onClick={onDismiss} aria-label="Cancel transformation">esc</button>
    </> : state.phase === "applying" ? <>
      <span className="imrse-message" role="status">Updating selection…</span><span className="imrse-action" aria-hidden="true"> </span>
    </> : state.phase === "success" ? <>
      <span className="imrse-message" role="status">Updated</span>
      {onUndo ? <button className="imrse-action" onClick={onUndo}>Undo</button> : <button className="imrse-action" onClick={onDismiss}>Close</button>}
    </> : <>
      <span className="imrse-message" role="alert" title={state.message}>{state.message}</span>
      {onCopyResult ? <button className="imrse-action" onClick={onCopyResult}>Copy</button> : null}
      <button className="imrse-action" onClick={onDismiss} aria-label="Dismiss error">esc</button>
    </>}
  </section>;
}
