class @EvaluationError

class Model

  # TODO: Indicate which methods are intended to be public!

  #@state: EJSONKeyedMapToSet<QFamilyId, value>
  #@familyCache: EJSONKeyedMap<QFamilyId, CacheEntry>
  #@columns: EJSONKeyedMap<ColumnId, Column>
  #@formulaColumnType: EJSONKeyedMap<ColumnId, type>.
  #  A column ID will be absent if no evaluated family has a known type, i.e.,
  #  there are no evaluated families or all evaluated families are empty with
  #  unknown type.

  initializeColumnTempData: (col) ->
    col.childByName = new EJSONKeyedMap()
    if columnIsState(col)
      col.numStateCells = 0

  registerColumnWithParent: (col) ->
    parentColId = col.parent
    parentCol = @columns.get(parentColId)
    # XXX: Assert no duplicate names
    if col.name?
      parentCol.childByName.set(col.name, col._id)
    if col.cellName?
      parentCol.childByName.set(col.cellName, col._id)

  unregisterColumnWithParent: (col) ->
    parentColId = col.parent
    parentCol = @columns.get(parentColId)
    if col.name?
      parentCol.childByName.delete(col.name)
    if col.cellName?
      parentCol.childByName.delete(col.cellName)

  constructor: ->
    @publishers = []

    @columns = new EJSONKeyedMap()
    @state = new EJSONKeyedMapToSet()
    @familyCache = null

    # Load from DB.
    # Future: Need a way to make a temporary model for a transaction without reloading.
    for col in Columns.find().fetch()
      @columns.set(col._id, col)
      @initializeColumnTempData(col)
      for cellIdStr of col.cells ? {}
        cellId = EJSONfromMongoFieldName(cellIdStr)
        @state.add({columnId: col._id, cellId: cellIdParent(cellId)},
                   cellIdLastStep(cellId))
        col.numStateCells++
      # Don't store a duplicate copy.  So, careful about writing col back to DB.
      delete col.cells

    # Special case: create root column if missing.
    unless @columns.get(rootColumnId)?
      # None of the other properties should be used.
      col = {
        _id: rootColumnId
        children: []
        cells: {}
      }
      @columns.set(rootColumnId, col)
      Columns.insert(col)
      delete col.cells
      @initializeColumnTempData(col)

    # Now go back and link things up.
    for colId in @columns.keys()
      col = @columns.get(colId)
      # Oops, the DB already stores parents.  Future: Validate.
      ## XXX: Validate each column (except root) has exactly one parent.
      #for childId in col.children
      #  @columns.get(childId).parent = colId
      if colId != rootColumnId
        # XXX: Assert parent existence
        @registerColumnWithParent(col)
    # Future: validate that type usage is acyclic.

    for colId in @columns.keys()
      for publisher in @publishers
        @publishColumn(colId, publisher)

  getColumn: (columnId) ->
    # Treat as read-only and valid only until the model is next modified.
    # XXX: Replace by a real API.  At least the references will be easy to find.
    return @columns.get(columnId)

  defineColumn: (parentId, index, name, type, cellName, formula) ->
    # Future: specify order rather than always at the end
    # Future: validate everything
    # Future: validate no name for type = _unit or _token
    parentCol = @columns.get(parentId)
    if !formula? && parentCol.formula?
      throw new Error('Creating a state column as child of a formula column is currently not allowed.')
    if formula? && type?
      # For now, with dynamic typing.  This might change.
      throw new Error('Cannot specify type for a formula column')
    if !formula? && !type?
      throw new Error('Must specify type for a state column')
    parentCol = @columns.get(parentId)
    unless 0 <= index <= parentCol.children.length
      throw new Error('Index out of range')
    @invalidateCache()
    thisId = Random.id()
    col = {
      _id: thisId
      parent: parentId
      name: name
      type: type
      cellName: cellName
      formula: formula
      children: []
      cells: {}
    }
    @columns.set(thisId, col)
    Columns.insert(col)
    # Silly... "cells" is for DB only.
    delete col.cells
    @initializeColumnTempData(col)
    parentCol.children.splice(index, 0, thisId)
    # Meteor is nice for so many things, but not ORM...
    Columns.update(parentCol._id, {$set: {children: parentCol.children}})
    @registerColumnWithParent(col)

    for publisher in @publishers
      @publishColumn(thisId, publisher)
      @unpublishColumn(parentId, publisher)
      @publishColumn(parentId, publisher)

    return thisId

  renameColumn: (columnId, name, cellName) ->
    col = @columns.get(columnId)
    parentId = col.parent
    parentCol = @columns.get(parentId)
    @unregisterColumnWithParent(col)
    col.name = name
    col.cellName = cellName
    @registerColumnWithParent(col)
    Columns.update(columnId, {$set: {name: name, cellName: cellName}})
    for publisher in @publishers
      @unpublishColumn(columnId, publisher)
      @publishColumn(columnId, publisher)
      @unpublishColumn(parentId, publisher)
      @publishColumn(parentId, publisher)

  # Future: API to move and copy groups of columns.  This is an order of
  # magnitude more complicated.

  changeFormula: (columnId, formula) ->
    col = @columns.get(columnId)
    unless col.formula?
      throw new Error('Can only changeFormula on a formula column!')
    @invalidateCache()
    col.formula = formula
    Columns.update(columnId, {$set: {formula: formula}})
    for publisher in @publishers
      @unpublishColumn(columnId, publisher)
      @publishColumn(columnId, publisher)

  deleteColumn: (columnId) ->
    if columnId == rootColumnId
      throw new Error('Cannot delete the root column.')
    # Assert not root
    col = @columns.get(columnId)
    if col.children.length > 0
      throw new Error('Please delete all child columns first.')
    # Assert col.childByName also empty
    if columnIsState(col) && col.numStateCells > 0
      throw new Error('Please delete all state cells first.')
    parentId = col.parent
    parentCol = @columns.get(parentId)
    @invalidateCache()
    parentCol.children.splice(parentCol.children.indexOf(columnId), 1)
    Columns.update(parentCol._id, {$set: {children: parentCol.children}})
    @unregisterColumnWithParent(col)
    @columns.delete(columnId)
    Columns.remove(columnId)
    for publisher in @publishers
      @unpublishColumn(columnId, publisher)
      @unpublishColumn(parentId, publisher)
      @publishColumn(parentId, publisher)

  # Future: Token order and API to change it
  writeState: (qFamilyId, value, present) ->
    # Future: Validate everything.
    cellId = cellIdChild(qFamilyId.cellId, value)
    mongoUpdateThing = {}
    mongoUpdateThing['cells.' + EJSONtoMongoFieldName(cellId)] = true
    if present
      if !@state.has(qFamilyId, value)
        @invalidateCache()
        @state.add(qFamilyId, value)
        Columns.update(qFamilyId.columnId, {$set: mongoUpdateThing})
        @columns.get(qFamilyId.columnId).numStateCells++
        for publisher in @publishers
          @unpublishColumn(qFamilyId.columnId, publisher)
          @publishColumn(qFamilyId.columnId, publisher)
    else
      if @state.has(qFamilyId, value)
        cellId = cellIdChild(qFamilyId.cellId, value)
        col = @columns.get(qFamilyId.columnId)

        # Check we are not orphaning descendant state cells.
        for childColumnId in col.children
          childCol = @columns.get(childColumnId)
          if @state.elementsFor({columnId: childColumnId, cellId: cellId}).length > 0
            throw new Meteor.Error('delete-state-cell-has-descendants',
                                   'Please delete descendant state cells first.')

        @invalidateCache()
        @state.delete(qFamilyId, value)
        Columns.update(qFamilyId.columnId, {$unset: mongoUpdateThing})
        col.numStateCells--
        for publisher in @publishers
          @unpublishColumn(qFamilyId.columnId, publisher)
          @publishColumn(qFamilyId.columnId, publisher)

  evaluateFamily1: (qFamilyId) ->
    col = @columns.get(qFamilyId.columnId)
    if col.formula?
      vars = new EJSONKeyedMap()
      vars.set('this', {type: col.parent, elements: [qFamilyId.cellId]})
      return evaluateFormula(this, vars, col.formula)
    else
      # State column (there are no domain columns yet)
      return {type: col.type, elements: @state.elementsFor(qFamilyId)}

  evaluateFamily: (qFamilyId) ->
    ce = @familyCache.get(qFamilyId)
    unless ce?
      ce = {state: FAMILY_IN_PROGRESS, content: null}
      @familyCache.set(qFamilyId, ce)
      try
        ce.content = @evaluateFamily1(qFamilyId)
        ce.state = FAMILY_SUCCESS

        if @columns.get(qFamilyId.columnId).formula?
          # Update formulaColumnType
          oldFCT = @formulaColumnType.get(qFamilyId.columnId)
          if ce.content.type? && ce.content.type != oldFCT
            if oldFCT?
              for publisher in @publishers
                @unpublishFormulaColumnType(qFamilyId.columnId, publisher)
            newFCT = if oldFCT? then FORMULA_COLUMN_TYPE_MIXED else ce.content.type
            @formulaColumnType.set(qFamilyId.columnId, newFCT)
            for publisher in @publishers
              @publishFormulaColumnType(qFamilyId.columnId, publisher)

      catch e
        if e instanceof EvaluationError
          ce.state = FAMILY_ERROR
        else
          throw e

    return ce

  readFamilyForFormula: (qFamilyId) ->
    ce = @evaluateFamily(qFamilyId)
    if ce.state == FAMILY_SUCCESS
      return ce.content
    else
      # Includes FAMILY_IN_PROGRESS, which means a newly detected cycle.
      # Future: 'Reference to CELL, which failed', precise cycle detection with
      # different message.
      throw new EvaluationError()

  readFamily: (qFamilyId) ->
    ce = @familyCache.get(qFamilyId)
    # Assert it has been evaluated (i.e., watches are correct).
    return ce.content

  evaluateAll: ->
    if @familyCache?
      return  # already valid
    @familyCache = new EJSONKeyedMap()
    @formulaColumnType = new EJSONKeyedMap()

    evaluateSubtree = (qCellId) =>
      col = @columns.get(qCellId.columnId)
      for childColId in col.children
        ce = @evaluateFamily({columnId: childColId, cellId: qCellId.cellId})
        if ce.state == FAMILY_SUCCESS
          for value in ce.content.elements
            childQCellId = {columnId: childColId, cellId: cellIdChild(qCellId.cellId, value)}
            evaluateSubtree(childQCellId)

    # Future: Only evaluate what users are viewing.
    evaluateSubtree({columnId: rootColumnId, cellId: rootCellId})

    # Consider publishing as we go?
    for qFamilyId in @familyCache.keys()
      for publisher in @publishers
        @publishFamily(qFamilyId, publisher)

  unpublishFormulaColumnType: (columnId, publisher) ->
    publisher.removed(FORMULA_COLUMN_TYPE_COLLECTION, columnId)

  publishFormulaColumnType: (columnId, publisher) ->
    publisher.added(FORMULA_COLUMN_TYPE_COLLECTION, columnId,
                    {type: @formulaColumnType.get(columnId)})

  # I (Matt) believe that each formula column should have a single type, but
  # right now it is determined only during formula evaluation and not stored in
  # the column object.  So this is how you get it.
  getFormulaColumnType: (columnId) -> @formulaColumnType.get(columnId)

  unpublishFamily: (qFamilyId, publisher) ->
    publisher.removed(FAMILY_DATA_COLLECTION, EJSON.stringify(qFamilyId))

  publishFamily: (qFamilyId, publisher) ->
    # Everything in the CacheEntry is OK to publish.
    publisher.added(FAMILY_DATA_COLLECTION, EJSON.stringify(qFamilyId),
                    @familyCache.get(qFamilyId))

  unpublishColumn: (columnId, publisher) ->
    publisher.removed(COLUMN_COLLECTION, columnId)

  publishColumn: (columnId, publisher) ->
    publisher.added(COLUMN_COLLECTION, columnId, @columns.get(columnId))

  invalidateCache: ->
    if @familyCache?
      for qFamilyId in @familyCache.keys()
        for publisher in @publishers
          @unpublishFamily(qFamilyId, publisher)
      @familyCache = null
      for columnId in @formulaColumnType.keys()
        for publisher in @publishers
          @unpublishFormulaColumnType(columnId, publisher)
      @formulaColumnType = null

  # CLEANUP: Rewrite this to keep a set of published objects from all
  # collections.  Then we can replay them to a new publisher and write a wrapper
  # to publish/unpublish an object to all publishers.
  addPublisher: (publisher) ->
    @publishers.push(publisher)
    for columnId in @columns.keys()
      @publishColumn(columnId, publisher)
    if @familyCache?
      for qFamilyId in @familyCache.keys()
        @publishFamily(qFamilyId, publisher)
      for columnId in @formulaColumnType.keys()
        @publishFormulaColumnType(columnId, publisher)
    publisher.ready()

  removePublisher: (publisher) ->
    @publishers.splice(@publishers.indexOf(publisher), 1)

Meteor.startup () ->
  @model = new Model()
  @getColumn = (id) -> model.getColumn(id)
  if model.columns.keys().length == 1  # root column :/
    loadSampleData()
  model.evaluateAll()
# Publish everything for now.
# Future: Reduce amount of add/remove thrashing.
Meteor.publish(null, () ->
  @onStop(() -> model.removePublisher(this))
  model.addPublisher(this)
)
Meteor.methods({
  # The model methods do not automatically evaluate so that we can do bulk
  # changes from the server side, but for now we always evaluate after each
  # change from the client.  It would be a little harder for the client itself
  # to request this via another method (it would require a callback).
  # Future: validation!
  defineColumn: (parentId, index, name, type, cellName, formula) ->
    model.defineColumn(parentId, index, name, type, cellName, formula)
    model.evaluateAll()
  renameColumn: (columnId, name, cellName) ->
    model.renameColumn(columnId, name, cellName)
    model.evaluateAll()
  changeFormula: (columnId, formula) ->
    model.changeFormula(columnId, formula)
    model.evaluateAll()
  deleteColumn: (columnId) ->
    model.deleteColumn(columnId)
    model.evaluateAll()
  writeState: (qFamilyId, value, present) ->
    model.writeState(qFamilyId, value, present)
    model.evaluateAll()
})
