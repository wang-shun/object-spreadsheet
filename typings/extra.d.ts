// Node.js global object
declare var global: any;

// Stubs for now.

// I didn't find a type definition for Jison at all.  We could start one.
// ~ Matt 2016-02-28, rechecked 2016-09-19
declare var Jison: fixmeAny;

declare module Meteor {
  var EnvironmentVariable: EnvironmentVariableStatic;
  interface EnvironmentVariableStatic {
    new<T>(): EnvironmentVariable<T>;
  }
  interface EnvironmentVariable<T> {
    get(): T;
    withValue<R>(value: T, func: () => R): R;
  }

  // Unsound but probably the most reasonable way to write this.
  function makeErrorType<typeofClass>(name: string, constructor: typeofClass): typeofClass;
}

declare module Blaze {
  function _reportException(e: Error, msg: string): void;
}

// datejs library modifies the global Date object.
declare interface Date {
  toString(format: string): string;
}

declare interface HandsontableStatic {
  Dom: {
    stopImmediatePropagation(event: fixmeAny): void;
  };
}
