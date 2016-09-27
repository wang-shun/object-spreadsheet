namespace Objsheets {

  export var RelsheetsServer = {
    _procedures: {},
    procedures: function(this: fixmeAny, appName: fixmeAny, defs: fixmeAny) {
      this._procedures[appName] = defs;
    },
    compile: function(this: fixmeAny, appName: fixmeAny, errCallback: (msg: string, stack: fixmeAny) => void = (m, s) => console.warn(m, s)) {
      // This may run multiple times; it should overwrite and not cause any problems.
      for (let name in this._procedures[appName]) {
        let preProc = this._procedures[appName][name];
        try {
          // NOTE: This is an interim implementation.  Once we have a basic
          // procedure editor, procedures will be loaded from dumps just like
          // column formulas.
          let params = preProc.params.map((p: fixmeAny) => ({
              name: p[0],
              type: parseTypeStr(p[1]),
              singular: fallback(p[2], true)
            }));
          let proc = parseProcedure({
            name: name,
            params: params,
            body: preProc.body
          });
          let oldId = Procedures.findOne({
            name: name
          }) != null ? Procedures.findOne({
            name: name
          })._id : null;
          if (oldId != null) {
            $$.model.redefineProcedure(oldId, proc);
          } else {
            $$.model.defineProcedure(proc);
          }
        } catch (e) {
          // Incompatible schema change?
          errCallback(`Failed to define app ${appName} sample procedure ${name} on sheet ${$$.id}:`, e.stack);
        }
      }
    }
  };

  Meteor.methods({
    compileProcedures: (cc: fixmeAny, appName: fixmeAny) => {
      cc.run(() => {
        RelsheetsServer.compile(appName);
      });
    }
  });

}
