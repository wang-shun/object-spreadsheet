namespace Objsheets {

  // Utility function to translate CoffeeScript "a ? b".
  // ~ Matt 2016-01-31
  export function fallback<T>(a: T, b: T): T {
    return (a != null) ? a : b;
  }

}
