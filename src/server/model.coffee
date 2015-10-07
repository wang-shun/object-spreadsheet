class CannedTransaction
  # @params: EJSONKeyedMap of name to type
  constructor: (@params, @body) ->

class Model

  # TODO: Indicate which methods are intended to be public!

  #@columns: EJSONKeyedMap<ColumnId, Column>

  constructor: ->
    @settings = {compiler: true, profiling: 0}
    @columnCache = {}
    
    # Special case: create root column if missing.
    unless @getColumn(rootColumnId)?
      @wasEmpty = true
      # None of the other properties should be used.
      Columns.insert
        _id: rootColumnId
        children: []
        fieldName: null
        specifiedType: '_token'  # Close enough to the truth?
        type: null
        typecheckError: null
        isObject: true  # Allow children.
        objectName: null
        formula: null

    # If this is the first time the server process is accessing this sheet, it
    # might contain data generated by a different version of the server code.
    @invalidateSchemaCache()

    # For now, these exist only in memory, to be added by server code.
    @cannedTransactions = new EJSONKeyedMap()

  getColumn: (columnId) ->
    # Treat as read-only and valid only until the model is next modified.
    # XXX: Replace by a real API.  At least the references will be easy to find.
    return @columnCache[columnId] ? Columns.findOne(columnId)

  getAllColumns: (columnId=rootColumnId) ->
    col = @getColumn columnId
    # A bit of auto-repair in case some columns were deleted
    validChildren = col.children.filter (x) -> @getColumn(x)?
    if validChildren.length != col.children.length
      Columns.update(columnId, {$set: {children: validChildren}})
    [[columnId, col]].concat (@getAllColumns c for c in validChildren)...

  defineColumn: (parentId, index, fieldName, specifiedType, isObject, objectName, formula, attrs) ->
    # Future: validate everything
    # Future: validate no fieldName for type _token.  For _unit, there could be borderline use cases.
    # XXX: Do not allow non-object columns to have type _token?  Currently it
    # won't hurt anything, and it doesn't make sense to tighten this until we
    # finalize the flow for specifying types of newly created columns.
    parentCol = @getColumn(parentId)
    unless parentCol?
      throw new Meteor.Error('defineColumn-no-parent', 'The specified parent column does not exist.')
    unless 0 <= index <= parentCol.children.length
      throw new Meteor.Error('defineColumn-index-out-of-range', 'Index out of range')
    if !isObject && objectName?
      throw new Meteor.Error('defineColumn-objectName-not-isObject',
                             'A column with isObject = false cannot have an objectName.')
    if !formula?
      if parentCol.formula?
        throw new Meteor.Error('defineColumn-state-under-formula',
                               'Creating a state column as child of a formula column is currently not allowed.')
      if !specifiedType?
        # XXX We should never allow this, but it is pointless to fix when we
        # don't validate the values anyway.
        specifiedType = '_any'
        # TODO perhaps a better flow would be to leave undefined, but check when
        #  user enters data
        #throw new Meteor.Error('defineColumn-type-required',
        #                       'Must specify type for a state column')
    if formula?
      validateFormula(formula)
    @invalidateSchemaCache()
    thisId = Random.id()
    col = {
      _id: thisId
      parent: parentId
      fieldName: fieldName
      specifiedType: specifiedType
      type: null
      typecheckError: null
      isObject: isObject
      objectName: objectName
      formula: formula
      children: []
    }
    for k,v of attrs || {}
      col[k] = v
    Columns.insert(col)
    if !parentCol.isObject
      @changeColumnIsObject(parentCol._id, true)
      parentCol = @getColumn(parentId)
      index = 1
    parentCol.children.splice(index, 0, thisId)
    # Meteor is nice for so many things, but not ORM...
    Columns.update(parentCol._id, {$set: {children: parentCol.children}})

    return thisId

  changeColumnFieldName: (columnId, fieldName) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    col = @getColumn(columnId)
    if fieldName == col.fieldName
      return
    Columns.update(columnId, {$set: {fieldName: fieldName}})
    @invalidateColumnCache()

  changeColumnObjectName: (columnId, objectName) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    col = @getColumn(columnId)
    if objectName == col.objectName
      return
    if !col.isObject && objectName?
      throw new Meteor.Error('defineColumn-objectName-not-isObject',
                             'A column with isObject = false cannot have an objectName.')      
    Columns.update(columnId, {$set: {objectName: objectName}})
    @invalidateColumnCache()

  changeColumnIsObject: (columnId, isObject) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    col = @getColumn(columnId)
    if isObject == col.isObject
      return
    
    if isObject
      # When making a state column into an object column: 
      # column type becomes "_token", existing values are moved to a 
      # newly created child column
      if !col.formula?
        @invalidateSchemaCache()
        Columns.update(columnId, {$set: {specifiedType: '_token', isObject: true, objectName: col.fieldName, fieldName: null}})
        childId = @defineColumn(columnId, 0, "*", col.specifiedType, false, null, null, {})
        Cells.find({column: columnId}).forEach (family) ->
          tokens = (Random.id() for value in family.values)
          Cells.update(family._id, {$set: {values: tokens}})
          for [token, value] in zip(tokens, family.values)
            key = cellIdChild(family.key, token)
            Cells.insert({column: childId, key, values: [value]})
    else
      # When making a state column into a value column:
      # - If column type is "_token", values are copied from the column's only child,
      #   and that child is removed.
      # - Otherwise, column must have no children.
      if col.type == '_token'
        if col.children?.length > 1
          throw new Meteor.Error('remove-object-has-children',
                                 'Object must have a single field before converting to values.')
        if col.children?.length == 1
          childId = col.children[0]
          childCol = @getColumn(childId)
          if childCol.isObject || childCol.children?.length
            throw new Meteor.Error('remove-object-complex-value',
                                   "Child '#{childCol.objectName ? childCol.fieldName}' is not a simple value.")
          Cells.find({column: columnId}).forEach (family) ->
            newValues = []
            for value in family.values
              Cells.find({column: childId, key: value}).forEach (family) ->
                newValues.push(family.values...)
            Cells.update(family._id, {$set: {values: newValues}})
          Columns.update(columnId, {$set: {specifiedType: childCol.type, children: []}})
          Columns.remove(childId)
          Cells.remove({column: childId})
        else
          Columns.update(columnId, {$set: {specifiedType: '_any'}})
        @invalidateSchemaCache()
      else
        if col.children?.length
          throw new Meteor.Error('remove-object-has-children',
                                 'Please delete all child columns first.')
      if col.objectName?
        Columns.update(columnId, {$set: {objectName: null, fieldName: col.objectName}})
    Columns.update(columnId, {$set: {isObject: isObject}})
    @invalidateColumnCache()

  changeColumnSpecifiedType: (columnId, specifiedType) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    @invalidateSchemaCache()
    Columns.update(columnId, {$set: {specifiedType}})

  _changeColumnType: (columnId, type) ->
    Columns.update(columnId, {$set: {type}})

  _changeColumnTypecheckError: (columnId, typecheckError) ->
    Columns.update(columnId, {$set: {typecheckError}})

  # Future: API to move and copy groups of columns.  This is an order of
  # magnitude more complicated.

  changeColumnFormula: (columnId, formula) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    # TODO check that there are no state cells
    #unless col.formula?
    # ...
    #  throw new Meteor.Error('changeFormula-on-non-formula-column',
    #                         'Can only changeFormula on a formula column!')
    if formula?
      validateFormula(formula)
    col = @getColumn(columnId)
    # Hack: When a state column is converted to a formula column,
    # automatically remove the default type of '_any'.
    if !col.formula? && col.specifiedType == '_any'
      Columns.update(columnId, {$set: {specifiedType: null}})
    Columns.update(columnId, {$set: {formula}})
    @invalidateSchemaCache()  # type may change

  changeColumnDisplay: (columnId, display) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    if display?
      validateFormula(display)
    Columns.update(columnId, {$set: {display}})
    
  changeColumnReferenceDisplay: (columnId, referenceDisplay) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    if referenceDisplay?
      validateFormula(referenceDisplay)
    Columns.update(columnId, {$set: {referenceDisplay}})

  reorderColumn: (columnId, newIndex) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    col = @getColumn(columnId)
    parentCol = @getColumn(col.parent)
    children = (x for x in parentCol.children when x != columnId)
    children.splice(newIndex, 0, columnId)
    Columns.update(col.parent,  {$set: {children}})
    @invalidateColumnCache()
    
  deleteColumn: (columnId) ->
    if columnId == rootColumnId
      throw new Meteor.Error('delete-root-column',
                             'Cannot delete the root column.')
    # Assert not root
    col = @getColumn(columnId)
    if col.children?.length
      throw new Meteor.Error('delete-column-has-children',
                             'Please delete all child columns first.')
    # XXX: Make this work again.
    #if columnIsState(col) && col.numStateCells > 0
    #  throw new Meteor.Error('delete-column-has-state-cells',
    #                         'Please delete all state cells first.')
    parentCol = @getColumn(col.parent)
    @invalidateSchemaCache()
    parentCol.children.splice(parentCol.children.indexOf(columnId), 1)
    Columns.update(parentCol._id, {$set: {children: parentCol.children}})
    Columns.remove(columnId)

  evaluateFamily1: (qFamilyId) ->
    col = @getColumn(qFamilyId.columnId)
    if col.formula?
      s = JSON.stringify
      if @settings.profiling >=2 then console.log "[evaluateFamily1(qFamilyId=#{s qFamilyId}) formula=#{s col.formula}]"
      compiled = $$.formulaEngine.compiled[qFamilyId.columnId]
      if col.typecheckError?
        throw new EvaluationError("Formula failed type checking: #{col.typecheckError}")
      if compiled?
        result = new TypedSet(col.type, compiled($$.formulaEngine, [qFamilyId.cellId]))
      else
        vars = new EJSONKeyedMap(
          [['this', new TypedSet(col.parent, new EJSONKeyedSet([qFamilyId.cellId]))]])
        result = evaluateFormula(this, vars, col.formula)
      if 0 #compiled?
        result1 = new TypedSet(col.type, compiled($$.formulaEngine, vars.get("this").set.elements()))
        if !EJSON.equals(result, result1)
          console.log "Wrong output from compiler;\nformula=#{s col.formula}]"
          console.log "> interpreter result = #{s result}"
          console.log "> compiled result    = #{s result1}"
          console.log "-----------------------------"
      if @settings.profiling >=2 then console.log "[/evaluateFamily1]"
      return result
    else
      # State column;
      # Must be empty, otherwise we wouldn't have gotten here.
      # XXX: Be consistent about which state families exist in the DB.
      return new TypedSet(col.type)

  evaluateFamily: (qFamilyId) ->
    keyFields = {column: qFamilyId.columnId, key: qFamilyId.cellId}
    ce = Cells.findOne(keyFields)
    unless ce?
      Cells.insert(keyFields)
      try
        content = @evaluateFamily1(qFamilyId)
        Cells.update(keyFields, {$set: {values: content.elements()}})
      catch e
        if e instanceof EvaluationError
          Cells.update(keyFields, {$set: {error: e.message}})
        else
          throw e
      ce = Cells.findOne(keyFields)

    if ce.values?
      return new TypedSet(@getColumn(qFamilyId.columnId).type,
                          new EJSONKeyedSet(ce.values))
    else
      return null

  # This method serves two purposes:
  # - Determine the type that the column should be assumed to have for the
  #   purposes of other formulas.
  # - Determine whether the formula passes type checking before we try to
  #   evaluate it.
  # These don't have to be done at the same time, but for now that's convenient.
  typecheckColumn: (columnId) ->
    col = @getColumn(columnId)
    type = col.type
    unless type?
      # Formula columns of unspecified type are set to TYPE_ERROR at the
      # beginning for cycle detection, analogous to how family evaluation works.
      type = col.specifiedType ? TYPE_ERROR
      @_changeColumnType(columnId, type)
      if col.formula?
        try
          vars = new EJSONKeyedMap([['this', col.parent]])
          type = typecheckFormula(this, vars, col.formula)
          unless type?
            # This kind of bug would otherwise cause the client to be
            # permanently not ready, which is tedious to debug.
            throw new Error('typecheckFormula returned null/undefined')
          if col.specifiedType?
            valAssert(mergeTypes(col.specifiedType, type) == col.specifiedType,
                      "Column #{columnId} formula returns #{type}, which is not a subtype of specified type #{col.specifiedType}")
          else
            @_changeColumnType(columnId, type)
          if @settings.compiler && !($$.formulaEngine.compiled[columnId])?
            fc = new FormulaCompiler($$.formulaEngine)
            if fc.isCompilationSupported(col.formula)
              $$.formulaEngine.compiled[columnId] = fc.compileAsFunc(col.formula)
        catch e
          unless e instanceof FormulaValidationError
            throw e
          # If type was unspecified, it is left as TYPE_ERROR, i.e., unknown
          # for the purposes of other formulas.
          @_changeColumnTypecheckError(columnId, e.message)
          type = "<error>"

    console.assert(type?)
    type

  typecheckAll: ->
    if @settings.profiling >= 1 then console.log "<typecheckAll>"
    for [columnId, _] in @getAllColumns()
      @typecheckColumn(columnId)
    if @settings.profiling >= 1 then console.log "</typecheckAll>"

  evaluateAll: ->
    # We're now assuming that everything that can make the computed data invalid
    # during one run of the server calls invalidateDataCache, so we don't do it
    # here.  Extra evaluateAll calls will find everything already done and make
    # no changes.
    if @settings.profiling >= 1 then console.log "<evaluateAll>"
    @typecheckAll()
    @populateColumnCache()

    evaluateSubtree = (qCellId) =>
      col = @getColumn(qCellId.columnId)
      for childColId in col.children
        tset = @evaluateFamily({columnId: childColId, cellId: qCellId.cellId})
        if tset?
          for value in tset.elements()
            childQCellId = {columnId: childColId, cellId: cellIdChild(qCellId.cellId, value)}
            evaluateSubtree(childQCellId)

    # Future: Only evaluate what users are viewing.
    evaluateSubtree({columnId: rootColumnId, cellId: rootCellId})
    if @settings.profiling >= 1 then console.log "</evaluateAll>"

  ## Removes all column definitions and data!
  drop: ->
    Columns.remove({_id: {$ne: rootColumnId}})
    Columns.update(rootColumnId, {$set: {children: []}})
    Cells.remove({})

  populateColumnCache: ->
    for c in Columns.find().fetch()
      @columnCache[c._id] = c

  invalidateColumnCache: ->
    @columnCache = {}
      
  invalidateSchemaCache: ->
    if @settings.profiling >= 1 then console.log "--- invalidateSchemaCache ---"
    @invalidateColumnCache()
    @invalidateDataCache()
    $$.formulaEngine?.invalidateSchemaCache()
    for [columnId, col] in @getAllColumns() when columnId != rootColumnId
      @_changeColumnType(columnId, null)
      @_changeColumnTypecheckError(columnId, null)

  invalidateDataCache: ->
    if @settings.profiling >= 1 then console.log "--- invalidateDataCache ---"
    for [columnId, col] in @getAllColumns() when columnId != rootColumnId
      if col.formula?
        Cells.remove({column: columnId})

  executeCannedTransaction: (name, argsObj) ->
    ctxn = @cannedTransactions.get(name)
    unless ctxn?
      throw new Meteor.Error('no-such-transaction', "No such canned transaction #{name}.")
    # Future: Validate types!
    # Future: Add built-in parameters (clientUser, currentTime) here.
    args = new EJSONKeyedMap(
      for [paramName, paramType] in ctxn.params.entries()
        [paramName, new TypedSet(paramType, set(argsObj[paramName]))])
    try
      $$.runTransaction(=>
        executeStatements(this, args, ctxn.body)
        @evaluateAll()
        )
    catch e
      if e instanceof EvaluationError
        console.log('Transaction failed:', name, argsObj, e.stack)
        # Future: How much information to send to unprivileged clients?
        throw new Meteor.Error('transaction-failed', 'Transaction failed.')
      else
        throw e

Meteor.startup () ->
  Tablespace.onCreate ->
    @do ->
      @model = new Model
      @formulaEngine = new FormulaEngine
      appName = /(?:^|\.)([^.]+)$/.exec(@id)?[1]
      if @model.wasEmpty
        if appName == 'ptc' then loadPTCData(@model)
        else if appName in ['005q', 'beta', 'milk']
          loadDump(@model, appName)
          # TO MAKE A DUMP:
          # ./private/scripts/mkdump APPNAME
      @model.evaluateAll()

  Tablespace.default = tspace = Tablespace.get('ptc')  # mostly for use in the shell
  tspace.run()


Meteor.methods
  # The model methods do not automatically evaluate so that we can do bulk
  # changes from the server side, but for now we always evaluate after each
  # change from the client.  It would be a little harder for the client itself
  # to request this via another method (it would require a callback).
  # Future: validation!
  open: (cc) -> cc.run()
  defineColumn: (cc, parentId, index, fieldName, specifiedType, isObject, objectName, formula, viewId) ->
    cc.run ->
      #attrs = if viewId? then {view: viewId} else {}
      id = @model.defineColumn(parentId, index, fieldName, specifiedType, isObject, objectName, formula)
      if viewId? then new View(viewId).addColumn(id, true)  # FIXME: honor index
      @model.evaluateAll()
  changeColumnFieldName: (cc, columnId, fieldName) ->
    cc.run -> @model.changeColumnFieldName(columnId, fieldName)
  changeColumnIsObject: (cc, columnId, isObject) ->
    cc.run ->
      @model.changeColumnIsObject(columnId, isObject)
      # For the case where specifiedType is automatically changed between _token and _any.
      @model.evaluateAll()
  changeColumnObjectName: (cc, columnId, objectName) ->
    cc.run -> @model.changeColumnObjectName(columnId, objectName)
  changeColumnSpecifiedType: (cc, columnId, specifiedType) ->
    cc.run ->
      @model.changeColumnSpecifiedType(columnId, specifiedType)
      @model.evaluateAll()
  changeColumnFormula: (cc, columnId, formula) ->
    cc.run ->
      @model.changeColumnFormula(columnId, formula)
      @model.evaluateAll()
  changeColumnDisplay: (cc, columnId, display) ->
    cc.run ->
      @model.changeColumnDisplay(columnId, display)
  changeColumnReferenceDisplay: (cc, columnId, referenceDisplay) ->
    cc.run ->
      @model.changeColumnReferenceDisplay(columnId, referenceDisplay)
  reorderColumn: (cc, columnId, newIndex) ->
    cc.run -> @model.reorderColumn(columnId, newIndex)
  deleteColumn: (cc, columnId) ->
    cc.run ->
      @model.deleteColumn(columnId)
      View.removeColumnFromAll(columnId)
      @model.evaluateAll()
  notify: (cc) ->
    cc.run ->
      @model.invalidateDataCache()
      @model.evaluateAll()
  executeCannedTransaction: (cc, name, argsObj) ->
    cc.run ->
      @model.executeCannedTransaction(name, argsObj)


exported {Model}
