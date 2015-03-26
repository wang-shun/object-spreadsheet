
if Meteor.isClient
  Relsheets =
    open: (sheet, proceduresAppName=null) ->
      Tablespace.default = Tablespace.get(sheet)
      $$.call('open', () ->
        if proceduresAppName?
          $$.call('compileProcedures', proceduresAppName)
        $$.subscribeAll())
    call: (transaction, argsObj, callback) ->
      $$.call('executeCannedTransaction', transaction, argsObj,
              andThen (result) -> callback?(result))


if Meteor.isServer

  Relsheets =
    _procedures: {}
    procedures: (appName, defs) -> @_procedures[appName] = defs
    compile: (appName) ->
      # This may run multiple times; it should overwrite and not cause any problems.
      try
        for name, proc of @_procedures[appName]
          $$.model.cannedTransactions.set(
            name, parseCannedTransaction(proc.params, proc.body))
      catch e
        # Incompatible schema change?
        console.log("Failed to define app #{appName} sample procedure #{name} on sheet #{$$.id}:", e.stack)

  Meteor.methods
    compileProcedures: (cc, appName) -> cc.run -> Relsheets.compile(appName)


Relsheets.readObj = (t, rootCellId, keyField=undefined, visited=undefined) ->
  obj = {qCellId: {columnId: t.root, cellId: rootCellId}}
  if !visited?
    visited = new EJSONKeyedMap
  if (v = visited.get(obj.qCellId))
    return v
  visited.set(obj.qCellId, obj)
    
  if keyField?
    obj[keyField] = cellIdLastStep(rootCellId)
  for x in t.subtrees
    c = Columns.findOne(x.root)
    if c?
      vals = new ColumnBinRel(x.root).lookup(set([rootCellId])).set.elements()
      if c.objectName?
        fam = (@readObj(x, cellIdChild(rootCellId, v), c.fieldName, visited) for v in vals)
        fam.qFamilyId = {columnId: x.root, cellId: rootCellId}
        obj[c.objectName] = fam
      else if c.fieldName?
        if c.type? && !typeIsPrimitive(c.type)
          ot = View.drillDown(c.type)
          vals = vals.map((v) => @readObj(ot, v, Columns.findOne(ot.root)?.fieldName, visited))
        obj[c.fieldName] = vals

  obj


Relsheets.read = ->
  @readObj(View.rootLayout(), [])


exported = (d) ->
  for k,v of d
    @[k] = v

exported {Relsheets}
