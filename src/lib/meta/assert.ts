// Much-needed assert function with lazyness
function assert(cond: () => boolean, msg?: string) {
  if (assertEnabled && !cond())
    console.warn(new Error(msg ? `assertion failed: ${msg}` : "assertion failed").stack);
}

var assertEnabled = true;