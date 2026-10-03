// This component needs only a class join; no utility-framework dependency is required.
export function cn(...values: Array<string | false | null | undefined>): string {
  return values.filter(Boolean).join(" ");
}
