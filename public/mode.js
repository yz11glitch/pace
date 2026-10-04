export function isBenchmarkMode(search = "") {
  return new URLSearchParams(search).get("bench") === "1";
}

