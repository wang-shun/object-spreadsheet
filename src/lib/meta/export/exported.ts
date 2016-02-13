function exported(d) {
  var _results;
  _results = [];
  for (let k in d) {
    let v = d[k];
    _results.push(this[k] = v);
  }
  return _results;
}

exported({
  exported: exported
});
