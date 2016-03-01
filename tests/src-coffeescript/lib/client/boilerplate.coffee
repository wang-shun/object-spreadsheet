openCallbacks = []
@RelsheetsClient =
  open: (sheet, proceduresAppName=null) ->
    Tablespace.defaultTablespace = Tablespace.get(sheet)
    $$.call('open', () ->
      if proceduresAppName?
        $$.call('compileProcedures', proceduresAppName)
      $$.subscribeAll()
      return)
    for callback in openCallbacks
      callback()
    return
  call: (transaction, argsObj, callback=undefined) ->
    $$.call('executeCannedTransaction', transaction, glue(argsObj),
            standardServerCallbackThen(callback))
    return
  onOpen: (callback) ->
    openCallbacks.push(callback)
    return

  readObj: (t, rootCellId=[], expandRefs=false, keyField=undefined, visited=undefined) ->
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
          if expandRefs && c.type? && typeIsReference(c.type)
            ot = View.drillDown(c.type)
            vals = vals.map((v) => @readObj(ot, v, expandRefs, Columns.findOne(ot.root)?.fieldName, visited))
          obj[c.fieldName] = vals

    obj

  # Future: Deprecate this in favor of something like readSubtree?
  read: (viewId=undefined) ->
    layout = 
      if viewId? then (new View(viewId).def())?.layout || new Tree(rootColumnId)
      else View.rootLayout()
    @readObj(layout, [], true)

  readSubtree: (columnStr, rootCellId) ->
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
    @readObj(columnTree, rootCellId)

  
glue = (argsobj) ->
  value = (a) ->
    if a.qCellId? then a.qCellId.cellId else a
  arg = (a) ->
    if _.isArray(a) then a.map value
    else [value(a)]
  new ->
    @[k] = arg(v) for k,v of argsobj ; null
    
