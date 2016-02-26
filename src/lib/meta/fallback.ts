// Utility function to translate CoffeeScript "a ? b".
// ~ Matt 2016-01-31
function fallback(a, b) {
  return (a != null) ? a : b;
}
