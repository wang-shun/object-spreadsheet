
CallingContext = {
  get: function() {
    var d = process.domain;
    if (d) return d.cc
  },
  set: function(cc, func) {
    var domain = Npm.require('domain')
    var d = domain.create();
    d.cc = cc;
    od = process.domain  /* going to get overwritten by Domain.run() */
    d.run(func);
    process.domain = od
  }
}

