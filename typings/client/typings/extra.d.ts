// es6-promise type definition is used on the client as recommended at:
// http://stackoverflow.com/questions/27573365/how-to-use-typescript-with-native-es6-promises

// deanius:promise
// TODO: Move to type definition file for deanius:promise
declare module Meteor {
  // As many as needed. :/
  function wrapPromise<R>(f: (cb: MeteorCallback<R>) => void): Promise<R>;
  function wrapPromise<R, A1>(f: (a1: A1, cb: MeteorCallback<R>) => void):
    (a1: A1) => Promise<R>;
  function wrapPromise<R, A1, A2>(f: (a1: A1, a2: A2, cb: MeteorCallback<R>) => void):
    (a1: A1, a2: A2) => Promise<R>;
}
