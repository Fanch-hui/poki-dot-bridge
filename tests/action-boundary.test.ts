import assert from "node:assert/strict";
import test from "node:test";
import { PokiActionSchema } from "../src/shared/schemas.ts";

test("Phone actions keep legitimate typed text and reject mixed action keys", () => {
  assert.deepEqual(PokiActionSchema.parse({ type: "tap", ref: 1 }), { type: "tap", ref: 1 });
  assert.equal(PokiActionSchema.safeParse({ type: "tap", tap: 1 }).success, false);
  assert.equal(PokiActionSchema.safeParse({ tap: 1, wait_until: "Results" }).success, false);
  assert.equal(PokiActionSchema.safeParse({
    path: { goal: "Find tea", steps: [{ tap: "Search", type: "tea" }] },
  }).success, false);
});

test("Cross-screen tap targets retain their visible label and row", () => {
  const namedTap = { tap: { label: "选规格", type: "Button", row_label: "绿茶" } };
  assert.deepEqual(PokiActionSchema.parse(namedTap), namedTap);
  assert.equal(PokiActionSchema.safeParse({ tap: { label: "搜索", x: 100 } }).success, false);
  assert.equal(PokiActionSchema.safeParse({ tap: { label: "搜索", ref: 1 } }).success, false);
  assert.equal(PokiActionSchema.safeParse({ swipe: { label: "列表" } }).success, false);
  assert.equal(PokiActionSchema.safeParse({
    path: { goal: "Open delivery", steps: [{ navigate: { app: "Shop", destination: { label: "Delivery" } } }] },
  }).success, true);
});
