import assert from "node:assert/strict";
import { test } from "node:test";

import { createCancelScope } from "../cli/cancel.mjs";

test("取消之后后续步骤不执行，并带回已完成次数", async () => {
  const scope = createCancelScope();
  let calls = 0;

  const first = await scope.guard(() => {
    calls += 1;
    return { ok: true, via: "ax" };
  });
  assert.equal(calls, 1);
  assert.deepEqual(first, { ok: true, via: "ax" });
  assert.equal(scope.completedSteps, 1);
  assert.equal(scope.isCancelled(), false);

  scope.markCancelled();
  const second = await scope.guard(() => {
    calls += 1;
    return { ok: true };
  });
  assert.equal(calls, 1);
  assert.equal(scope.isCancelled(), true);
  assert.deepEqual(second, {
    ok: false,
    status: "cancelled",
    completedSteps: 1,
  });
  assert.equal(scope.completedSteps, 1);
});

test("取消是粘性的：之后每一次都不执行，completedSteps 不再增加", async () => {
  const scope = createCancelScope();
  let calls = 0;
  const run = () => {
    calls += 1;
    return { ok: true };
  };

  await scope.guard(run);
  await scope.guard(run);
  scope.markCancelled();

  const third = await scope.guard(run);
  const fourth = await scope.guard(async () => {
    calls += 1;
    return { ok: true };
  });

  assert.equal(calls, 2);
  assert.equal(scope.completedSteps, 2);
  assert.equal(scope.isCancelled(), true);
  assert.deepEqual(third, { ok: false, status: "cancelled", completedSteps: 2 });
  assert.deepEqual(fourth, { ok: false, status: "cancelled", completedSteps: 2 });
});

test("新一次运行清除取消状态和计数", async () => {
  const scope = createCancelScope();
  let calls = 0;

  await scope.guard(() => {
    calls += 1;
    return { ok: true };
  });
  scope.markCancelled();
  const blocked = await scope.guard(() => {
    calls += 1;
    return { ok: true };
  });
  assert.equal(calls, 1);
  assert.equal(blocked.completedSteps, 1);

  scope.beginRun();
  assert.equal(scope.isCancelled(), false);
  assert.equal(scope.completedSteps, 0);

  const again = await scope.guard(() => {
    calls += 1;
    return { ok: true, n: 1 };
  });
  assert.equal(calls, 2);
  assert.deepEqual(again, { ok: true, n: 1 });
  assert.equal(scope.completedSteps, 1);
  assert.equal(scope.isCancelled(), false);
});

test("尚未执行任何步骤时取消，completedSteps 为 0 且函数不跑", async () => {
  const scope = createCancelScope();
  let calls = 0;
  scope.markCancelled();
  const result = await scope.guard(() => {
    calls += 1;
    return { ok: true };
  });
  assert.equal(calls, 0);
  assert.deepEqual(result, { ok: false, status: "cancelled", completedSteps: 0 });
});

test("函数抛错不算完成，也不因此变成取消", async () => {
  const scope = createCancelScope();
  await assert.rejects(
    () => scope.guard(() => {
      throw new Error("boom");
    }),
    /boom/,
  );
  assert.equal(scope.completedSteps, 0);
  assert.equal(scope.isCancelled(), false);

  let calls = 0;
  const result = await scope.guard(async () => {
    calls += 1;
    return { ok: false, reasonCode: "stale_ref" };
  });
  assert.equal(calls, 1);
  assert.deepEqual(result, { ok: false, reasonCode: "stale_ref" });
  assert.equal(scope.completedSteps, 1);
});

test("重复标记取消仍然粘住，beginRun 之后才能再执行", async () => {
  const scope = createCancelScope();
  let calls = 0;
  scope.markCancelled();
  scope.markCancelled();
  await scope.guard(() => {
    calls += 1;
    return { ok: true };
  });
  assert.equal(calls, 0);

  scope.beginRun();
  await scope.guard(() => {
    calls += 1;
    return { ok: true };
  });
  assert.equal(calls, 1);
  assert.equal(scope.completedSteps, 1);
});
