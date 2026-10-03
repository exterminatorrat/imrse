import type {ReactNode} from "react";
import {Providers} from "./providers";
import "./preview.css";
export const metadata={title:"imrse · pill component preview",description:"Interactive UI component preview. No model calls or system text access."};
export default function Layout({children}:{children:ReactNode}){
 return <html lang="en" suppressHydrationWarning><body><Providers>{children}</Providers></body></html>;
}
