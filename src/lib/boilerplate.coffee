
if Meteor.isClient
  Relsheets =
    open: (sheet, proceduresAppName=null) ->
      Tablespace.default = Tablespace.get(sheet)
      $$.call('open', () ->
        if proceduresAppName?
          $$.call('compileProcedures', proceduresAppName)
        $$.subscribeAll())
    call: (transaction, argsObj, callback) ->
      $$.call('executeCannedTransaction', transaction, glue(argsObj),
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


Relsheets.readObj = (t, rootCellId=[], expandRefs=false, keyField=undefined, visited=undefined) ->
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
      vals = new FamilyId({cellId: rootCellId, columnId: x.root}).values()
      if c.isObject
        fam = (@readObj(x, cellIdChild(rootCellId, v), expandRefs, c.fieldName, visited) for v in vals)
        fam.qFamilyId = {columnId: x.root, cellId: rootCellId}
        # We could use objectNameWithFallback, but this gives easier syntax for readers.
        objectName = c.objectName ? c.fieldName
        obj[objectName] = fam
      else if c.fieldName?
        # TODO: Sending the full content of all referenced objects to the client
        # is a security problem.  Remove this feature and update all affected
        # applications.  (Doesn't really matter until we have authentication.)
        if expandRefs && c.type? && !typeIsPrimitive(c.type)
          ot = View.drillDown(c.type)
          vals = vals.map((v) => @readObj(ot, v, expandRefs, Columns.findOne(ot.root)?.fieldName, visited))
        obj[c.fieldName] = vals

  obj

# Future: Deprecate this in favor of something like readSubtree?
Relsheets.read = (viewId) ->
  layout = 
    if viewId? then (new View(viewId).def())?.layout || new Tree(rootColumnId)
    else View.rootLayout()
  @readObj(layout, [], true)

Relsheets.readSubtree = (columnStr, rootCellId) ->
  try
    columnTree = View.drillDown(parseObjectTypeRef(columnStr))
  catch e
    # Apparently the above can be attempted before the client has received the
    # entire Columns publication.  XXX: Avoid catching real errors.
    return {}
  # Alternatively, we could take viewId and depth parameters and do the
  # following, which will let the developer send only a subset of the
  # descendants of the starting column to the client (once we restrict
  # publishing), but we generally expect the developer to create a dedicated
  # schema subtree for each web application view anyway.
  #columnTree = new View(viewId).def().layout
  #for i in [0...depth]
  #  columnTree = columnTree.subtrees[0]
  Relsheets.readObj(columnTree, rootCellId)

  
glue = (argsobj) ->
  value = (a) ->
    if a.qCellId? then a.qCellId.cellId else a
  arg = (a) ->
    if _.isArray(a) then a.map value
    else [value(a)]
  new ->
    @[k] = arg(v) for k,v of argsobj ; null
    
  
exported = (d) ->
  for k,v of d
    @[k] = v

exported {Relsheets}
