/**
 * 一次脚本运行内的取消状态。与 AX、Swift、daemon 无关。
 *
 * 粘性：markCancelled() 之后，同一次运行里后续 guard() 不再执行函数，
 * 直接返回 { ok: false, status: "cancelled", completedSteps }。
 * completedSteps 是已经执行完的调用次数，不含被取消、因而没有执行的那些。
 * beginRun() 表示新一次运行开始，清除取消标记，并把 completedSteps 归零。
 *
 * 尚未接入 jsapi / daemon。调用方自己持有 scope，在脚本入口调用 beginRun()。
 */

export function cancelledResult(completedSteps) {
  return { ok: false, status: "cancelled", completedSteps };
}

export function createCancelScope() {
  let cancelled = false;
  let completedSteps = 0;

  return {
    beginRun() {
      cancelled = false;
      completedSteps = 0;
    },
    markCancelled() {
      cancelled = true;
    },
    isCancelled() {
      return cancelled;
    },
    get completedSteps() {
      return completedSteps;
    },
    /**
     * 已取消：不调用 fn。
     * 未取消：执行 fn（可以返回 Promise）。正常返回后 completedSteps + 1。
     * fn 抛错或 reject：不增加计数，错误原样抛出，也不因此变成取消。
     */
    async guard(fn) {
      if (cancelled) return cancelledResult(completedSteps);
      const result = await fn();
      completedSteps += 1;
      return result;
    },
  };
}
