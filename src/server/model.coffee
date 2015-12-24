class CannedTransaction
  # @params: EJSONKeyedMap of name to type
  constructor: (@params, @body) ->

class Model

  # TODO: Indicate which methods are intended to be public!

  #@columns: EJSONKeyedMap<ColumnId, Column>

  constructor: ->
    # Compiler produced incorrect results on SiteTotals.site on the cost sheet.
    # ~ Matt 2015-10-19
    @settings = {compiler: false, profiling: 0}
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
        referenceDisplayColumn: null
        formula: null

    # If this is the first time the server process is accessing this sheet, it
    # might contain data generated by a different version of the server code.
    @invalidateSchemaCache()

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
        throw new Meteor.Error('state-under-formula',
                               'Cannot have a state column as child of a formula column.')
      if !specifiedType?
        # TODO perhaps a better flow would be to leave undefined, but check when
        #  user enters data
        throw new Meteor.Error('defineColumn-type-required',
                               'Must specify type for a state column')
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
      referenceDisplayColumn: null
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

  # Should be roughly equivalent to what you get by adding a field and then
  # "promoting" to an object type via the flow in changeColumnIsObject.  I'd
  # rather do this in one call to the server. ~ Matt 2015-11-12
  insertUnkeyedStateObjectTypeWithField: (parentId, index, objectName, fieldName, specifiedType, attrs) ->
    objectColId = @defineColumn(parentId, index, null, '_token', true, objectName, null, attrs)
    fieldColId = @defineColumn(objectColId, 0, fieldName, specifiedType, false, null, null, attrs)
    return [objectColId, fieldColId]

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
    
    updates = {isObject: isObject}
    if isObject
      if col.formula?
        # Do not generate a new object name: [fieldName] is good enough.
      else
        # When making a state column into an object column:
        # column type becomes "_token", a new object name is generated,
        # and existing values are moved to a newly created child column
        @invalidateSchemaCache()
        Columns.update(columnId, {$set: {specifiedType: '_token', isObject: true, objectName: nextAvailableColumnName('Object'), fieldName: null}})
        childId = @defineColumn(columnId, 0, col.fieldName, col.specifiedType, false, null, null, {})
        Cells.find({column: columnId}).forEach (family) ->
          tokens = (Random.id() for value in family.values)
          Cells.update(family._id, {$set: {values: tokens}})
          for [token, value] in zip(tokens, family.values)
            key = cellIdChild(family.key, token)
            Cells.insert({column: childId, key, values: [value]})
    else
      updates.objectName = null
      # When making a column into a value column:
      # - If column type is "_token", values are copied from the column's only child,
      #   and that child is removed.
      # - Otherwise, column must have no children.
      if col.type == '_token'
        if col.children?.length != 1
          throw new Meteor.Error('remove-object-has-children',
                                 'Object must have a single field before converting to values.')
        childId = col.children[0]
        childCol = @getColumn(childId)
        if childCol.isObject || childCol.children?.length
          throw new Meteor.Error('remove-object-complex-value',
                                 "Child '#{childCol.objectName ? childCol.fieldName ? '(unnamed)'}' is not a simple value.")
        Cells.find({column: columnId}).forEach (family) ->
          newValues = []
          for value in family.values
            Cells.find({column: childId, key: value}).forEach (family) ->
              newValues.push(family.values...)
          Cells.update(family._id, {$set: {values: newValues}})
        updates.specifiedType = childCol.type
        updates.fieldName = childCol.fieldName
        updates.children = []
        Columns.remove(childId)
        Cells.remove({column: childId})
        @invalidateSchemaCache()
      else
        if col.children?.length
          throw new Meteor.Error('remove-object-has-children',
                                 'Please delete all child columns first.')
    Columns.update(columnId, {$set: updates})
    @invalidateColumnCache()

  changeColumnSpecifiedType: (columnId, specifiedType) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    col = @getColumn(columnId)
    if specifiedType == col.specifiedType
      return
    if (col.specifiedType == '_token') != (specifiedType == '_token')
      throw new Meteor.Error('change-type-token',
                             'Cannot change a column type to or from _token.')
    if !col.formula?
      if col.isObject
        throw new Meteor.Error('change-type-state-keyed-object',
                               "Oops... we haven't implemented changing the key type of a state object column " +
                               "since we're deprecating state keyed objects.")
      # If we get here, there should be no descendant data to worry about.
      # Reparse existing data as the new type /before/ we invalidate computed
      # reference display columns.
      newFamilies =
        for family in Cells.find({column: columnId}).fetch()
          # Object newly allocated by fetch(), OK to mutate
          family.values =
            for v in family.values
              try
                # XXX: It's O(m*n) to parse m references to an object column with n objects.  Add caching.
                parseValue(specifiedType, valueToText(liteModel, col.specifiedType, v))
              catch e
                # Yep, that omits it from the collected array.
                continue
          family

    @invalidateSchemaCache()
    Columns.update(columnId, {$set: {specifiedType}})
    if !col.formula?
      # XXX If we crash here, the database will be corrupt, but there are
      # probably many other cases just as bad...
      for family in newFamilies
        # XXX _id should be stable for state families, but cleaner not to rely
        # on it (or change _id to be column+key like we were discussing).
        Cells.update(family._id, {$set: {values: family.values}})

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
    if formula?
      validateFormula(formula)

    col = @getColumn(columnId)
    updates = {formula}
    if !col.formula? && formula?
      for childColumnId in col.children
        if !@getColumn(childColumnId).formula?
          throw new Meteor.Error('state-under-formula',
                                 'Cannot have a state column as child of a formula column.')

      # Currently this is allowed to just blow away existing state cells.

      # Hack: When a state column is converted to a formula column,
      # automatically remove the specified type.  This should be OK because having
      # to specify a type for a formula column is a rare case.  If at some point
      # we distinguish whether state column types were user-specified or inferred
      # from data, then we could consider keeping a user-specified type here.
      updates.specifiedType = null
    else if col.formula? && !formula?
      parentCol = @getColumn(col.parent)
      if parentCol.formula?
        throw new Meteor.Error('state-under-formula',
                               'Cannot have a state column as child of a formula column.')
      if col.type not in [TYPE_EMPTY, TYPE_ERROR]
        # We'd better set a specifiedType that matches the evaluated families.
        # If col.specifiedType is already set, col.type will be the same and
        # this will be a no-op.
        updates.specifiedType = col.type
      else
        # In this case, there are no nonempty evaluated families.
        # The user can easily change the type if it isn't what they want.
        updates.specifiedType = DEFAULT_STATE_FIELD_TYPE
      # Convert erroneous families to empty. :/
      Cells.update({column: columnId, error: {$exists: true}},
                   {$unset: {error: null}, $set: {values: []}},
                   {multi: true})

    Columns.update(columnId, {$set: updates})
    @invalidateSchemaCache()  # type may change

  changeColumnReferenceDisplayColumn: (columnId, referenceDisplayColumn) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    # Don't bother with further validation here because we have to be prepared
    # anyway for the choice of reference display column to become invalid as a
    # result of modifications to the sheet.
    # We use a different convention than Match.Optional...
    check(referenceDisplayColumn, Match.OneOf(String, null))
    Columns.update(columnId, {$set: {referenceDisplayColumn}})

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
    col = @getColumn(columnId)
    if col.children?.length
      throw new Meteor.Error('delete-column-has-children',
                             'Please delete all child columns first.')
    parentCol = @getColumn(col.parent)
    @invalidateSchemaCache()
    Cells.remove({column: columnId})
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
    # Reference to a deleted column?
    unless col?
      return TYPE_ERROR
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
            valAssert(commonSupertype(col.specifiedType, type) == col.specifiedType,
                      "Column '#{stringifyColumnRef([columnId, true])}' " +
                      "formula returns '#{stringifyType(type)}', " +
                      "which is not convertible to the specified type '#{col.specifiedType}'")
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

  # Procedure object:
  # {
  #   name: string
  #   params: list of {name (str), type (str as usual), singular (bool)}
  #   body: statements list
  # }

  defineProcedure: (proc) ->
    proc._id = Random.id()
    validateProcedure(proc)
    Procedures.insert(proc)
    return proc._id

  # Overwrites (and optionally renames) the existing procedure with procId.
  redefineProcedure: (procId, proc) ->
    delete proc._id  # ignored if passed
    validateProcedure(proc)
    # It's OK to pass a replacement document without an id:
    # https://docs.mongodb.org/manual/reference/method/db.collection.update/#update-parameter
    # No effect if no procedure with the ID exists.  OK?
    Procedures.update(procId, proc)

  deleteProcedure: (procId) ->
    # No effect if no procedure with the ID exists.  OK?
    Procedures.remove(procId)

  executeCannedTransaction: (name, argsObj) ->
    proc = Procedures.findOne({name: name})
    unless proc?
      throw new Meteor.Error('no-such-procedure', "No such procedure '#{name}'.")
    # Typecheck the procedure.  TODO: Cache this like for column formulas.
    try
      typecheckProcedure(this, proc)
    catch e
      unless e instanceof FormulaValidationError
        throw e
      console.log(e.stack)
      throw new Meteor.Error(
        'procedure-ill-typed',
        "Procedure '#{name}' is ill-typed with respect to the current schema and cannot be executed.")
    # Future: Validate argument types!
    # Future: Add built-in parameters (clientUser, currentTime) here.
    args = new EJSONKeyedMap(
      for param in proc.params
        [param.name, new TypedSet(param.type, set(argsObj[param.name]))])
    try
      $$.runTransaction(=>
        executeProcedure(this, proc, args)
        @evaluateAll()
        )
    catch e
      if e instanceof EvaluationError
        console.log('Transaction failed:', name, argsObj, e.stack)
        # Future: How much information to send to unprivileged clients?
        throw new Meteor.Error('transaction-failed', 'Transaction failed.')
      else
        throw e

  repair: () ->
    # We can add repair steps for crashes and bugs in old versions of the code here.
    @invalidateSchemaCache()

    # Remove orphaned columns and state families.

    liveColumnIds = new EJSONKeyedSet()
    scanColumnSubtree = (columnId) =>
      liveColumnIds.add(columnId)
      col = @getColumn(columnId)
      for childColId in col.children
        scanColumnSubtree(childColId)
    scanColumnSubtree(rootColumnId)
    for col in Columns.find().fetch()
      unless liveColumnIds.has(col._id)
        Columns.remove(col)

    liveFamilies = new EJSONKeyedSet()  # {column, key}
    # Traversal code adapted from evaluateAll.
    scanCellSubtree = (qCellId) =>
      col = @getColumn(qCellId.columnId)
      for childColId in col.children
        keyFields = {column: childColId, key: qCellId.cellId}
        liveFamilies.add(keyFields)
        ce = Cells.findOne(keyFields)
        if ce?.values?
          for value in ce.values
            childQCellId = {columnId: childColId, cellId: cellIdChild(qCellId.cellId, value)}
            scanCellSubtree(childQCellId)
    scanCellSubtree({columnId: rootColumnId, cellId: rootCellId})
    for ce in Cells.find().fetch()
      unless liveFamilies.has({column: ce.column, key: ce.key})
        Cells.remove(ce)

    for col in Columns.find().fetch()
      if col.formula?
        # A mitigation for the common problem of formula operations being
        # removed.  There are obviously many other ways a bad database can break
        # us.
        try
          validateFormula(col.formula)
        catch e
          unless e instanceof Meteor.Error && e.error == 'invalid-formula'
            throw e
          console.log("Column '#{stringifyColumnRef([col._id, true])}' contains invalid formula " +
                      "#{JSON.stringify(col.formula)}: #{e.message}.  Resetting.")
          col.formula = DUMMY_FORMULA
          col.specifiedType = null
          Columns.update(col._id, col)


# Used by procedures and the UI.
# Keeping this parallel with the other ways the UI modifies data, which don't go
# through the model or call invalidateDataCache.  XXX: Fix this (lack of) API.
@recursiveDeleteStateCellNoInvalidate = (columnId, cellId) ->
  col = getColumn(columnId)
  for childColId in col.children
    childCol = getColumn(childColId)
    unless childCol.formula?
      # Empty families are only inserted during evaluateAll, so they may not yet
      # exist for objects created in the same transaction.
      if (ce = Cells.findOne({column: childColId, key: cellId}))?
        for val in ce.values
          # The Cells.update in here is subsumed by the Cells.remove below.  Oh well.
          recursiveDeleteStateCellNoInvalidate(childColId, cellIdChild(cellId, val))
        Cells.remove({column: childColId, key: cellId})
  Cells.update({column: columnId, key: cellIdParent(cellId)},
               {$pull: {values: cellIdLastStep(cellId)}})

Meteor.startup () ->
  Tablespace.onCreate ->
    @do ->
      console.log "creating model of [#{@id}]"
      @model = new Model
      @formulaEngine = new FormulaEngine
      appName = /(?:^|\.)([^.]+)$/.exec(@id)?[1]
      if @model.wasEmpty
        #if appName == 'ptc' then loadPTCData(@model)
        #else
          loadDumpIfExists(@model, appName)
          # TO MAKE A DUMP:
          # ./private/scripts/mkdump APPNAME
      @model.repair()
      @model.evaluateAll()

  if Meteor.isServer   # this condition is here to allow standalone mode
    Tablespace.default = tspace = Tablespace.get('ptc')  # mostly for use in the shell
    #tspace.run()  # Slows down server startup.


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
  insertUnkeyedStateObjectTypeWithField: (cc, parentId, index, objectName, fieldName, specifiedType, viewId) ->
    cc.run ->
      #attrs = if viewId? then {view: viewId} else {}
      [objectColId, fieldColId] = @model.insertUnkeyedStateObjectTypeWithField(
        parentId, index, objectName, fieldName, specifiedType)
      if viewId?
        view = new View(viewId)
        view.addColumn(objectColId, true)  # FIXME: honor index
        view.addColumn(fieldColId, true)  # FIXME: honor index
      @model.evaluateAll()
  changeColumnFieldName: (cc, columnId, fieldName) ->
    cc.run -> @model.changeColumnFieldName(columnId, fieldName)
  changeColumnIsObject: (cc, columnId, isObject) ->
    cc.run ->
      @model.changeColumnIsObject(columnId, isObject)
      # For the case where a token object is converted to or from a field.
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
  changeColumnReferenceDisplayColumn: (cc, columnId, referenceDisplayColumn) ->
    cc.run ->
      @model.changeColumnReferenceDisplayColumn(columnId, referenceDisplayColumn)
  reorderColumn: (cc, columnId, newIndex) ->
    cc.run -> @model.reorderColumn(columnId, newIndex)
  deleteColumn: (cc, columnId) ->
    cc.run ->
      @model.deleteColumn(columnId)
      View.removeColumnFromAll(columnId)
      @model.evaluateAll()
  recursiveDeleteStateCellNoInvalidate: (cc, columnId, cellId) ->
    cc.run ->
      recursiveDeleteStateCellNoInvalidate(columnId, cellId)
  notify: (cc) ->
    cc.run ->
      @model.invalidateDataCache()
      @model.evaluateAll()
  executeCannedTransaction: (cc, name, argsObj) ->
    cc.run ->
      @model.executeCannedTransaction(name, argsObj)


exported {Model}
