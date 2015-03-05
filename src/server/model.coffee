# Careful: with "class EvaluationError", the original class gets assigned to a
# file-scope variable that shadows the exported wrapped class seen by the rest
# of the application, and instanceof breaks.
@EvaluationError = Meteor.makeErrorType('EvaluationError',
  class @EvaluationError
    constructor: (@message) ->
)

class Model

  # TODO: Indicate which methods are intended to be public!

  #@columns: EJSONKeyedMap<ColumnId, Column>

  constructor: ->
    # Load from DB.
    # Future: Need a way to make a temporary model for a transaction without reloading.
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
          console.log("Resetting invalid formula in column #{col._id}: #{e.message}")
          col.formula = ['lit', '_unit', []]
          col.specifiedType = null
          Columns.update(col._id, col)

    # Special case: create root column if missing.
    unless @getColumn(rootColumnId)?
      @wasEmpty = true
      # None of the other properties should be used.
      col = {
        _id: rootColumnId
        children: []
        fieldName: null
        specifiedType: '_token'  # Close enough to the truth?
        type: null
        typecheckError: null
        isObject: true  # Allow children.
        objectName: null
        formula: null
      }
      Columns.insert(col)

    # If this is the first time the server process is accessing this sheet, it
    # might contain data generated by a different version of the server code.
    @invalidateCache()

  getColumn: (columnId) ->
    # Treat as read-only and valid only until the model is next modified.
    # XXX: Replace by a real API.  At least the references will be easy to find.
    return Columns.findOne(columnId)

  getAllColumns: (columnId=rootColumnId) ->
    #columnId = columnId ? rootColumnId
    col = @getColumn columnId
    [[columnId, col]].concat (@getAllColumns c for c in col.children)...

  defineColumn: (parentId, index, fieldName, specifiedType, isObject, objectName, formula, attrs) ->
    # Future: validate everything
    # Future: validate no fieldName for type _token.  For _unit, there could be borderline use cases.
    # XXX: Do not allow non-object columns to have type _token?  Currently it
    # won't hurt anything, and it doesn't make sense to tighten this until we
    # finalize the flow for specifying types of newly created columns.
    parentCol = @getColumn(parentId)
    unless parentCol?
      throw new Meteor.Error('defineColumn-no-parent', 'The specified parent column does not exist.')
    unless parentCol.isObject
      throw new Meteor.Error('defineColumn-parent-not-isObject', 'The parent column must be an object to have children.')
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
    @invalidateCache()
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
    for k,v of attrs
      col[k] = v
    Columns.insert(col)
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
    parentCol = @getColumn(col.parent)
    Columns.update(columnId, {$set: {fieldName: fieldName}})

  changeColumnIsObject: (columnId, isObject) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    col = @getColumn(columnId)
    if isObject == col.isObject
      return
    # The way you get a (state) token column is to "add object type" to a state
    # column that still has the default type of _any.  Conversely, removing the
    # object type changes the type back to _any.  Future: better flow!
    if isObject
      if !col.formula? && col.specifiedType == '_any'
        @invalidateCache()
        Columns.update(columnId, {$set: {specifiedType: '_token'}})
    else
      if col.children?.length
        throw new Meteor.Error('delete-column-has-children',  # XXX this is not deleteColumn
                               'Please delete all child columns first.')
      if col.objectName?
        Columns.update(columnId, {$set: {objectName: null}})
      if col.specifiedType == '_token'
        @invalidateCache()
        Columns.update(columnId, {$set: {specifiedType: '_any'}})
    Columns.update(columnId, {$set: {isObject: isObject}})

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
    parentCol = @getColumn(col.parent)
    Columns.update(columnId, {$set: {objectName: objectName}})

  changeColumnSpecifiedType: (columnId, specifiedType) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    @invalidateCache()
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
    validateFormula(formula)
    @invalidateCache()
    col = @getColumn(columnId)
    # Hack: When a state column is converted to a formula column,
    # automatically remove the default type of '_any'.
    if !col.formula? && col.specifiedType == '_any'
      Columns.update(columnId, {$set: {specifiedType: null}})
    Columns.update(columnId, {$set: {formula: formula}})

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
    @invalidateCache()
    parentCol.children.splice(parentCol.children.indexOf(columnId), 1)
    Columns.update(parentCol._id, {$set: {children: parentCol.children}})
    Columns.remove(columnId)

  evaluateFamily1: (qFamilyId) ->
    col = @getColumn(qFamilyId.columnId)
    if col.formula?
      if col.typecheckError?
        throw new EvaluationError("Formula failed type checking: #{col.typecheckError}")
      vars = new EJSONKeyedMap(
        [['this', new TypedSet(col.parent, new EJSONKeyedSet([qFamilyId.cellId]))]])
      return evaluateFormula(this, vars, col.formula)
    else
      # State column (there are no domain columns yet)
      # If it were nonempty, we wouldn't have gotten here.
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
            valAssert(mergeTypes(col.specifiedType, type) != TYPE_ERROR,
                      "Column #{columnId} type is specified as #{col.specifiedType} but formula returns type #{type}")
          else
            @_changeColumnType(columnId, type)
        catch e
          unless e instanceof FormulaValidationError
            throw e
          # If type was unspecified, it is left as TYPE_ERROR, i.e., unknown
          # for the purposes of other formulas.
          @_changeColumnTypecheckError(columnId, e.message)
    type

  typecheckAll: ->
    for [columnId, _] in @getAllColumns()
      @typecheckColumn(columnId)

  evaluateAll: ->
    # We're now assuming that everything that can make the computed data invalid
    # during one run of the server calls invalidateCache, so we don't do it
    # here.  Extra evaluateAll calls will find everything already done and make
    # no changes.

    @typecheckAll()

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

  ## Removes all column definitions and data!
  drop: ->
    Columns.remove({_id: {$ne: rootColumnId}})
    Columns.update(rootColumnId, {$set: {children: []}})
    Cells.remove({})

  invalidateCache: ->
    for [columnId, col] in @getAllColumns() when columnId != rootColumnId
      @_changeColumnType(columnId, null)
      @_changeColumnTypecheckError(columnId, null)
      if col.formula?
        Cells.remove({column: columnId})


Meteor.startup () ->
  Tablespace.onCreate ->
    @do ->
      @model = new Model
      if /^(.*\.)?ptc$/.test(@id) && @model.wasEmpty
        loadSampleData(@model)
      @model.evaluateAll()

  Tablespace.default = tspace = Tablespace.get('ptc')  # mostly for use in the shell
  tspace.run()


Meteor.methods({
  # The model methods do not automatically evaluate so that we can do bulk
  # changes from the server side, but for now we always evaluate after each
  # change from the client.  It would be a little harder for the client itself
  # to request this via another method (it would require a callback).
  # Future: validation!
  open: (cc) -> cc.run()
  defineColumn: (cc, parentId, index, fieldName, specifiedType, isObject, objectName, formula, viewId) ->
    cc.run ->
      attrs = if viewId? then {view: viewId} else {}
      id = @model.defineColumn(parentId, index, fieldName, specifiedType, isObject, objectName, formula, attrs)
      if viewId? then new View(viewId).addColumn(id)
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
  deleteColumn: (cc, columnId) ->
    cc.run ->
      @model.deleteColumn(columnId)
      View.removeColumnFromAll(columnId)
      @model.evaluateAll()
  notifyChange: (cc) ->
    cc.run -> @model.evaluateAll()
})

exported {Model}
