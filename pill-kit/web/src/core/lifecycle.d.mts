export type PillState =
 | {phase:"hidden"} | {phase:"input"}
 | {phase:"processing";id:string} | {phase:"applying";id:string}
 | {phase:"success";id:string} | {phase:"error";id:string;message:string};
export type PillEvent = {type:"invoke"|"dismiss"}|{type:"submit"|"generated"|"applied";id:string}|{type:"failed";id:string;message:string};
export const hidden: Readonly<{phase:"hidden"}>;
export function transition(state:PillState,event:PillEvent):PillState;
export function activityWord(elapsedMs:number,words:readonly string[],intervalMs?:number):string;
