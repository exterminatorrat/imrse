"use client";
import {useEffect, useState} from "react";
/** Conservative initial value prevents an animated flash before preferences are read. */
export function useMotionAllowed(): boolean {
  const [allowed,setAllowed] = useState(false);
  useEffect(()=>{
    const media = matchMedia("(prefers-reduced-motion: reduce)");
    const update=()=>setAllowed(!media.matches && document.visibilityState === "visible");
    update();media.addEventListener("change",update);document.addEventListener("visibilitychange",update);
    return ()=>{media.removeEventListener("change",update);document.removeEventListener("visibilitychange",update);};
  },[]);
  return allowed;
}
