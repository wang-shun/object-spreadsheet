namespace Objsheets {

  // Much-needed assert function with lazyness
  export function assert(cond: () => boolean, msg?: string) {
    if (assertEnabled && !cond())
      console.warn(new Error(msg ? `assertion failed: ${msg}` : "assertion failed").stack);
  }

  export var assertEnabled = true;

}
