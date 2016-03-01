@RelsheetsServer =
  _procedures: {}
  procedures: (appName, defs) -> @_procedures[appName] = defs; return
  compile: (appName) ->
    # This may run multiple times; it should overwrite and not cause any problems.
    for name, preProc of @_procedures[appName]
      try
        # NOTE: This is an interim implementation.  Once we have a basic
        # procedure editor, procedures will be loaded from dumps just like
        # column formulas.
        params =
          for p in preProc.params
            {name: p[0], type: parseTypeStr(p[1]), singular: p[2] ? true}
        proc = parseProcedure({
          name: name,
          params: params,
          body: preProc.body
        })
        oldId = Procedures.findOne({name: name})?._id
        if oldId?
          $$.model.redefineProcedure(oldId, proc)
        else
          $$.model.defineProcedure(proc)
      catch e
        # Incompatible schema change?
        console.log("Failed to define app #{appName} sample procedure #{name} on sheet #{$$.id}:", e.stack)
    return

Meteor.methods
  compileProcedures: (cc, appName) ->
    cc.run ->
      RelsheetsServer.compile(appName)
      return
    return
