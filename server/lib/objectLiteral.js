// Shared helper for locating and replacing the `var EN = {...};` /
// `var AR = {...};` object literals embedded in each static .dc.html page.
// Used by both the migration script (read) and the page-serving route
// (read + replace with live DB content).

// Returns { start, end } character offsets of the `{ ... }` literal that
// follows `var <varName> = ` in source, or null if not found. `start` is
// the index of the opening brace; `end` is the index just after the
// matching closing brace. Walks the source respecting string literals
// (and escaped characters within them) so braces inside copy text never
// throw off the count.
function findObjectLiteralRange(source, varName) {
  const marker = `var ${varName} = {`;
  const markerIdx = source.indexOf(marker);
  if (markerIdx === -1) return null;
  const start = source.indexOf('{', markerIdx);

  let i = start;
  let depth = 0;
  let inString = null;
  for (; i < source.length; i++) {
    const ch = source[i];
    if (inString) {
      if (ch === '\\') { i++; continue; }
      if (ch === inString) inString = null;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') { inString = ch; continue; }
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) { i++; break; }
    }
  }
  return { start, end: i };
}

function extractObjectLiteralSource(source, varName) {
  const range = findObjectLiteralRange(source, varName);
  if (!range) return null;
  return source.slice(range.start, range.end);
}

// Splices `replacementObj` (serialized as JSON, which is valid JS object
// literal syntax) in place of the existing `var <varName> = {...}` literal.
// No-ops (returns source unchanged) if the marker isn't found.
function replaceObjectLiteral(source, varName, replacementObj) {
  const range = findObjectLiteralRange(source, varName);
  if (!range) return source;
  const json = JSON.stringify(replacementObj);
  return source.slice(0, range.start) + json + source.slice(range.end);
}

module.exports = { findObjectLiteralRange, extractObjectLiteralSource, replaceObjectLiteral };
