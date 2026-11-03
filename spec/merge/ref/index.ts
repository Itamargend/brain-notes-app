export { splitLines, matchLines, diff3, MAX_DIFF_CELLS } from "./diff3.ts";
export { splitBlocks, joinBlocks } from "./sections.ts";
export { mergeFile, type MergeResult, type Doc } from "./merge.ts";
export { checkPath, foldKey, freePath, PathIndex, MAX_NOTE_BYTES } from "./paths.ts";
export { planCommit, copyHeader, copyStamp, type PlanInput, type PlanOutput, type Op, type Entry } from "./plan.ts";
