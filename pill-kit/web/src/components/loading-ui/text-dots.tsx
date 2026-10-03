"use client";
import type { ReactNode } from "react";
/** Local implementation of the requested TextDots API; not claimed as upstream source. */
export function TextDots({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <span className={`imrse-text-dots ${className}`}>
    <span>{children}</span>
    <span className="imrse-dots" aria-hidden="true"><span>.</span><span>.</span><span>.</span></span>
  </span>;
}
