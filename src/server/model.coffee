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
      @isEmpty = true
      # None of the other properties should be used.
      col = {
        _id: rootColumnId
        # Close enough to the truth?
        specifiedType: '_token'
        children: []
      }
      Columns.insert(col)

  getColumn: (columnId) ->
    # Treat as read-only and valid only until the model is next modified.
    # XXX: Replace by a real API.  At least the references will be easy to find.
    return Columns.findOne(columnId)

  getAllColumns: (columnId=rootColumnId) ->
    #columnId = columnId ? rootColumnId
    col = @getColumn columnId
    [[columnId, col]].concat (@getAllColumns c for c in col.children)...

  defineColumn: (parentId, index, name, specifiedType, cellName, formula, attrs) ->
    # Future: validate everything
    # Future: validate no name for type = _unit or _token
    parentCol = @getColumn.get(parentId)
    unless 0 <= index <= parentCol.children.length
      throw new Meteor.Error('defineColumn-index-out-of-range', 'Index out of range')
    if ((name? && childByName(parentCol, name)?) ||
        (cellName? && childByName(parentCol, cellName)?))
      throw new Meteor.Error('column-name-taken', 'The name is taken by a sibling column.')
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
      name: name
      specifiedType: specifiedType
      type: null
      typecheckError: null
      cellName: cellName
      formula: formula
      children: []
      cells: {}
    }
    for k,v of attrs
      col[k] = v
    Columns.insert(col)
    parentCol.children.splice(index, 0, thisId)
    # Meteor is nice for so many things, but not ORM...
    Columns.update(parentCol._id, {$set: {children: parentCol.children}})

    return thisId

  changeColumnName: (columnId, name) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    col = @getColumn(columnId)
    if name == col.name
      return
    parentCol = @getColumn(col.parent)
    if name? && childByName(parentCol, name)?
      throw new Meteor.Error('column-name-taken', 'The name is taken by a sibling column.')
    Columns.update(columnId, {$set: {name: name}})

  changeColumnCellName: (columnId, cellName) ->
    if columnId == rootColumnId
      throw new Meteor.Error('modify-root-column',
                             'Cannot modify the root column.')
    col = @getColumn(columnId)
    if cellName == col.cellName
      return
    parentCol = @getColumn(col.parent)
    if cellName? && childByName(parentCol, cellName)?
      throw new Meteor.Error('column-name-taken', 'The name is taken by a sibling column.')
    Columns.update(columnId, {$set: {cellName: cellName}})

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

  evaluateAll: ->
    # XXX: Detect if already valid?
    # Be sure to start clean.
    @invalidateCache()

    for [columnId, _] in @getAllColumns()
      @typecheckColumn(columnId)

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
      @model.evaluateAll()

  Tablespace.default = tspace = Tablespace.get('')  # mostly for use in the shell
  tspace.run()

  Tablespace.get('ptc').run ->
    if $$.model.isEmpty
      loadSampleData($$.model)


Meteor.methods({
  # The model methods do not automatically evaluate so that we can do bulk
  # changes from the server side, but for now we always evaluate after each
  # change from the client.  It would be a little harder for the client itself
  # to request this via another method (it would require a callback).
  # Future: validation!
  open: (cc) -> cc.run()
  defineColumn: (cc, parentId, index, name, specifiedType, cellName, formula) ->
    cc.run ->
      @model.defineColumn(parentId, index, name, specifiedType, cellName, formula)
      @model.evaluateAll()
  changeColumnName: (cc, columnId, name) ->
    cc.run -> @model.changeColumnName(columnId, name)
  changeColumnCellName: (cc, columnId, cellName) ->
    cc.run -> @model.changeColumnCellName(columnId, cellName)
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
      @model.evaluateAll()
  notifyChange: (cc) ->
    cc.run -> @model.evaluateAll()
})

exported {Model}
