/** Host-confirmed state changes; generation is never treated as a successful write. */
export const hidden = Object.freeze({ phase: "hidden" });
export function transition(state, event) {
  if (event.type === "dismiss") return hidden;
  if (event.type === "invoke") {
    return ["hidden", "success", "error"].includes(state.phase) ? { phase: "input" } : state;
  }
  if (event.type === "submit") {
    return state.phase === "input" && event.id ? { phase: "processing", id: event.id } : state;
  }
  if (!("id" in state) || event.id !== state.id) return state;
  if (event.type === "generated" && state.phase === "processing") return { phase: "applying", id: state.id };
  if (event.type === "applied" && state.phase === "applying") return { phase: "success", id: state.id };
  if (event.type === "failed" && ["processing", "applying"].includes(state.phase)) {
    return { phase: "error", id: state.id, message: event.message || "Couldn't update the selection" };
  }
  return state;
}
/** Activity copy, not purported model stages. No fake progress percentages. */
export function activityWord(elapsedMs, words, intervalMs = 2500) {
  if (!words.length) return "Thinking";
  const elapsed = Number.isFinite(elapsedMs) ? Math.max(0, elapsedMs) : 0;
  const interval = Number.isFinite(intervalMs) && intervalMs >= 1000 ? intervalMs : 2500;
  return words[Math.floor(elapsed / interval) % words.length] || "Thinking";
}
