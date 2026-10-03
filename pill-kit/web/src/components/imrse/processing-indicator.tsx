"use client";
import dynamic from "next/dynamic";
import {useEffect,useRef,useState} from "react";
import type {LottieRefCurrentProps} from "lottie-react";
import {useTheme} from "next-themes";
import {SpiralLoader} from "@/components/agent-elements/spiral-loader";
import {spiralFastData} from "@/components/agent-elements/spiral-loader-data";
import {TextDots} from "@/components/loading-ui/text-dots";
import {activityWord} from "@/core/lifecycle.mjs";
import {useMotionAllowed} from "./use-motion";
const Lottie=dynamic(()=>import("lottie-react"),{ssr:false});
const WORDS=["Thinking","Refining","Rewriting","Polishing","Discombobulating"] as const;
function StillSpiral(){
  const ref=useRef<LottieRefCurrentProps|null>(null);
  const {resolvedTheme}=useTheme();
  return <span className={`imrse-still-spiral ${resolvedTheme === "dark" ? "" : "imrse-invert"}`}>
    <Lottie animationData={spiralFastData} lottieRef={ref} autoplay={false} loop={false}
      onDOMLoaded={()=>ref.current?.goToAndStop(14,true)} style={{width:24,height:24}}/>
  </span>;
}
function ActivityLabel({animate}:{animate:boolean}){
  const [epoch] = useState(()=>Date.now());
  const [elapsed,setElapsed]=useState(0);
  useEffect(()=>{
    if(!animate) return;
    const timer=window.setInterval(()=>setElapsed(Date.now()-epoch),2500);
    return ()=>clearInterval(timer);
  },[animate,epoch]);
  const word=animate ? activityWord(elapsed,WORDS) : "Thinking";
  return <span className="imrse-activity" aria-hidden="true"><TextDots>
    <span key={word} className="imrse-word">{word}</span>
  </TextDots></span>;
}
/** The changing label is a sibling of the real loader; it never keys or remounts it. */
export function ProcessingIndicator(){
  const animate=useMotionAllowed();
  return <span className="imrse-processing" role="status">
    <span className="imrse-sr-only">Working on your text</span>
    <span className="imrse-spiral-frame" data-testid="spiral" aria-hidden="true">
      {animate ? <SpiralLoader size={24}/> : <StillSpiral/>}
    </span>
    <ActivityLabel animate={animate}/>
  </span>;
}
