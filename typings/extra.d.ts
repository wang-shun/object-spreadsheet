// Stubs for now.

// There's a partial type definition that doesn't include the Handsontable
// class.  Declare a stub, and then see what we can wire up and what we have to
// add.
declare var Handsontable;

// I didn't find a type definition for Jison at all.  We could start one.
// ~ Matt 2016-02-28
declare var Jison;

declare module Meteor {
  // Unsound but probably the most reasonable way to write this.
  function makeErrorType<typeofClass>(name: string, constructor: typeofClass): typeofClass;
}

declare module Blaze {
  function _reportException(e: Error, msg: string): void;
}

declare interface Error {
  stack: string;
}

// datejs package modifies the global Date object.
declare interface Date {
  toString(format: string): string;
}
